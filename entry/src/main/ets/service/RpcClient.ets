/**
 * RpcClient —— 所有与 Komari 服务端通信的唯一出口
 *
 * 设计要点：
 *   - 业务层只依赖 RpcClient 接口，不依赖具体实现，便于以后换传输方式
 *   - 鉴权头由外部注入（authHeaders 回调），RpcClient 自身不持有凭据
 *   - 服务端几乎全部 JSON 接口都收敛到 POST /api/rpc2，故只需一个 call 方法
 *
 * 维护约定：
 *   - 不要在各页面里直接 new HttpRpcClient，统一从 ServiceRegistry 取
 *   - 新增接口只需在 KomariApi.ets 加方法，本文件通常不用改
 */

import { http } from '@kit.NetworkKit';
import { JsonRpcRequest, JsonRpcResponse } from '../model/KomariTypes';

/** JSON-RPC 标准错误码 + Komari 自定义错误码 */
export class RpcCode {
  static readonly PARSE_ERROR: number = -32700;
  static readonly INVALID_REQUEST: number = -32600;
  static readonly METHOD_NOT_FOUND: number = -32601;
  static readonly INVALID_PARAMS: number = -32602;
  static readonly INTERNAL_ERROR: number = -32603;
  /** 权限不足或登录态失效，AuthService 依赖此码触发重新登录 */
  static readonly PERMISSION_DENIED: number = -32041;
}

/**
 * ArkTS 规定 throw 只能抛 Error 及其子类（arkts-limited-throw），
 * 所以 RpcException 必须继承 Error，不能是普通 class。
 */
export class RpcException extends Error {
  code: number;
  message: string;
  /** HTTP 层失败（连不上、超时）时为 true，业务层错误时为 false */
  transport: boolean;

  constructor(code: number, message: string, transport: boolean) {
    super(message);
    this.name = 'RpcException';
    this.code = code;
    this.message = message;
    this.transport = transport;
  }

  isPermissionDenied(): boolean {
    return this.code === RpcCode.PERMISSION_DENIED;
  }
}

/**
 * 鉴权头注入器。返回需要附加到每次请求上的头。
 * 由 AuthService 实现，RpcClient 只负责搬运，不关心凭据从哪来。
 */
export type HeaderProvider = () => Record<string, string>;

/** Komari 的传统 REST 响应包络（{ status, message, data }） */
export interface RestResponse<T> {
  status: string;
  message: string;
  data: T;
}

export interface RpcClient {
  /** JSON-RPC 2.0 调用，走 /api/rpc2 */
  call<T>(method: string, params?: Object): Promise<T>;
  /**
   * 原生 REST 调用，仅用于少数不走 RPC 桥的接口（登录 / 登出）
   * 新接口不要走这里，优先用 call
   */
  postJson<T>(path: string, body: Object): Promise<RestResponse<T>>;
  /** 只关心状态码的 GET，用于登出（服务端返回 302，不跟随跳转） */
  getStatus(path: string): Promise<number>;
  getBaseUrl(): string;
}

export class HttpRpcClient implements RpcClient {
  private baseUrl: string;
  private headerProvider: HeaderProvider;
  private timeoutMs: number;
  private idSeq: number = 1;
  /** 最近一次 call() 收到的 HTTP 状态码（请求异常时为 0），供连通性测试展示 */
  lastStatus: number = 0;

  constructor(baseUrl: string, headerProvider: HeaderProvider, timeoutMs: number = 10000) {
    this.baseUrl = this.normalize(baseUrl);
    this.headerProvider = headerProvider;
    this.timeoutMs = timeoutMs;
  }

  /** 去掉末尾斜杠，避免拼出 //api/rpc2 */
  private normalize(url: string): string {
    let u: string = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  getBaseUrl(): string {
    return this.baseUrl;
  }

  // params 必须是可选参数：ArkTS 不允许用未声明类型的对象字面量 {} 作默认值
  // （arkts-no-untyped-obj-literals）
  async call<T>(method: string, params?: Object): Promise<T> {
    const envelope: JsonRpcRequest = {
      jsonrpc: '2.0',
      method: method,
      params: params,
      id: this.idSeq++
    };

    const header: Record<string, string> = {
      'Content-Type': 'application/json'
    };
    const injected: Record<string, string> = this.headerProvider();
    // ArkTS 不支持对象展开合并 Record，逐条拷贝
    Object.keys(injected).forEach((k: string): void => {
      header[k] = injected[k];
    });

    const req = http.createHttp();
    let raw: string = '';
    let code: number = 0;

    try {
      const res = await req.request(`${this.baseUrl}/api/rpc2`, {
        method: http.RequestMethod.POST,
        header: header,
        extraData: JSON.stringify(envelope),
        connectTimeout: this.timeoutMs,
        readTimeout: this.timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });
      code = res.responseCode;
      this.lastStatus = code;
      raw = typeof res.result === 'string' ? res.result : '';
    } catch (e) {
      const err = e as Error;
      throw new RpcException(0, `网络请求失败: ${err?.message ?? 'unknown'}`, true);
    } finally {
      req.destroy();
    }

    if (code < 200 || code >= 300) {
      throw new RpcException(code, `HTTP ${code}`, true);
    }
    if (raw.length === 0) {
      throw new RpcException(0, '服务端返回空响应', true);
    }

    let parsed: JsonRpcResponse<T>;
    try {
      parsed = JSON.parse(raw) as JsonRpcResponse<T>;
    } catch (e) {
      throw new RpcException(RpcCode.PARSE_ERROR, '响应不是合法 JSON', true);
    }

    if (parsed.error) {
      throw new RpcException(parsed.error.code, parsed.error.message, false);
    }
    return parsed.result;
  }

  async postJson<T>(path: string, body: Object): Promise<RestResponse<T>> {
    const header: Record<string, string> = {
      'Content-Type': 'application/json'
    };
    const injected: Record<string, string> = this.headerProvider();
    Object.keys(injected).forEach((k: string): void => {
      header[k] = injected[k];
    });

    const req = http.createHttp();
    let raw: string = '';
    let code: number = 0;

    try {
      const res = await req.request(`${this.baseUrl}${path}`, {
        method: http.RequestMethod.POST,
        header: header,
        extraData: JSON.stringify(body),
        connectTimeout: this.timeoutMs,
        readTimeout: this.timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });
      code = res.responseCode;
      raw = typeof res.result === 'string' ? res.result : '';
    } catch (e) {
      const err = e as Error;
      throw new RpcException(0, `网络请求失败: ${err?.message ?? 'unknown'}`, true);
    } finally {
      req.destroy();
    }

    if (code < 200 || code >= 300) {
      throw new RpcException(code, `HTTP ${code}`, true);
    }
    if (raw.length === 0) {
      throw new RpcException(0, '服务端返回空响应', true);
    }
    return JSON.parse(raw) as RestResponse<T>;
  }

  async getStatus(path: string): Promise<number> {
    const header: Record<string, string> = {};
    const injected: Record<string, string> = this.headerProvider();
    Object.keys(injected).forEach((k: string): void => {
      header[k] = injected[k];
    });

    const req = http.createHttp();
    try {
      const res = await req.request(`${this.baseUrl}${path}`, {
        method: http.RequestMethod.GET,
        header: header,
        connectTimeout: this.timeoutMs,
        readTimeout: this.timeoutMs,
        expectDataType: http.HttpDataType.STRING
      });
      return res.responseCode;
    } catch (e) {
      const err = e as Error;
      throw new RpcException(0, `网络请求失败: ${err?.message ?? 'unknown'}`, true);
    } finally {
      req.destroy();
    }
  }
}
