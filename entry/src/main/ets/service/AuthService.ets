/**
 * AuthService —— 登录态的建立、恢复与失效处理
 *
 * 核心事实（来自服务端源码，不要凭直觉改）：
 *   1. session_token 有效期固定 30 天（MaxAge 2592000），**服务端不续期**
 *      GetSession 只判断过期并删除，UpdateLatest 只改最后在线时间
 *      → 轮询无法保活，到期只能重新登录
 *   2. session 只能通过 Cookie 传递，服务端不支持用 Authorization 头传 session
 *      Authorization 头只认 API Key（服务端全局配置，长度 >= 12）
 *   3. 开启 2FA 后无法静默重登，必须让用户输入验证码
 *   4. 私有站点模式下，匿名用户连节点列表都拿不到，只能调 4 个白名单方法
 *
 * 恢复策略（冷启动调用 restore）：
 *   Guest   → 直接进，不做任何网络探测
 *   ApiKey  → 取本地 key，有则视为已登录（无过期概念）
 *   Password→ 取本地 token → getMe 探测 → 失效则用保存的密码静默重登
 *             → 仍失败才置为 NeedsLogin，让 UI 弹登录页
 */

import { RpcClient, RpcException } from './RpcClient';
import { KomariApi } from './KomariApi';
import { KeyFactory, SecretStore } from '../storage/SecretStore';
import { AuthMode, ServerConfig } from '../model/KomariTypes';

export enum SessionState {
  /** 尚未探测 */
  Unknown = 0,
  /** 游客模式，只能访问 public:* 且受私有站点限制 */
  Guest = 1,
  Authenticated = 2,
  /** 需要用户介入：首次登录 / 密码变更 / 无可用凭据 */
  NeedsLogin = 3
}

export class AuthService {
  /** 与服务端 sessionCookieMaxAge 保持一致 */
  static readonly SESSION_TTL_MS: number = 30 * 24 * 60 * 60 * 1000;
  /** 剩余时间低于此值时，UI 提示即将过期（不打断） */
  static readonly EXPIRE_WARN_MS: number = 3 * 24 * 60 * 60 * 1000;

  private rpc: RpcClient;
  private api: KomariApi;
  private secrets: SecretStore;
  private config: ServerConfig;

  private sessionToken: string = '';
  private apiKey: string = '';
  private expireAt: number = 0;
  private state: SessionState = SessionState.Unknown;

  constructor(config: ServerConfig, rpc: RpcClient, api: KomariApi, secrets: SecretStore) {
    this.config = config;
    this.rpc = rpc;
    this.api = api;
    this.secrets = secrets;
  }

  getState(): SessionState {
    return this.state;
  }

  getExpireAt(): number {
    return this.expireAt;
  }

  getConfig(): ServerConfig {
    return this.config;
  }

  /** 距过期是否不足预警阈值，UI 用来显示提示条 */
  isNearExpiry(): boolean {
    if (this.expireAt === 0) {
      return false;
    }
    return this.expireAt - Date.now() < AuthService.EXPIRE_WARN_MS;
  }

