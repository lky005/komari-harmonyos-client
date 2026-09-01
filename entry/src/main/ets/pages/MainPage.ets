/**
 * MainPage —— 主界面（底部 Tab）
 *
 * Tab1 节点列表 | Tab2 Ping（二期） | Tab3 设置
 *
 * onPageShow 时刷新登录状态：NeedsLogin → 顶部提示条引导登录；
 * Session 剩余 < 3 天 → 非打断式过期提醒条。
 */

import { router } from '@kit.ArkUI';
import { SessionState } from '../service/AuthService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodesPage } from './NodesPage';

@Entry
@Component
struct MainPage {
  @State needsLogin: boolean = false;
  @State nearExpiry: boolean = false;
  @State authLabel: string = '';
  @State serverLabel: string = '';
  @State siteName: string = '';

  onPageShow(): void {
    this.refreshAuthState();
  }

  aboutToAppear(): void {
    this.refreshAuthState();
  }

  private refreshAuthState(): void {
    try {
      const cfg = ServiceRegistry.getActiveConfig();
      const auth = ServiceRegistry.getAuth();
      const state: SessionState = auth.getState();
      this.needsLogin = state === SessionState.NeedsLogin;
      this.nearExpiry = state === SessionState.Authenticated && auth.isNearExpiry();
      if (state === SessionState.Authenticated) {
        const name: string = cfg && cfg.username.length > 0 ? cfg.username : '已登录';
        this.authLabel = name;
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

  @Builder
  pingPlaceholder() {
    Column({ space: 10 }) {
      Text('Ping 监控')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('延迟曲线、丢包统计将在后续版本提供')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  settingsPane() {
    Column({ space: 12 }) {
      Text('设置')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

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
      .borderRadius(12)
      .backgroundColor($r('app.color.card_bg'))
      .width('100%')

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
      .borderRadius(12)
      .backgroundColor($r('app.color.card_bg'))
      .width('100%')

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

      Text('多服务端管理、Ping 监控、历史曲线将在后续版本提供')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .padding(16)
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      if (this.needsLogin) {
        // 非打断式提示条
        Row({ space: 8 }) {
          Text('⚠')
            .fontSize(14)
          Text('服务端需要登录才能查看数据')
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Text('去登录')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accent'))
        }
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .backgroundColor($r('app.color.status_warn'))
        .width('100%')
        .onClick((): void => {
          this.openAuth();
        })
      }

      Tabs({ barPosition: BarPosition.End }) {
        TabContent() {
          NodesPage()
        }
        .tabBar(this.tabLabel('节点'))

        TabContent() {
          this.pingPlaceholder()
        }
        .tabBar(this.tabLabel('Ping'))

        TabContent() {
          this.settingsPane()
        }
        .tabBar(this.tabLabel('设置'))
      }
      .layoutWeight(1)
      .barHeight(52)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  tabLabel(title: string) {
    Text(title)
      .fontSize(14)
      .fontColor($r('app.color.text_primary'))
  }
}
