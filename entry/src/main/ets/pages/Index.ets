/**
 * Index —— 启动路由页（Splash）
 *
 * 职责只有一件事：决定第一屏去哪。
 *   未同意《服务与隐私政策》→ 弹 PrivacyConsentSheet，等待用户选择
 *   无本地服务端配置 → ConnectPage
 *   有配置           → useServer + restore（自动重登/会话探测）→ MainPage
 *
 * 注意：
 *   - ServiceRegistry.ensureInit 必须在读取存储前调用，
 *     EntryAbility.onCreate 的 init 是异步的，可能晚于本页 aboutToAppear
 *   - 隐私闸门在路由之前：仅读本地存储的同意标记，未同意前不发任何
 *     网络请求（restore 的登录探测在同意后才会执行）
 *   - restore() 不抛网络异常（连不上按已登录放行），此处 catch 兜底进 ConnectPage
 */

import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { ServerConfig } from '../model/KomariTypes';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';
import { PrivacyPolicy } from '../common/constants/PrivacyPolicy';
import { PrivacyConsentSheet } from '../view/PrivacyConsentSheet';

@Entry
@Component
struct Index {
  @State tip: string = '正在启动…';
  @State privacyShow: boolean = false;

  aboutToAppear(): void {
    this.bootstrap();
  }

  /** 隐私弹层展示期间吞掉返回键/侧滑：必须做出选择才能离开 */
  onBackPress(): boolean {
    return this.privacyShow;
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await ServiceRegistry.ensureInit(ctx);
    // 注入 context 给 NodeDataStore（用于快照文件读写）
    NodeDataStore.getInstance().initContext(ctx);
    // 加载用户偏好配置（轮询频率/并发数）
    await NodeDataStore.getInstance().loadConfig();

    // 隐私闸门：只读本地存储的同意标记，未同意（或政策版本更新）→ 弹层等待
    let agreedVersion: string = '';
    try {
      agreedVersion = await ServiceRegistry.getServerStore().getSetting(PrivacyPolicy.AGREED_KEY, '');
    } catch (e) {
      // 读不到标记按未同意处理
    }
    if (agreedVersion !== PrivacyPolicy.VERSION) {
      this.privacyShow = true;
      return;
    }
    await this.routeAfterConsent();
  }

  /** 「同意」回调：落盘同意的版本号（失败不阻塞），收弹层并放行启动路由 */
  private async onAgreed(): Promise<void> {
    this.privacyShow = false;
    try {
      await ServiceRegistry.getServerStore().putSetting(PrivacyPolicy.AGREED_KEY, PrivacyPolicy.VERSION);
    } catch (e) {
      // 落盘失败不阻塞进入，下次启动会再弹一次
    }
    await this.routeAfterConsent();
  }

  /** 同意后的启动路由：有服务端配置走 restore 进主页，无则进引导页/空态主页 */
  private async routeAfterConsent(): Promise<void> {
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
      // 存储损坏等极端情况：退回连接页，不让应用卡死在启动页
      try {
        router.replaceUrl({ url: 'pages/ConnectPage' });
      } catch (e2) {
        // 忽略
      }
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Text('Komari')
          .fontSize(32)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.tip)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        LoadingProgress()
          .width(36)
          .height(36)
          .color($r('sys.color.ohos_id_color_emphasize'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)

      if (this.privacyShow) {
        PrivacyConsentSheet({ onAgree: (): void => {
          this.onAgreed();
        } })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
