import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';
import { NetworkMonitor } from '../common/NetworkMonitor';
import { AppKeys } from '../common/constants/AppKeys';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // 注入 context 给 NodeDataStore（用于快照文件读写）
    NodeDataStore.getInstance().initContext(this.context);
    // 启动网络状态监听（断连自愈）
    NetworkMonitor.getInstance().start();
    // 尽早预热存储（幂等；首页 ensureInit 会兜底，不依赖此调用完成）
    ServiceRegistry.init(this.context).catch((err: Error): void => {
      hilog.error(DOMAIN, 'testTag', 'ServiceRegistry init failed: %{public}s', err.message);
    });
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  private mainWindow: window.Window | null = null;

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 优先初始化沉浸式全屏与避让区，避免加载首屏时的尺寸跳跃与闪烁
    this.setupImmersiveWindow(windowStage).then((): void => {
      windowStage.loadContent('pages/Index', (err) => {
        if (err && err.code !== undefined && err.code !== 0) {
          hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      });
    }).catch((e: Error): void => {
      hilog.warn(DOMAIN, 'testTag', 'setupImmersiveWindow failed, fallback loadContent: %{public}s', JSON.stringify(e));
      windowStage.loadContent('pages/Index');
    });
  }

  /**
   * 沉浸光感核心（对齐 API24 规范）：
   *  - async/await 顺序获取主窗口并开启全屏布局（避免并行时序导致沉浸式失效）
   *  - setWindowLayoutFullScreen(true) 内容延伸到状态栏/导航栏区域，系统栏透明
   *  - 动态获取状态栏高度（px→vp）写入 AppStorage，供页面精确计算顶部占位
   *  - on('avoidAreaChange') 监听避让区变化（旋转/折叠）实时更新
   */
  private async setupImmersiveWindow(windowStage: window.WindowStage): Promise<void> {
    try {
      const win: window.Window = await windowStage.getMainWindow();
      this.mainWindow = win;

      try {
        await win.setWindowLayoutFullScreen(true);
        hilog.info(DOMAIN, 'testTag', 'setWindowLayoutFullScreen ok');
      } catch (e) {
        hilog.warn(DOMAIN, 'testTag', 'setWindowLayoutFullScreen fail: %{public}s', JSON.stringify(e));
      }

      this.applySystemBarInk(win);
      this.refreshAvoidArea(win);

      try {
        win.on('avoidAreaChange', (data: window.AvoidAreaOptions): void => {
          this.applyAvoidArea(win, data.type, data.area);
        });
      } catch (e) {
        hilog.warn(DOMAIN, 'testTag', 'on avoidAreaChange fail: %{public}s', JSON.stringify(e));
      }
    } catch (e) {
      hilog.warn(DOMAIN, 'testTag', 'setupImmersiveWindow fail: %{public}s', JSON.stringify(e));
    }
  }

  /** 透明系统栏 + 前景墨色随深浅色模式 */
  private applySystemBarInk(win: window.Window): void {
    const isDark: boolean =
      this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const ink: string = isDark ? '#FFFFFFFF' : '#FF000000';
    win.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      navigationBarColor: '#00000000',
      statusBarContentColor: ink,
      navigationBarContentColor: ink
    } as window.SystemBarProperties).catch((e: Error): void => {
      hilog.warn(DOMAIN, 'testTag', 'setSystemBar fail: %{public}s', JSON.stringify(e));
    });
  }

  /** 读取当前避让区并写入 AppStorage */
  private refreshAvoidArea(win: window.Window): void {
    try {
      const sysArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.applyAvoidArea(win, window.AvoidAreaType.TYPE_SYSTEM, sysArea);
    } catch (e) {
      hilog.warn(DOMAIN, 'testTag', 'getWindowAvoidArea TYPE_SYSTEM fail: %{public}s', JSON.stringify(e));
      AppStorage.setOrCreate(AppKeys.STATUS_BAR_HEIGHT, 32);
    }
    try {
      const navArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.applyAvoidArea(win, window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR, navArea);
    } catch (e) {
      hilog.warn(DOMAIN, 'testTag', 'getWindowAvoidArea TYPE_NAVIGATION_INDICATOR fail: %{public}s', JSON.stringify(e));
      AppStorage.setOrCreate(AppKeys.NAV_INDICATOR_HEIGHT, 0);
    }
  }

  /** AvoidArea 像素高度转 vp 写入 AppStorage */
  private applyAvoidArea(win: window.Window, type: window.AvoidAreaType, area: window.AvoidArea): void {
    try {
      const topPx: number = area.topRect ? area.topRect.height : 0;
      const bottomPx: number = area.bottomRect ? area.bottomRect.height : 0;
      if (type === window.AvoidAreaType.TYPE_SYSTEM) {
        const topVp: number = win.getUIContext().px2vp(topPx);
        AppStorage.setOrCreate(AppKeys.STATUS_BAR_HEIGHT, topVp);
        hilog.info(DOMAIN, 'testTag', 'status bar height = %{public}s vp', `${topVp}`);
      } else if (type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
        const bottomVp: number = win.getUIContext().px2vp(bottomPx);
        AppStorage.setOrCreate(AppKeys.NAV_INDICATOR_HEIGHT, bottomVp);
      }
    } catch (e) {
      hilog.warn(DOMAIN, 'testTag', 'applyAvoidArea fail: %{public}s', JSON.stringify(e));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
    if (this.mainWindow) {
      try {
        this.mainWindow.off('avoidAreaChange');
      } catch (e) {
        hilog.warn(DOMAIN, 'testTag', 'off avoidAreaChange fail: %{public}s', JSON.stringify(e));
      }
      this.mainWindow = null;
    }
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    // 恢复全局数据仓库的前台状态，各页面轮询会自动恢复
    NodeDataStore.getInstance().setForeground(true);
    AppStorage.setOrCreate(AppKeys.APP_FOREGROUND, true);
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // 标记为后台，各页面轮询会跳过请求（定时器保留，切回前台自动恢复）
    NodeDataStore.getInstance().setForeground(false);
    AppStorage.setOrCreate(AppKeys.APP_FOREGROUND, false);
  }
}
