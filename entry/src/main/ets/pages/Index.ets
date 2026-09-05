/**
 * Index —— 启动路由页（Splash）
 *
 * 职责只有一件事：决定第一屏去哪。
 *   无本地服务端配置 → ConnectPage
 *   有配置           → useServer + restore（自动重登/会话探测）→ MainPage
 *
 * 注意：
 *   - ServiceRegistry.ensureInit 必须在读取存储前调用，
 *     EntryAbility.onCreate 的 init 是异步的，可能晚于本页 aboutToAppear
 *   - restore() 不抛网络异常（连不上按已登录放行），此处 catch 兜底进 ConnectPage
 */

import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { ServerConfig } from '../model/KomariTypes';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';

@Entry
@Component
struct Index {
  @State tip: string = '正在启动…';

  aboutToAppear(): void {
    this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await ServiceRegistry.ensureInit(ctx);
    // 注入 context 给 NodeDataStore（用于快照文件读写）
    NodeDataStore.getInstance().initContext(ctx);
    // 加载用户偏好配置（轮询频率/并发数）
    await NodeDataStore.getInstance().loadConfig();
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
        .color($r('app.color.accent'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
