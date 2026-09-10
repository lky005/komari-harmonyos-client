/**
 * PrivacyGate —— 华为「标准化隐私声明托管服务」统一接入层
 *
 * 背景
 *   应用已在 AGC 启用隐私托管。系统会在首次打开 / 用户撤销同意后，
 *   自动弹出华为标准隐私弹窗。官方要求「勿在应用内自行实现弹窗展示
 *   隐私声明，否则发布审核将被驳回」，故原自建首启弹层
 *   PrivacyConsentSheet 已下线（文件保留，未挂载）。
 *
 * 本层职责
 *   1. isAgreed()        查询系统签署状态 —— 取代原 ServerStore.AGREED_KEY 自管标记
 *   2. needsResign()     协议版本变更、需用户重新签署
 *   3. subscribe()       监听系统弹窗签署结果公共事件，拿到「同意」时刻
 *   4. requestConsent()  主动拉起标准弹窗（重签、或用户首次拒绝后重试）
 *   5. revoke()          撤销同意记录（设置页「撤回隐私同意」用）
 *   6. getPolicyUrl()    取托管的隐私声明链接，供关于页桥接（免硬编码）
 *
 * 闸门语义（合规红线，沿用原实现）
 *   未取得同意前，只读本地存储，不发任何网络请求、不申请任何系统权限。
 *
 * 错误码（见 @hms.core.appgalleryservice.privacyManager.d.ts）
 *   1006700001 系统内部错误
 *   1006700002 指定的服务扩展连接失败
 *   1006700003 应用未接入隐私管理服务 —— 本地 hdc 调试 / 未上架时必然出现，
 *              此时云侧无托管配置，视为「无闸门」放行，避免开发期卡死。
 *   其余异常保守拦截（不联网），由 UI 提供重试入口。
 *
 * 相关文档：_local/docs/privacy-hosting-migration.md
 */

import { common } from '@kit.AbilityKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { privacyManager } from '@kit.AppGalleryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'PrivacyGate';

/** 隐私弹框签署结果公共事件 */
const EVENT_PRIVACY_STATE_CHANGED: string = 'usual.event.PRIVACY_STATE_CHANGED';

/** 1006700003：应用未接入隐私管理服务 */
const ERR_NOT_INTEGRATED: number = 1006700003;

/** 公共事件载荷：{ resultType, appIndex } */
interface PrivacyEventPayload {
  /** 1=同意完整模式，0=未同意 */
  resultType?: number;
  /** 应用分身索引，非分身场景为 0 */
  appIndex?: number;
}

/** 撤销同意记录的结果 */
export enum RevokeState {
  /** 云端签署记录已撤销 */
  DONE = 0,
  /** 应用未接入托管，无记录可撤（按通过处理） */
  NOT_APPLICABLE = 1,
  /** 撤销失败 —— 调用方应中止后续清理，避免"数据清了授权还在" */
  FAILED = 2
}

export class PrivacyGate {
  /** 宿主注册的「已同意」回调（Index 启动页据此放行启动路由） */
  static onAgreed: () => void = (): void => {};

  private static subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  private static appCloneIndex: number = 0;
  private static inited: boolean = false;
  /** 托管隐私声明链接缓存（一次查询即可，短期不变） */
  private static cachedPolicyUrl: string = '';

  /**
   * 初始化：记录分身索引 + 订阅签署结果事件。
   * 应在 EntryAbility.onCreate 调用一次（早订阅，避免漏事件）。
   */
  static init(ctx: common.UIAbilityContext): void {
    if (PrivacyGate.inited) {
      return;
    }
    PrivacyGate.inited = true;
    try {
      PrivacyGate.appCloneIndex = ctx.getApplicationContext().getCurrentAppCloneIndex();
    } catch (e) {
      // 取不到按非分身处理
      PrivacyGate.appCloneIndex = 0;
    }
    PrivacyGate.ensureSubscriber();
  }

