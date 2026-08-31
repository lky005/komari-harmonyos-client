/**
 * SecretStore —— 敏感凭据存储
 *
 * 存 session_token / 密码 / API Key 这类泄露即失控的数据。
 * 不要用它存任何非敏感配置，那些走 ServerStore。
 *
 * 设计要点：
 *   - 业务层只依赖 SecretStore 接口
 *   - AssetSecretStore 走系统级加密（关键资产存储）
 *   - MemorySecretStore 仅用于预览器与单测，禁止用于生产
 *
 * 维护约定：
 *   - alias 统一由 KeyFactory 生成，带服务端 id 前缀做多实例隔离
 *   - 卸载应用会清空 Asset，这是系统行为，不要试图绕过
 */

import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

export interface SecretStore {
  /** 写入或覆盖 */
  put(alias: string, secret: string): Promise<void>;
  /** 不存在时返回空串 */
  get(alias: string): Promise<string>;
  remove(alias: string): Promise<void>;
}

/** alias 生成规则，多服务端靠 serverId 隔离 */
export class KeyFactory {
  static sessionToken(serverId: string): string {
    return `komari_${serverId}_session`;
  }

  static password(serverId: string): string {
    return `komari_${serverId}_password`;
  }

  static apiKey(serverId: string): string {
    return `komari_${serverId}_apikey`;
  }
}

export class AssetSecretStore implements SecretStore {
  private encoder: util.TextEncoder = new util.TextEncoder();
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');

  private toBytes(s: string): Uint8Array {
    return this.encoder.encodeInto(s);
  }

  private toString(b: Uint8Array): string {
    return this.decoder.decodeToString(b);
  }

  async put(alias: string, secret: string): Promise<void> {
    const attr: asset.AssetMap = new Map();
    attr.set(asset.Tag.SECRET, this.toBytes(secret));
    attr.set(asset.Tag.ALIAS, this.toBytes(alias));
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attr.set(asset.Tag.DATA_LABEL_NORMAL_1, this.toBytes('komari'));

    try {
      await asset.add(attr);
    } catch (e) {
      // 已存在则更新，Asset 没有 upsert
      const err = e as BusinessError;
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, this.toBytes(alias));
      const update: asset.AssetMap = new Map();
      update.set(asset.Tag.SECRET, this.toBytes(secret));
      try {
        await asset.update(query, update);
      } catch (e2) {
        const err2 = e2 as BusinessError;
        throw new Error(`写入凭据失败: ${err2.code} (add: ${err.code})`);
      }
    }
  }

  async get(alias: string): Promise<string> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.toBytes(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);

    try {
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results.length === 0) {
        return '';
      }
      const secret = results[0].get(asset.Tag.SECRET) as Uint8Array;
      if (!secret) {
        return '';
      }
      return this.toString(secret);
    } catch (e) {
      const err = e as BusinessError;
      // 查不到不算错误，返回空串让调用方走登录流程
      if (err.code === 24000002) {
        return '';
      }
      throw new Error(`读取凭据失败: ${err.code}`);
    }
  }

  async remove(alias: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.toBytes(alias));
    try {
      await asset.remove(query);
    } catch (e) {
      const err = e as BusinessError;
      // 不存在时静默成功
      if (err.code !== 24000002) {
        throw new Error(`删除凭据失败: ${err.code}`);
      }
    }
  }
}

/** 仅供预览器与单测；数据不落盘，进程退出即失效 */
export class MemorySecretStore implements SecretStore {
  private map: Map<string, string> = new Map();

  async put(alias: string, secret: string): Promise<void> {
    this.map.set(alias, secret);
  }

  async get(alias: string): Promise<string> {
    return this.map.get(alias) ?? '';
  }

  async remove(alias: string): Promise<void> {
    this.map.delete(alias);
  }
}
