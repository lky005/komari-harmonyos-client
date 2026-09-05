/**
 * SettingsPane —— 设置页（从 MainPage 物理拆分，2026-09-04）
 *
 * 职责：服务端信息展示、登录状态展示、服务端管理/登录/登出入口。
 * 与 MainPage 的关系：通过 pageRef 暴露 refreshAuthState() 和 getScroller()，
 * MainPage 在 onPageShow 时调用 refreshAuthState()，在 getCurrentScroller()
 * 中调用 getScroller() 参与 bindToScrollable 联动。
 *
 * 注意：本组件不是 @Entry，是 MainPage TabContent 的子组件。
 */

import { router } from '@kit.ArkUI';
import { SessionState } from '../service/AuthService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore, PollConfig } from '../common/NodeDataStore';

/** 分段选项定义 */
interface SegmentOption {
  label: string;
  value: number;
}

const LIST_INTERVAL_OPTIONS: SegmentOption[] = [
  { label: '极速 3s', value: 3000 },
  { label: '均衡 5s', value: 5000 },
  { label: '节能 10s', value: 10000 },
  { label: '极简 30s', value: 30000 }
];

const DETAIL_INTERVAL_OPTIONS: SegmentOption[] = [
  { label: '1s', value: 1000 },
  { label: '2s', value: 2000 },
  { label: '5s', value: 5000 }
];

const CONCURRENT_OPTIONS: SegmentOption[] = [
  { label: '2', value: 2 },
  { label: '3', value: 3 },
  { label: '4', value: 4 },
  { label: '5', value: 5 },
  { label: '6', value: 6 }
];

@Component
export struct SettingsPane {
  /** MainPage 持有此引用，用于调用 refreshAuthState / getScroller */
  pageRef: (p: SettingsPane) => void = (_p: SettingsPane): void => {};

