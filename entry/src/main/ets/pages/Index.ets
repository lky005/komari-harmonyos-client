/**
 * Index —— 启动路由页（纯路由，**不渲染任何可见 UI**）
 *
 * 视觉上不承担开屏职责：冷启动时系统启动页（增强启动页，见
 * resources/base/profile/start_window.json）是**唯一**的开屏画面，
 * 本页只在系统启动页渐隐后露出版面底色，随后立即 replaceUrl 到目标页。
 * 因此本页不得添加标题、图标、转圈等任何元素 —— 加了就会变成「第二个开屏」。
 *
 * 加载反馈的归属：进入列表页之后由各页自己的加载/空态承担
 * （如 NodesPage 的「空状态 / 加载中」区块，含 LoadingProgress 与错误提示）。
 *
 * 隐私闸门（华为隐私托管）
 *   - 同意状态由 PrivacyGate 向系统查询，本页**不承载任何隐私声明 UI**
 *   - 未通过时静默停在原地等系统弹窗的签署结果公共事件，拿到同意后放行
 *   - 协议版本变更（REQUIRE_RESIGNING_VERSION_UPDATE）时**静默**拉起一次
 *     标准弹窗：官方文档未说明该场景系统是否会自动弹，不拉则可能卡在此页
 *   - 未接入隐私管理服务（本地 hdc 调试 / 未上架）时闸门自动放行
 *
 * 注意：
 *   - ServiceRegistry.ensureInit 必须在读取存储前调用，
 *     EntryAbility.onCreate 的 init 是异步的，可能晚于本页 aboutToAppear
 *   - 隐私闸门在路由之前：未同意前不发任何网络请求
 *     （restore 的登录探测在同意后才会执行）
 *   - restore() 不抛网络异常（连不上按已登录放行），此处 catch 兜底进 ConnectPage
 */

import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { ServerConfig } from '../model/KomariTypes';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';
import { PrivacyGate } from '../common/PrivacyGate';

@Entry
@Component
struct Index {
  /** 已放行启动路由：防止事件与快路径各走一次 */
  private routed: boolean = false;

  aboutToAppear(): void {
    // 事件可能在任意时刻到达（系统弹窗由用户操作决定），先注册回调
    PrivacyGate.onAgreed = (): void => {
      this.onConsentGranted();
    };
    this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await ServiceRegistry.ensureInit(ctx);
    // 注入 context 给 NodeDataStore（用于快照文件读写）
    NodeDataStore.getInstance().initContext(ctx);
    // 加载用户偏好配置（轮询频率/并发数）—— 本地 KV，不涉及网络与系统权限
    await NodeDataStore.getInstance().loadConfig();

    // 隐私闸门：未通过则留在本页等系统弹窗的签署结果事件（无任何界面反馈）
    if (!PrivacyGate.isAgreed()) {
      // 协议版本变更需重签：静默拉起标准弹窗，不赌系统会自动弹
      if (PrivacyGate.needsResign()) {
        await this.pullSystemConsent();
      }
      return;
    }
    await this.routeAfterConsent();
  }

  /**
   * 静默拉起系统标准隐私弹窗。
   * 本页不承担隐私告知职责，因此不成功也不做任何提示。
   */
  private async pullSystemConsent(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const agreed: boolean = await PrivacyGate.requestConsent(ctx);
    if (agreed) {
      this.onConsentGranted();
    }
  }

  /** 系统侧确认同意：放行启动路由 */
  private async onConsentGranted(): Promise<void> {
    if (this.routed) {
      return;
    }
    await this.routeAfterConsent();
  }

  /** 同意后的启动路由：有服务端配置走 restore 进主页，无则进引导页/空态主页 */
  private async routeAfterConsent(): Promise<void> {
    if (this.routed) {
      return;
    }
    this.routed = true;
    try {
      const store = ServiceRegistry.getServerStore();
      const servers: ServerConfig[] = await store.listServers();
      if (servers.length === 0) {
        // 用户在引导页跳过过配置 → 直接进主页（各 Tab 显示空态）；
        // 从未配置过 → 进引导页
        let onboarded: string = '';
        try {
          onboarded = await store.getSetting('onboarded', '');
        } catch (e) {
          // 读不到标记按未引导处理
        }
        if (onboarded === '1') {
          router.replaceUrl({ url: 'pages/MainPage' });
        } else {
          router.replaceUrl({ url: 'pages/ConnectPage' });
        }
        return;
      }
      const activeId: string = await store.getActiveServerId();
      let cfg: ServerConfig | undefined = undefined;
      servers.forEach((s: ServerConfig): void => {
        if (!cfg && s.id === activeId) {
          cfg = s;
        }
      });
      if (!cfg) {
        cfg = servers[0];
      }
      await ServiceRegistry.useServer(cfg);
      // 切换服务端：清空全局数据缓存，避免旧服务端数据残留
      NodeDataStore.getInstance().clear();
      // 加载该服务端的本地快照（冷启动秒开，后台静默联网校准）
      await NodeDataStore.getInstance().loadSnapshot(cfg.id);
      await ServiceRegistry.getAuth().restore();
      router.replaceUrl({ url: 'pages/MainPage' });
    } catch (e) {
      // 存储损坏等极端情况：退回连接页，不让应用卡死在本页
      try {
        router.replaceUrl({ url: 'pages/ConnectPage' });
      } catch (e2) {
        // 忽略
      }
    }
  }

  build() {
    // 纯底板：只铺与启动页一致的底色，不放任何元素。
    // 底色与 start_window_background 保持一致（见 resources/base/element/color.json），
    // 系统启动页 200ms 渐隐后看不出画面切换，视觉上只有一个开屏。
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