  /**
   * 查询系统签署状态。
   *   true  = 已同意完整模式 → 放行
   *   false = 未同意 / 需重新签署 / 查询异常 → 拦截
   * 未接入隐私管理服务（1006700003）→ 无闸门，放行。
   */
  static isAgreed(): boolean {
    try {
      const results: privacyManager.AppPrivacyResult[] = privacyManager.getAppPrivacyResult();
      for (let i = 0; i < results.length; i++) {
        const r: privacyManager.AppPrivacyResult = results[i];
        if (r.type === privacyManager.AppPrivacyType.PRIVACY_AGREEMENT) {
          return r.result === privacyManager.AppPrivacyResultType.FULL_MODE_AGREED;
        }
      }
      // 未返回隐私协议项：按未同意处理
      return false;
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === ERR_NOT_INTEGRATED) {
        hilog.info(DOMAIN, TAG, '%{public}s', 'privacy service not integrated, gate disabled');
        return true;
      }
      hilog.error(DOMAIN, TAG, 'getAppPrivacyResult failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /** 协议发生变更、需要重新签署？读不到或未接入返回 false */
  static needsResign(): boolean {
    try {
      const results: privacyManager.AppPrivacyResult[] = privacyManager.getAppPrivacyResult();
      for (let i = 0; i < results.length; i++) {
        const r: privacyManager.AppPrivacyResult = results[i];
        if (r.type === privacyManager.AppPrivacyType.PRIVACY_AGREEMENT) {
          return r.result === privacyManager.AppPrivacyResultType.REQUIRE_RESIGNING_VERSION_UPDATE;
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /**
   * 主动拉起系统标准隐私弹窗。
   * 用于两种情况：①协议版本变更需重签 ②用户首次拒绝后主动重试。
   * 返回是否已取得「同意完整模式」。
   */
  static async requestConsent(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      const consent: privacyManager.ConsentResult = await privacyManager.requestAppPrivacyConsent(ctx);
      const results: privacyManager.AppPrivacyResult[] = consent.results;
      for (let i = 0; i < results.length; i++) {
        const r: privacyManager.AppPrivacyResult = results[i];
        if (r.type === privacyManager.AppPrivacyType.PRIVACY_AGREEMENT) {
          return r.result === privacyManager.AppPrivacyResultType.FULL_MODE_AGREED;
        }
      }
      return false;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'requestAppPrivacyConsent failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  /**
   * 撤销同意记录（云端签署记录）。
   * 撤销后再次打开应用会重新弹出标准隐私弹窗。
   */
  static revoke(): RevokeState {
    try {
      privacyManager.disableService();
      PrivacyGate.cachedPolicyUrl = '';
      return RevokeState.DONE;
    } catch (e) {
      const err = e as BusinessError;
      // 未接入托管（未上架 / 云侧未开启）时无记录可撤 —— 不是失败
      if (err.code === ERR_NOT_INTEGRATED) {
        hilog.info(DOMAIN, TAG, '%{public}s', 'privacy service not integrated, nothing to revoke');
        return RevokeState.NOT_APPLICABLE;
      }
      hilog.error(DOMAIN, TAG, 'disableService failed: %{public}s', JSON.stringify(e));
      return RevokeState.FAILED;
    }
  }

  /**
   * 取托管的隐私声明链接。失败返回空串，调用方回退到本地常量。
   * 用动态取值而非硬编码：AGC 侧重建设协议后旧 agreementId 会失效。
   */
  static getPolicyUrl(): string {
    if (PrivacyGate.cachedPolicyUrl.length > 0) {
      return PrivacyGate.cachedPolicyUrl;
    }
    try {
      const info: privacyManager.AppPrivacyMgmtInfo = privacyManager.getAppPrivacyMgmtInfo();
      const links: privacyManager.AppPrivacyLink[] = info.privacyInfo;
      for (let i = 0; i < links.length; i++) {
        const link: privacyManager.AppPrivacyLink = links[i];
        if (link.type === privacyManager.AppPrivacyLinkType.PRIVACY_STATEMENT_LINK && link.url.length > 0) {
          PrivacyGate.cachedPolicyUrl = link.url;
          return link.url;
        }
      }
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'getAppPrivacyMgmtInfo unavailable: %{public}s', JSON.stringify(e));
    }
    return '';
  }

  /** 订阅签署结果公共事件（幂等，只建一次） */
  private static ensureSubscriber(): void {
    if (PrivacyGate.subscriber !== undefined) {
      return;
    }
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [EVENT_PRIVACY_STATE_CHANGED]
    };
    commonEventManager.createSubscriber(info)
      .then((sub: commonEventManager.CommonEventSubscriber): void => {
        PrivacyGate.subscriber = sub;
        try {
          commonEventManager.subscribe(sub,
            (err: BusinessError, data: commonEventManager.CommonEventData): void => {
              if (err) {
                hilog.error(DOMAIN, TAG, 'subscribe callback error: %{public}s', JSON.stringify(err));
                return;
              }
              const payload: PrivacyEventPayload =
                JSON.parse(data?.data ?? '{}') as PrivacyEventPayload;
              // 分身场景：只认本实例的事件
              if ((payload.appIndex ?? 0) !== PrivacyGate.appCloneIndex) {
                return;
              }
              // 1 = 同意完整模式
              if ((payload.resultType ?? 0) === 1) {
                PrivacyGate.onAgreed();
              }
            });
        } catch (e) {
          hilog.error(DOMAIN, TAG, 'subscribe failed: %{public}s', JSON.stringify(e));
        }
      })
      .catch((e: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'createSubscriber failed: %{public}s', JSON.stringify(e));
      });
  }
}