  /**
   * 生成每次请求要附加的头。交给 RpcClient 作为 HeaderProvider。
   * 注意：session 走 Cookie 头，API Key 走 Authorization 头，不能混用。
   */
  buildHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    if (this.config.authMode === AuthMode.ApiKey) {
      if (this.apiKey.length > 0) {
        headers['Authorization'] = `Bearer ${this.apiKey}`;
      }
      return headers;
    }
    if (this.sessionToken.length > 0) {
      headers['Cookie'] = `session_token=${this.sessionToken}`;
    }
    return headers;
  }

  /**
   * 冷启动恢复。不会抛网络异常：连不上服务端时按"保持已登录"处理，
   * 让页面用缓存渲染，请求失败时再由页面自己降级。
   */
  async restore(): Promise<SessionState> {
    if (this.config.authMode === AuthMode.Guest) {
      this.state = SessionState.Guest;
      return this.state;
    }

    if (this.config.authMode === AuthMode.ApiKey) {
      this.apiKey = await this.secrets.get(KeyFactory.apiKey(this.config.id));
      this.state = this.apiKey.length > 0 ? SessionState.Authenticated : SessionState.NeedsLogin;
      return this.state;
    }

    // Password 模式
    this.sessionToken = await this.secrets.get(KeyFactory.sessionToken(this.config.id));
    if (this.sessionToken.length === 0) {
      this.state = SessionState.NeedsLogin;
      return this.state;
    }

    let alive: boolean = false;
    try {
      alive = await this.probe();
    } catch (e) {
      const err = e as RpcException;
      if (err instanceof RpcException && err.transport) {
        // 网络不可达，无法判定，先按已登录放行
        this.state = SessionState.Authenticated;
        return this.state;
      }
      alive = false;
    }

    if (alive) {
      this.state = SessionState.Authenticated;
      return this.state;
    }

    // 会话失效，尝试用保存的密码静默重登
    const saved: string = await this.secrets.get(KeyFactory.password(this.config.id));
    if (saved.length === 0) {
      this.state = SessionState.NeedsLogin;
      return this.state;
    }
    try {
      await this.login(this.config.username, saved, '', false);
      this.state = SessionState.Authenticated;
    } catch (e) {
      this.state = SessionState.NeedsLogin;
    }
    return this.state;
  }

  /** 主动探测当前 token 是否有效 */
  private async probe(): Promise<boolean> {
    const me = await this.api.getMe();
    return me.logged_in === true;
  }

  /**
   * 登录。成功后写入 session_token；remember 为 true 时同时保存密码，
   * 供 30 天过期后静默重登使用。
   * 开启 2FA 的账号必须传 twoFa，否则服务端返回 401。
   */
  async login(username: string, password: string, twoFa: string, remember: boolean): Promise<void> {
    const res = await this.rpc.postJson<Object>('/api/login', {
      username: username,
      password: password,
      '2fa_code': twoFa
    });

    if (res.status !== 'success') {
      throw new Error(res.message.length > 0 ? res.message : '登录失败');
    }

    // 响应形如 { status, message, data: { "set-cookie": { session_token: "..." } } }
    const data = res.data as Record<string, Object>;
    const setCookie = data['set-cookie'] as Record<string, string>;
    const token: string = setCookie ? setCookie['session_token'] : '';
    if (!token || token.length === 0) {
      throw new Error('登录响应中未取到 session_token');
    }

    this.config.username = username;
    this.config.authMode = AuthMode.Password;
    this.config.rememberPassword = remember;
    this.sessionToken = token;
    this.expireAt = Date.now() + AuthService.SESSION_TTL_MS;
    this.state = SessionState.Authenticated;

    await this.secrets.put(KeyFactory.sessionToken(this.config.id), token);
    if (remember) {
      await this.secrets.put(KeyFactory.password(this.config.id), password);
    } else {
      await this.secrets.remove(KeyFactory.password(this.config.id));
    }
  }

  /** 使用 API Key 登录（无过期，需服务端已配置） */
  async loginWithApiKey(key: string): Promise<void> {
    if (key.length < 12) {
      throw new Error('API Key 长度不足，服务端要求至少 12 位');
    }
    this.apiKey = key;
    this.config.authMode = AuthMode.ApiKey;
    this.state = SessionState.Authenticated;
    await this.secrets.put(KeyFactory.apiKey(this.config.id), key);
  }

  /** 登出：清服务端会话 + 清本地凭据。服务端返回 302，不跟随跳转 */
  async logout(): Promise<void> {
    try {
      await this.rpc.getStatus('/api/logout');
    } catch (e) {
      // 服务端清不掉也要清本地，不能卡住用户
    }
    await this.secrets.remove(KeyFactory.sessionToken(this.config.id));
    await this.secrets.remove(KeyFactory.password(this.config.id));
    await this.secrets.remove(KeyFactory.apiKey(this.config.id));
    this.sessionToken = '';
    this.apiKey = '';
    this.expireAt = 0;
    this.state = SessionState.NeedsLogin;
  }

  /** 切换为游客模式，不清除已保存凭据 */
  useAsGuest(): void {
    this.config.authMode = AuthMode.Guest;
    this.sessionToken = '';
    this.state = SessionState.Guest;
  }
}
