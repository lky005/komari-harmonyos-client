/**
 * ServerStore —— 非敏感配置存储（服务端列表 + 应用偏好）
 *
 * 只存不需要加密的东西：服务端地址、当前选中、刷新频率、主题等。
 * 凭据一律走 SecretStore，不要图省事塞这里。
 *
 * 维护约定：
 *   - 使用前必须在 EntryAbility 里调用 init(context)
 *   - 新增偏好项用 getSetting / putSetting，不必加新方法
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AuthMode, ServerConfig } from '../model/KomariTypes';

export interface ServerStore {
  listServers(): Promise<ServerConfig[]>;
  saveServer(cfg: ServerConfig): Promise<void>;
  removeServer(id: string): Promise<void>;
  getActiveServerId(): Promise<string>;
  setActiveServerId(id: string): Promise<void>;
  getSetting(key: string, defValue: string): Promise<string>;
  putSetting(key: string, value: string): Promise<void>;

  /**
   * 清空本机全部持久化数据：服务端列表、活动服务端 id、全部偏好项。
   * 仅供「撤回隐私授权」流程调用 —— 数据不可恢复。
   */
  clearAll(): Promise<void>;
}

const STORE_NAME: string = 'komari_client';
const KEY_SERVERS: string = 'servers';
const KEY_ACTIVE: string = 'active_server_id';

export class PreferencesServerStore implements ServerStore {
  private store: preferences.Preferences | undefined = undefined;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.store = await preferences.getPreferences(context, STORE_NAME);
  }

  private ensure(): preferences.Preferences {
    if (!this.store) {
      throw new Error('ServerStore 未初始化，请先在 EntryAbility 调用 init(context)');
    }
    return this.store;
  }

  async listServers(): Promise<ServerConfig[]> {
    const raw: string = await this.ensure().get(KEY_SERVERS, '[]') as string;
    try {
      const list: ServerConfig[] = JSON.parse(raw) as ServerConfig[];
      return list ?? [];
    } catch (e) {
      return [];
    }
  }

  async saveServer(cfg: ServerConfig): Promise<void> {
    const list: ServerConfig[] = await this.listServers();
    const idx: number = list.findIndex((item: ServerConfig): boolean => item.id === cfg.id);
    if (idx >= 0) {
      list[idx] = cfg;
    } else {
      list.push(cfg);
    }
    const store = this.ensure();
    await store.put(KEY_SERVERS, JSON.stringify(list));
    await store.flush();
  }

  async removeServer(id: string): Promise<void> {
    const list: ServerConfig[] = await this.listServers();
    const next: ServerConfig[] = list.filter((item: ServerConfig): boolean => item.id !== id);
    const store = this.ensure();
    await store.put(KEY_SERVERS, JSON.stringify(next));
    const active: string = await this.getActiveServerId();
    if (active === id) {
      await store.put(KEY_ACTIVE, next.length > 0 ? next[0].id : '');
    }
    await store.flush();
  }

  async getActiveServerId(): Promise<string> {
    return await this.ensure().get(KEY_ACTIVE, '') as string;
  }

  async setActiveServerId(id: string): Promise<void> {
    const store = this.ensure();
    await store.put(KEY_ACTIVE, id);
    await store.flush();
  }

  async getSetting(key: string, defValue: string): Promise<string> {
    return await this.ensure().get(key, defValue) as string;
  }

  async putSetting(key: string, value: string): Promise<void> {
    const store = this.ensure();
    await store.put(key, value);
    await store.flush();
  }

  /** 清空整个 Preferences 实例并落盘（撤回授权用） */
  async clearAll(): Promise<void> {
    const store = this.ensure();
    await store.clear();
    await store.flush();
  }
}

/** 供预览器使用；数据不落盘 */
export class MemoryServerStore implements ServerStore {
  private servers: ServerConfig[] = [];
  private active: string = '';
  private settings: Map<string, string> = new Map();

  async listServers(): Promise<ServerConfig[]> {
    return this.servers;
  }

  async saveServer(cfg: ServerConfig): Promise<void> {
    const idx: number = this.servers.findIndex((item: ServerConfig): boolean => item.id === cfg.id);
    if (idx >= 0) {
      this.servers[idx] = cfg;
    } else {
      this.servers.push(cfg);
    }
  }

  async removeServer(id: string): Promise<void> {
    this.servers = this.servers.filter((item: ServerConfig): boolean => item.id !== id);
  }

  async getActiveServerId(): Promise<string> {
    return this.active;
  }

  async setActiveServerId(id: string): Promise<void> {
    this.active = id;
  }

  async getSetting(key: string, defValue: string): Promise<string> {
    return this.settings.get(key) ?? defValue;
  }

  async putSetting(key: string, value: string): Promise<void> {
    this.settings.set(key, value);
  }

  async clearAll(): Promise<void> {
    this.servers = [];
    this.active = '';
    this.settings.clear();
  }
}

/** 由 host:port 生成稳定 id，避免大小写/末尾斜杠造成重复条目 */
export function makeServerId(baseUrl: string): string {
  let u: string = baseUrl.trim();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  return u.replace('https://', '').replace('http://', '').toLowerCase();
}

export function makeServerConfig(name: string, baseUrl: string, authMode: AuthMode): ServerConfig {
  return {
    id: makeServerId(baseUrl),
    name: name,
    baseUrl: baseUrl,
    authMode: authMode,
    username: '',
    rememberPassword: false
  };
}