  @State needsLogin: boolean = false;
  @State nearExpiry: boolean = false;
  @State authLabel: string = '';
  @State serverLabel: string = '';
  @State siteName: string = '';
  // 刷新与性能设置
  @State listIntervalIdx: number = 1;   // 默认均衡 5s
  @State detailIntervalIdx: number = 1; // 默认 2s
  @State concurrentIdx: number = 1;     // 默认 3

  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pageRef(this);
    this.refreshAuthState();
    this.loadPrefs();
  }

  /** 从 NodeDataStore 读取当前配置，初始化选中项 */
  private loadPrefs(): void {
    const cfg: PollConfig = NodeDataStore.getInstance().getConfig();
    this.listIntervalIdx = this.findIdx(LIST_INTERVAL_OPTIONS, cfg.listInterval, 1);
    this.detailIntervalIdx = this.findIdx(DETAIL_INTERVAL_OPTIONS, cfg.detailInterval, 1);
    this.concurrentIdx = this.findIdx(CONCURRENT_OPTIONS, cfg.maxConcurrent, 1);
  }

  private findIdx(options: SegmentOption[], value: number, fallback: number): number {
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === value) return i;
    }
    return fallback;
  }

  private onListIntervalChange(idx: number): void {
    this.listIntervalIdx = idx;
    NodeDataStore.getInstance().updateConfig({ listInterval: LIST_INTERVAL_OPTIONS[idx].value });
  }

  private onDetailIntervalChange(idx: number): void {
    this.detailIntervalIdx = idx;
    NodeDataStore.getInstance().updateConfig({ detailInterval: DETAIL_INTERVAL_OPTIONS[idx].value });
  }

  private onConcurrentChange(idx: number): void {
    this.concurrentIdx = idx;
    NodeDataStore.getInstance().updateConfig({ maxConcurrent: CONCURRENT_OPTIONS[idx].value });
  }

  aboutToDisappear(): void {
    this.pageRef = (_p: SettingsPane): void => {};
  }

  /** 供 MainPage 调用：刷新认证状态（从 AuthPage/ServerManagePage 返回时） */
  refreshAuthState(): void {
    try {
      const cfg = ServiceRegistry.getActiveConfig();
      const auth = ServiceRegistry.getAuth();
      const state: SessionState = auth.getState();
      this.needsLogin = state === SessionState.NeedsLogin;
      this.nearExpiry = state === SessionState.Authenticated && auth.isNearExpiry();
      if (state === SessionState.Authenticated) {
        this.authLabel = cfg && cfg.username.length > 0 ? cfg.username : '已登录';
      } else if (state === SessionState.Guest) {
        this.authLabel = '游客';
      } else if (state === SessionState.NeedsLogin) {
        this.authLabel = '未登录';
      } else {
        this.authLabel = '检测中…';
      }
      this.serverLabel = cfg ? cfg.baseUrl : '';
      this.siteName = cfg ? cfg.name : '';
    } catch (e) {
      this.needsLogin = true;
      this.authLabel = '未连接';
    }
  }

  /** 供 MainPage 调用：获取 scroller 参与 bindToScrollable 联动 */
  getScroller(): Scroller {
    return this.scroller;
  }

  private async doLogout(): Promise<void> {
    try {
      await ServiceRegistry.getAuth().logout();
    } catch (e) {
      // 本地已清理，不阻塞界面
    }
    this.refreshAuthState();
  }

  private openAuth(): void {
    router.pushUrl({ url: 'pages/AuthPage' });
  }

  private openServerManage(): void {
    router.pushUrl({ url: 'pages/ServerManagePage' });
  }

  build() {
    List({ scroller: this.scroller, space: 12 }) {
      ListItem() {
        Column({ space: 2 }) {
          Text('当前服务端')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Text(this.siteName.length > 0 ? this.siteName : this.serverLabel)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.serverLabel)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .padding(14)
        .borderRadius(20)
        .backgroundColor($r('app.color.card_bg'))
        .width('100%')
      }

      ListItem() {
        Column({ space: 2 }) {
          Text('登录状态')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Text(this.authLabel)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.needsLogin ? $r('app.color.status_bad') : $r('app.color.text_primary'))
            .width('100%')
          if (this.nearExpiry) {
            Text('登录状态即将过期，重新登录可获得 30 天会话')
              .fontSize(12)
              .fontColor($r('app.color.status_warn'))
              .width('100%')
          }
        }
        .padding(14)
        .borderRadius(20)
        .backgroundColor($r('app.color.card_bg'))
        .width('100%')
      }

      // ===== 刷新与性能设置 =====
      ListItem() {
        Column({ space: 14 }) {
          Text('刷新与性能')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          // 列表页刷新
          Column({ space: 6 }) {
            Text('列表页刷新')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Row({ space: 6 }) {
              ForEach(LIST_INTERVAL_OPTIONS, (opt: SegmentOption, idx: number) => {
                Text(opt.label)
                  .fontSize(12)
                  .fontColor(this.listIntervalIdx === idx ? Color.White : $r('app.color.text_secondary'))
                  .backgroundColor(this.listIntervalIdx === idx ? $r('app.color.accent') : $r('app.color.page_bg'))
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .borderRadius(8)
                  .layoutWeight(1)
                  .textAlign(TextAlign.Center)
                  .onClick((): void => {
                    this.onListIntervalChange(idx);
                  })
              }, (opt: SegmentOption) => opt.label + '_' + this.listIntervalIdx)
            }
            .width('100%')
          }
          .width('100%')

          // 详情页刷新
          Column({ space: 6 }) {
            Text('详情页刷新')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Row({ space: 6 }) {
              ForEach(DETAIL_INTERVAL_OPTIONS, (opt: SegmentOption, idx: number) => {
                Text(opt.label)
                  .fontSize(12)
                  .fontColor(this.detailIntervalIdx === idx ? Color.White : $r('app.color.text_secondary'))
                  .backgroundColor(this.detailIntervalIdx === idx ? $r('app.color.accent') : $r('app.color.page_bg'))
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .borderRadius(8)
                  .layoutWeight(1)
                  .textAlign(TextAlign.Center)
                  .onClick((): void => {
                    this.onDetailIntervalChange(idx);
                  })
              }, (opt: SegmentOption) => opt.label + '_' + this.detailIntervalIdx)
            }
            .width('100%')
          }
          .width('100%')

          // 最大并发
          Column({ space: 6 }) {
            Text('最大并发')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Row({ space: 6 }) {
              ForEach(CONCURRENT_OPTIONS, (opt: SegmentOption, idx: number) => {
                Text(opt.label)
                  .fontSize(12)
                  .fontColor(this.concurrentIdx === idx ? Color.White : $r('app.color.text_secondary'))
                  .backgroundColor(this.concurrentIdx === idx ? $r('app.color.accent') : $r('app.color.page_bg'))
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .borderRadius(8)
                  .layoutWeight(1)
                  .textAlign(TextAlign.Center)
                  .onClick((): void => {
                    this.onConcurrentChange(idx);
                  })
              }, (opt: SegmentOption) => opt.label + '_' + this.concurrentIdx)
            }
            .width('100%')
          }
          .width('100%')
        }
        .padding(14)
        .borderRadius(20)
        .backgroundColor($r('app.color.card_bg'))
        .width('100%')
      }

      ListItem() {
        Column({ space: 10 }) {
          Button('服务端管理 / 切换')
            .fontSize(15)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.accent'))
            .width('100%')
            .height(44)
            .onClick((): void => {
              this.openServerManage();
            })

          Button(this.needsLogin ? '登录' : '切换账号 / 使用 API Key')
            .fontSize(15)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.accent'))
            .width('100%')
            .height(44)
            .onClick((): void => {
              this.openAuth();
            })

          Button('退出登录')
            .fontSize(15)
            .fontColor($r('app.color.status_bad'))
            .backgroundColor($r('app.color.card_bg'))
            .width('100%')
            .height(44)
            .onClick((): void => {
              this.doLogout();
            })
        }
        .width('100%')
      }

      ListItem() {
        Text('离线重连提示、下拉刷新、卡片密度设置将在后续版本提供')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 96 })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .cachedCount(3, true)
    .clip(false)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

}
