/**
 * ServiceRegistry —— 全局装配点
 *
 * 所有页面从这里取服务，不要自己 new。
 * 目的是让"换实现"只改这一个文件：
 *   换存储 → 改 init 里的 SecretStore / ServerStore 实现
 *   换传输 → 改 HttpRpcClient
 *   换鉴权 → 改 AuthService
 *
 * 使用：
 *   1. EntryAbility.onCreate 里 await ServiceRegistry.init(context)
 *   2. 业务里 ServiceRegistry.getApi() / getAuth() / getServerStore()
 */

import { common } from '@kit.AbilityKit';
import { AuthService } from '../service/AuthService';
import { HeaderProvider, HttpRpcClient, RpcClient } from '../service/RpcClient';
import { KomariApi } from '../service/KomariApi';
import { AssetSecretStore, SecretStore } from '../storage/SecretStore';
import { PreferencesServerStore, ServerStore } from '../storage/ServerStore';
import { AuthMode, ServerConfig } from '../model/KomariTypes';

export class ServiceRegistry {
  private static serverStore: ServerStore | undefined = undefined;
  private static secrets: SecretStore | undefined = undefined;
  private static rpc: RpcClient | undefined = undefined;
  private static api: KomariApi | undefined = undefined;
  private static auth: AuthService | undefined = undefined;
  private static activeConfig: ServerConfig | undefined = undefined;

  /**
   * 必须在 EntryAbility 中调用一次。
   * 幂等：重复调用不会重建存储（EntryAbility 与首页都可能触发）。
   */
  static async init(context: common.UIAbilityContext): Promise<void> {
    if (ServiceRegistry.serverStore && ServiceRegistry.secrets) {
      return;
    }
    const store = new PreferencesServerStore();
    await store.init(context);
    ServiceRegistry.serverStore = store;
    ServiceRegistry.secrets = new AssetSecretStore();
  }

  /**
   * 供首页使用：不关心 EntryAbility 是否已完成初始化，调用即保证可用。
   * onCreate 里的 init 是异步的，loadContent 后首页可能先于它完成，
   * 直接依赖 getServerStore() 会偶发"未初始化"。
   */
  static async ensureInit(context: common.UIAbilityContext): Promise<void> {
    await ServiceRegistry.init(context);
  }

  /** 供预览器使用：不依赖真实 context */
  static initForPreview(serverStore: ServerStore, secrets: SecretStore): void {
    ServiceRegistry.serverStore = serverStore;
    ServiceRegistry.secrets = secrets;
  }

  static getServerStore(): ServerStore {
    if (!ServiceRegistry.serverStore) {
      throw new Error('ServiceRegistry 未初始化');
    }
    return ServiceRegistry.serverStore;
  }

  static getSecrets(): SecretStore {
    if (!ServiceRegistry.secrets) {
      throw new Error('ServiceRegistry 未初始化');
    }
    return ServiceRegistry.secrets;
  }

  /**
   * 切换到指定服务端，重建 rpc / api / auth 三件套。
   * 切换服务端时必须调用，否则请求会打到旧地址。
   */
  static async useServer(config: ServerConfig): Promise<AuthService> {
    const secrets: SecretStore = ServiceRegistry.getSecrets();

    // AuthService 需要 RpcClient，而 RpcClient 的鉴权头又来自 AuthService。
    // 用一层可变闭包打破循环：先给空实现，AuthService 建好后再替换。
    let provider: HeaderProvider = (): Record<string, string> => {
      return {} as Record<string, string>;
    };
    const rpc = new HttpRpcClient(config.baseUrl, (): Record<string, string> => provider());
    const api = new KomariApi(rpc);
    const auth = new AuthService(config, rpc, api, secrets);
    provider = (): Record<string, string> => auth.buildHeaders();

    ServiceRegistry.rpc = rpc;
    ServiceRegistry.api = api;
    ServiceRegistry.auth = auth;
    ServiceRegistry.activeConfig = config;

    await ServiceRegistry.getServerStore().setActiveServerId(config.id);
    return auth;
  }

  static getApi(): KomariApi {
    if (!ServiceRegistry.api) {
      throw new Error('尚未选择服务端，请先调用 useServer()');
    }
    return ServiceRegistry.api;
  }

  static getAuth(): AuthService {
    if (!ServiceRegistry.auth) {
      throw new Error('尚未选择服务端，请先调用 useServer()');
    }
    return ServiceRegistry.auth;
  }

  static getActiveConfig(): ServerConfig | undefined {
    return ServiceRegistry.activeConfig;
  }
}
