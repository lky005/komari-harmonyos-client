/**
 * AuthPage —— 登录页（账号密码 / API Key 两种模式）
 *
 * 前置条件：ServiceRegistry 已 useServer()（从 Main/Connect 页进入时已保证）。
 * 登录成功后：普通入口 router.back() 返回来源页，由来源页 onPageShow 刷新登录状态；
 * 首连入口（路由参数 thenMain=true，由引导页传入）router.clear 后进 MainPage。
 *
 * 2FA 输入已按产品决策移除（2026-09-06）：账号密码模式只收用户名/密码，
 * 开启 2FA 的账号登录时服务端返回错误并在此展示。服务端事实（内部记录 第 2 节，
 * 不要凭直觉改）：登录走 POST /api/login，token 在响应体 data.set-cookie.session_token；
 * API Key 服务端要求长度 >= 12，授予 admin，永不过期。
 */

import { router } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { LoginForm } from '../view/LoginForm';

/** 路由参数：thenMain=true 表示登录成功后直接清栈进主页（首连流程） */
export interface AuthPageParams {
  thenMain?: boolean;
}

enum LoginTab {
  Password = 0,
  ApiKey = 1
}

@Entry
@Component
struct AuthPage {
  @State tab: LoginTab = LoginTab.Password;
  @State username: string = '';
  @State password: string = '';
  @State remember: boolean = true;
  @State apiKey: string = '';
  @State busy: boolean = false;
  @State errorText: string = '';
  @State thenMain: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const p = router.getParams() as AuthPageParams;
    if (p && p.thenMain === true) {
      this.thenMain = true;
    }
  }

  private serverName(): string {
    const cfg = ServiceRegistry.getActiveConfig();
    if (!cfg) {
      return '';
    }
    return cfg.name.length > 0 ? cfg.name : cfg.baseUrl;
  }

  /** 登录成功后的去向：普通入口返回来源页，首连入口清栈进主页 */
  private afterLoginSuccess(): void {
    if (this.thenMain) {
      router.clear();
      router.replaceUrl({ url: 'pages/MainPage' });
    } else {
      router.back();
    }
  }

  private async doPasswordLogin(): Promise<void> {
    if (this.username.trim().length === 0 || this.password.length === 0) {
      this.errorText = '请输入用户名和密码';
      return;
    }
    this.busy = true;
    this.errorText = '';
    try {
      await ServiceRegistry.getAuth().login(this.username.trim(), this.password, '', this.remember);
      this.afterLoginSuccess();
    } catch (err) {
      const e = err as Error;
      this.errorText = e?.message ?? '登录失败';
    } finally {
      this.busy = false;
    }
  }

  private async doApiKeyLogin(): Promise<void> {
    if (this.apiKey.trim().length === 0) {
      this.errorText = '请输入 API Key';
      return;
    }
    this.busy = true;
    this.errorText = '';
    try {
      await ServiceRegistry.getAuth().loginWithApiKey(this.apiKey.trim());
      this.afterLoginSuccess();
    } catch (err) {
      const e = err as Error;
      this.errorText = e?.message ?? '登录失败';
    } finally {
      this.busy = false;
    }
  }

  private async doGuest(): Promise<void> {
    await ServiceRegistry.getAuth().useAsGuest();
    router.back();
  }

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 14 }) {
          Text('登录')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text(`服务端：${this.serverName()}`)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          // 模式切换
          Row({ space: 8 }) {
            Button('账号密码')
              .fontSize(13)
              .fontColor(this.tab === LoginTab.Password ? Color.White : $r('app.color.text_secondary'))
              .backgroundColor(this.tab === LoginTab.Password ? $r('app.color.accent') : $r('app.color.card_bg'))
              .onClick((): void => {
                this.tab = LoginTab.Password;
                this.errorText = '';
              })
            Button('API Key')
              .fontSize(13)
              .fontColor(this.tab === LoginTab.ApiKey ? Color.White : $r('app.color.text_secondary'))
              .backgroundColor(this.tab === LoginTab.ApiKey ? $r('app.color.accent') : $r('app.color.card_bg'))
              .onClick((): void => {
                this.tab = LoginTab.ApiKey;
                this.errorText = '';
              })
          }
          .width('100%')

          if (this.tab === LoginTab.Password) {
            LoginForm({
              username: $username,
              password: $password,
              remember: $remember
            })

            Button(this.busy ? '登录中…' : '登录')
              .fontSize(16)
              .fontColor(Color.White)
              .backgroundColor($r('app.color.accent'))
              .width('100%')
              .height(44)
              .enabled(!this.busy)
              .margin({ top: 4 })
              .onClick((): void => {
                this.doPasswordLogin();
              })

            // 游客模式只对已有会话的常规入口有意义；
            // 首连流程中引导页已经处理过游客路径，这里不再提供
            if (!this.thenMain) {
              Button('以游客身份继续')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .backgroundColor(Color.Transparent)
                .width('100%')
                .enabled(!this.busy)
                .onClick((): void => {
                  this.doGuest();
                })
            }
          } else {
            TextInput({ text: this.apiKey, placeholder: 'API Key（服务端"系统设置"中配置）' })
              .type(InputType.Password)
              .height(44)
              .fontSize(15)
              .backgroundColor($r('app.color.card_bg'))
              .onChange((v: string): void => {
                this.apiKey = v;
              })

            Text('API Key 具有管理员权限且永不过期，仅建议在自有服务器上使用。')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')

            Button(this.busy ? '验证中…' : '使用 API Key 登录')
              .fontSize(16)
              .fontColor(Color.White)
              .backgroundColor($r('app.color.accent'))
              .width('100%')
              .height(44)
              .enabled(!this.busy)
              .onClick((): void => {
                this.doApiKeyLogin();
              })
          }

          if (this.errorText.length > 0) {
            Text(this.errorText)
              .fontSize(13)
              .fontColor($r('app.color.status_bad'))
              .width('100%')
          }
        }
        .padding({ left: 20, right: 20, bottom: 20 })
        .width('100%')
        .constraintSize({ minHeight: '100%' })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .clip(false)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: {
        title: { mainTitle: '登录' },
        backIcon: {
          icon: $r('sys.symbol.arrow_left'),
          action: (): void => { router.back(); }
        }
      },
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .backgroundColor($r('app.color.page_bg'))
  }
}
