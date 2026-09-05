/**
 * SettingsPane —— 设置页（从 MainPage 物理拆分，2026-09-04；2026-09-06 重组）
 *
 * 职责：只做「展示 + 入口」——
 *   当前服务端 / 登录状态两张展示卡；
 *   管理我的服务端（服务端列表 + 编辑弹层，切换与账号一体）独立入口卡；
 *   刷新与性能迁到独立二级页 RefreshPerfPage。
 * 与 MainPage 的关系：通过 pageRef 暴露 refreshAuthState() 和 getScroller()，
 * MainPage 在 onPageShow 时调用 refreshAuthState()，在 getCurrentScroller()
 * 中调用 getScroller() 参与 bindToScrollable 联动。
 *
 * 注意：本组件不是 @Entry，是 MainPage TabContent 的子组件。
 */

import { router } from '@kit.ArkUI';
import { SessionState } from '../service/AuthService';
import { ServiceRegistry } from '../common/ServiceRegistry';

@Component
export struct SettingsPane {
  /** MainPage 持有此引用，用于调用 refreshAuthState / getScroller */
  pageRef: (p: SettingsPane) => void = (_p: SettingsPane): void => {};

  @State needsLogin: boolean = false;
  @State nearExpiry: boolean = false;
  @State authLabel: string = '';
  @State serverLabel: string = '';
  @State siteName: string = '';
  /** 已建立会话（非游客/未登录）才显示退出登录 */
  @State isAuthed: boolean = false;

  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pageRef(this);
    this.refreshAuthState();
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
      this.isAuthed = state === SessionState.Authenticated;
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
      this.isAuthed = false;
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

  private openRefreshPerf(): void {
    router.pushUrl({ url: 'pages/RefreshPerfPage' });
  }

  /** 带标题/副标题/箭头的入口行卡片 */
  @Builder
  entryCard(title: string, subtitle: string, action: () => void) {
    ListItem() {
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text(title)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text(subtitle)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .padding(14)
      .borderRadius(20)
      .backgroundColor($r('app.color.card_bg'))
      .onClick((): void => {
        action();
      })
    }
  }

  build() {
    List({ scroller: this.scroller, space: 12 }) {
      // ===== 当前服务端（展示卡） =====
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

      // ===== 登录状态（展示卡，点进登录页可换 API Key 登录） =====
      ListItem() {
        Column({ space: 2 }) {
          Row({ space: 8 }) {
            Text('登录状态')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .layoutWeight(1)
            Text('›')
              .fontSize(16)
              .fontColor($r('app.color.text_tertiary'))
          }
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
        .onClick((): void => {
          this.openAuth();
        })
      }

      // ===== 独立入口卡 =====
      this.entryCard('管理我的服务端', '切换、添加、编辑服务端与登录账号', (): void => {
        this.openServerManage();
      })

      this.entryCard('刷新与性能', '列表/详情刷新频率、并发数、Ping 详情缓存', (): void => {
        this.openRefreshPerf();
      })

      // ===== 退出登录（仅已建立会话时显示） =====
      if (this.isAuthed) {
        ListItem() {
          Text('退出登录')
            .fontSize(15)
            .fontColor($r('app.color.status_bad'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(14)
            .borderRadius(20)
            .backgroundColor($r('app.color.card_bg'))
            .onClick((): void => {
              this.doLogout();
            })
        }
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
