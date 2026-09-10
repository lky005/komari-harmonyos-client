/**
 * PrivacyRevoke —— 「撤回隐私授权」执行编排
 *
 * 入口：关于页 → 隐私说明下方「撤回隐私授权」→ 弹层红色按钮 → 二次确认
 *
 * 执行顺序（顺序有讲究）
 *   1. 先撤云端签署记录（PrivacyGate.revoke → privacyManager.disableService）
 *      失败即中止 —— 否则会出现「本机数据清了、云端授权还在」的矛盾态
 *   2. 清本机凭据（SecretStore：每个服务端的 会话 Token / 密码 / API Key）
 *      必须先做，因为第 3 步会清掉服务端列表，之后就取不到 serverId 了
 *   3. 清持久化配置（ServerStore.clearAll：服务端列表 + 活动 id + 全部偏好）
 *   4. 清缓存（NodeDataStore.purge 连落盘快照一起删；PingRecordStore 纯内存）
 *   5. ServiceRegistry.clearActive() 清内存中的活动服务端装配
 *
 * 容错原则
 *   - 第 1 步失败 → 整体中止，ok=false，**本机不做任何清理**
 *   - 第 2~5 步任一项失败 → 继续执行剩余项（尽力清干净），逐项记入 failures，
 *     由 UI 如实告知用户哪些没清掉，而不是假装成功
 *   - 全部清理幂等：SecretStore.remove 对不存在静默成功（24000002），
 *     NodeDataStore.purge 对无文件静默成功 → 重复执行安全
 *   - 未接入托管（1006700003）不算撤销失败，按 NOT_APPLICABLE 通过，
 *     否则开发期 / 未上架阶段无法验证该功能
 *
 * 相关文档：_local/docs/privacy-hosting-migration.md
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { PrivacyGate, RevokeState } from './PrivacyGate';
import { ServiceRegistry } from './ServiceRegistry';
import { NodeDataStore } from './NodeDataStore';
import { PingRecordStore } from './PingRecordStore';
import { KeyFactory, SecretStore } from '../storage/SecretStore';
import { ServerStore } from '../storage/ServerStore';
import { ServerConfig } from '../model/KomariTypes';

const DOMAIN = 0x0000;
const TAG = 'PrivacyRevoke';

/** 撤回执行结果 */
export interface RevokeOutcome {
  /** true = 可以退出应用；false = 云端撤销失败已中止，什么都没动 */
  ok: boolean;
  /** 云端撤销结果 */
  state: RevokeState;
  /** 本机清理失败项（人话，可直接展示给用户） */
  failures: string[];
}

export class PrivacyRevoke {
  /**
   * 执行完整撤回流程。
   * 调用方在 ok=true 时应追加 ServiceRegistry 的退出逻辑（terminateSelf）。
   */
  static async execute(): Promise<RevokeOutcome> {
    const failures: string[] = [];

    // —— 第 1 步：撤云端签署记录。失败即中止，本机不动
    const state: RevokeState = PrivacyGate.revoke();
    if (state === RevokeState.FAILED) {
      hilog.error(DOMAIN, TAG, '%{public}s', 'revoke failed, abort without wiping');
      return { ok: false, state: state, failures: failures };
    }

    // —— 第 2 步：清本机凭据（须在配置清理之前，否则取不到 serverId）
    try {
      const store: ServerStore = ServiceRegistry.getServerStore();
      const secrets: SecretStore = ServiceRegistry.getSecrets();
      const servers: ServerConfig[] = await store.listServers();
      for (let i = 0; i < servers.length; i++) {
        const id: string = servers[i].id;
        const label: string = servers[i].name;
        const aliases: string[] = [
          KeyFactory.sessionToken(id),
          KeyFactory.password(id),
          KeyFactory.apiKey(id)
        ];
        for (let j = 0; j < aliases.length; j++) {
          try {
            await secrets.remove(aliases[j]);
          } catch (e) {
            PrivacyRevoke.record(failures, `登录凭据未清除（${label}）`);
          }
        }
      }
    } catch (e) {
      PrivacyRevoke.record(failures, '读取服务端配置失败');
    }

    // —— 第 3 步：清持久化配置
    try {
      await ServiceRegistry.getServerStore().clearAll();
    } catch (e) {
      PrivacyRevoke.record(failures, '本机配置未清除');
    }

    // —— 第 4 步：清缓存
    try {
      await NodeDataStore.getInstance().purge();
    } catch (e) {
      PrivacyRevoke.record(failures, '节点缓存未清除');
    }
    try {
      PingRecordStore.getInstance().clear();
    } catch (e) {
      PrivacyRevoke.record(failures, 'Ping 记录未清除');
    }

    // —— 第 5 步：清内存中的活动服务端装配
    try {
      ServiceRegistry.clearActive();
    } catch (e) {
      PrivacyRevoke.record(failures, '会话引用未清除');
    }

    hilog.info(DOMAIN, TAG, 'revoke finished, failures=%{public}d', failures.length);
    return { ok: true, state: state, failures: failures };
  }

  /** 去重记录失败项，避免同名错误重复展示 */
  private static record(failures: string[], msg: string): void {
    if (failures.indexOf(msg) < 0) {
      failures.push(msg);
    }
  }
}
