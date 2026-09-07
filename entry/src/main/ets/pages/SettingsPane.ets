/**
 * SettingsPane —— 设置页（从 MainPage 物理拆分，2026-09-04；2026-09-06 重组）
 *
 * 职责：只做「展示 + 入口」——
 *   当前服务端展示卡 / 登录状态信息卡（网址·协议·用户名·登录方式·是否存密码，
 *   纯展示不可点，重新登录入口收敛到管理页编辑弹层）；
 *   管理我的服务端（服务端列表 + 编辑弹层，切换与账号一体）独立入口卡；
 *   刷新与性能迁到独立二级页 RefreshPerfPage。
 * 与 MainPage 的关系：通过 pageRef 暴露 refreshAuthState() 和 getScroller()，
 * MainPage 在 onPageShow 时调用 refreshAuthState()，在 getCurrentScroller()
 * 中调用 getScroller() 参与 bindToScrollable 联动。
 *
 * 注意：本组件不是 @Entry，是 MainPage TabContent 的子组件。
 */

import { router } from '@kit.ArkUI';
import { AuthMode } from '../model/KomariTypes';
import { SessionState } from '../service/AuthService';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AppKeys } from '../common/constants/AppKeys';

/** infoRow 入参：@Builder 必须按引用传对象字面量才随 @State 动态重渲染 */
interface InfoRowParam {
  label: string;
  value: string;
}

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
  /** 登录状态信息卡所需字段（纯展示，登录入口收敛到管理页编辑弹层） */
  @State hasServer: boolean = false;
  @State baseUrl: string = '';
  @State authMode: AuthMode = AuthMode.Guest;
  @State rememberPassword: boolean = false;
  /** 与节点/Ping 页同款：SERVER_SEQ 变化即重读认证状态（编辑弹层改密码/切服务端后即时刷新） */
  @StorageProp(AppKeys.SERVER_SEQ) @Watch('onServerSeqChanged') serverSeq: number = 0;

  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pageRef(this);
    this.refreshAuthState();
  }

  aboutToDisappear(): void {
    this.pageRef = (_p: SettingsPane): void => {};
  }

  /** 编辑弹层保存/切换/登录后 bump SERVER_SEQ：卡片不依赖 onPageShow 即时重读 */
  private onServerSeqChanged(): void {
    this.refreshAuthState();
  }

  /** 供 MainPage 调用：刷新认证状态（从 ServerManagePage 返回时） */
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
      this.hasServer = cfg !== undefined && cfg.baseUrl.length > 0;
      this.baseUrl = cfg ? cfg.baseUrl : '';
      this.authMode = cfg ? cfg.authMode : AuthMode.Guest;
      this.rememberPassword = cfg ? cfg.rememberPassword : false;
    } catch (e) {
      this.needsLogin = true;
      this.isAuthed = false;
      this.authLabel = '未连接';
      this.hasServer = false;
      this.baseUrl = '';
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

  private openServerManage(): void {
    router.pushUrl({ url: 'pages/ServerManagePage' });
  }

  private openRefreshPerf(): void {
    router.pushUrl({ url: 'pages/RefreshPerfPage' });
  }

  private openLicenses(): void {
    router.pushUrl({ url: 'pages/OpenSourceLicensePage' });
  }

  private openAbout(): void {
    router.pushUrl({ url: 'pages/AboutPage' });
  }

  /** 当前配置的协议（从 baseUrl 的 scheme 归纳） */
  private schemeLabel(): string {
    if (this.baseUrl.startsWith('https://')) {
      return 'HTTPS';
    }
    if (this.baseUrl.startsWith('http://')) {
      return 'HTTP';
    }
    return '—';
  }

  /** 配置的登录方式（密码 / API Key / 游客；会话未建立时统一显示未登录） */
  private authModeLabel(): string {
    if (this.needsLogin || !this.hasServer) {
      return '未登录';
    }
    if (this.authMode === AuthMode.Password) {
      return '密码';
    }
    if (this.authMode === AuthMode.ApiKey) {
      return 'API Key';
    }
    return '游客';
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

  /** 信息行：左标签（宽 64）+ 右值。$$ 按引用传参，@State 变化时随渲染刷新（值传参只会停在首渲旧值） */
  @Builder
  infoRow($$: InfoRowParam) {
    Row({ space: 12 }) {
      Text($$.label)
        .fontSize(14)
        .lineHeight(20)
        .fontColor($r('app.color.text_secondary'))
        .width(64)
      Text($$.value)
        .fontSize(14)
        .lineHeight(20)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
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

      // ===== 登录状态（纯信息卡：网址/协议/用户名/登录方式/是否存密码；重新登录走「管理我的服务端」编辑弹层） =====
      ListItem() {
        Column({ space: 12 }) {
          Text('登录状态')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          this.infoRow({ label: '网址', value: this.hasServer ? this.baseUrl : '—' })
          this.infoRow({ label: '协议', value: this.hasServer ? this.schemeLabel() : '—' })
          this.infoRow({ label: '用户名', value: this.authLabel })
          this.infoRow({ label: '登录方式', value: this.authModeLabel() })
          if (this.authMode === AuthMode.Password && !this.needsLogin) {
            this.infoRow({ label: '记住密码', value: this.rememberPassword ? '已存本地' : '未存储' })
          }
          if (this.nearExpiry) {
            Text('登录状态即将过期，可在「管理我的服务端」中重新登录获得 30 天会话')
              .fontSize(11)
              .fontColor($r('app.color.status_warn'))
              .width('100%')
          }
        }
        .padding(14)
        .borderRadius(20)
        .backgroundColor($r('app.color.card_bg'))
        .width('100%')
      }

      // ===== 独立入口卡 =====
      this.entryCard('管理我的服务端', '切换、添加、编辑服务端与登录账号', (): void => {
        this.openServerManage();
      })

      this.entryCard('刷新与性能', '列表/详情刷新频率、并发数、Ping 详情缓存', (): void => {
        this.openRefreshPerf();
      })

      this.entryCard('开源许可', '本应用使用的开源组件与许可证', (): void => {
        this.openLicenses();
      })

      this.entryCard('关于', '版本信息、功能介绍与许可声明', (): void => {
        this.openAbout();
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
