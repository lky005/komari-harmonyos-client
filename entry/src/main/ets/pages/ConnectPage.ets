/**
 * ConnectPage —— 首启引导页 / 添加服务端页（双模式复用）
 *
 * 模式判定：router.getLength() > 1 → 添加模式（有来源页，显示返回箭头、隐藏跳过）；
 * 否则为首启引导模式（隐藏返回箭头，底部提供「跳过」）。
 *
 * 引导流程（对应设计文档 5.4 私有站点闸门，顺序不能反）：
 *   1. 协议按钮（https 默认 / http）+ 域名输入（粘贴完整链接自动解析）
 *   2. 输入校验（仅 http/https；host 合法性）+ http/内网黄色小字提醒（放行不阻断）
 *   3. 临时 RpcClient 调 rpc.ping 自检 → getPublicSettings 拿站点名/私有标记 → getVersion
 *   4. 保存 ServerConfig → useServer
 *      私有站点 → AuthPage(thenMain=true) 登录后清栈进主页
 *      公开站点 → 游客直接进，或选择登录后进
 *   5. 跳过：记 onboarded 标记，不配置服务端直接进主页（三 Tab 显示空态）
 *
 * 防错：重复添加不再静默覆盖（旧行为 saveServer upsert 会把已有服务端的
 * authMode 重置），改为弹窗提示「切换到已有服务端」。
 */

import { router } from '@kit.ArkUI';
import {
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsNavigationTitleBarOptions,
  TitleBarStyleOptions,
  ScrollEffectType,
  BlurStrategy,
  hdsMaterial
} from '@kit.UIDesignKit';
import { AuthMode, PublicSettings, ServerConfig, VersionInfo } from '../model/KomariTypes';
import { HeaderProvider, HttpRpcClient } from '../service/RpcClient';
import { KomariApi } from '../service/KomariApi';
import { makeServerConfig, makeServerId } from '../storage/ServerStore';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';
import { AppKeys } from '../common/constants/AppKeys';
import { UrlInput, validateHostRest, buildBaseUrl } from '../view/UrlInput';
import { AuthPageParams } from './AuthPage';

interface ProbeResult {
  settings: PublicSettings;
  version: VersionInfo;
}

@Entry
@Component
struct ConnectPage {
  @State https: boolean = true;
  @State rest: string = '';
  @State probing: boolean = false;
  @State result: ProbeResult | undefined = undefined;
  @State errorText: string = '';
  @State entering: boolean = false;
  /** 本次会话已保存过服务端（保存后隐藏跳过区） */
  @State saved: boolean = false;
  /** 添加模式（从服务端管理页进入）：显示返回箭头、隐藏跳过 */
  @State addMode: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    // 本 SDK 中 router.getLength() 返回 string（页面栈中页面数）
    this.addMode = Number(router.getLength()) > 1;
  }

  private inputValid(): boolean {
    return validateHostRest(this.rest);
  }

  private async probe(): Promise<void> {
    if (!this.inputValid()) {
      this.errorText = '请输入正确的域名或 IP，例如 panel.example.com';
      return;
    }
    const baseUrl: string = buildBaseUrl(this.https, this.rest);
    this.probing = true;
    this.errorText = '';
    this.result = undefined;
    try {
      // 探测阶段不带任何凭据，与登录态无关
      const emptyHeaders: Record<string, string> = {};
      const provider: HeaderProvider = (): Record<string, string> => emptyHeaders;
      const api = new KomariApi(new HttpRpcClient(baseUrl, provider, 8000));

      const pong: string = await api.ping();
      if (pong !== 'pong') {
        throw new Error('服务端响应异常');
      }
      const settings: PublicSettings = await api.getPublicSettings();
      let version: VersionInfo = { version: '', hash: '' };
      try {
        version = await api.getVersion();
      } catch (e) {
        // 版本接口失败不阻塞，老版本兼容
      }
      this.result = { settings: settings, version: version };
    } catch (err) {
      const e = err as Error;
      this.result = undefined;
      this.errorText = e?.message ?? '连接失败';
    } finally {
      this.probing = false;
    }
  }

  /** 探测成功后按 id 查重：返回已存在的同址服务端 */
  private async findDuplicate(): Promise<ServerConfig | undefined> {
    const id: string = makeServerId(buildBaseUrl(this.https, this.rest));
    const list: ServerConfig[] = await ServiceRegistry.getServerStore().listServers();
    let found: ServerConfig | undefined = undefined;
    list.forEach((s: ServerConfig): void => {
      if (!found && s.id === id) {
        found = s;
      }
    });
    return found;
  }

  /** 保存配置 → useServer → 清缓存 → 通知列表页重建轮询 */
  private async saveAndUse(siteName: string, privateSite: boolean): Promise<void> {
    const baseUrl: string = buildBaseUrl(this.https, this.rest);
    const authMode: AuthMode = privateSite ? AuthMode.Password : AuthMode.Guest;
    const cfg: ServerConfig = makeServerConfig(siteName, baseUrl, authMode);
    await ServiceRegistry.getServerStore().saveServer(cfg);
    await ServiceRegistry.useServer(cfg);
    NodeDataStore.getInstance().clear();
    AppStorage.setOrCreate(AppKeys.SERVER_SEQ, Date.now());
    this.saved = true;
  }

  private siteName(r: ProbeResult): string {
    return r.settings.sitename.length > 0 ? r.settings.sitename : buildBaseUrl(this.https, this.rest);
  }

  /** 私有站点 / 用户选择登录：保存后进登录页，登录成功由 AuthPage 清栈进主页 */
  private async loginNext(): Promise<void> {
    const r = this.result;
    if (!r || this.entering) {
      return;
    }
    this.entering = true;
    this.errorText = '';
    try {
      const dup: ServerConfig | undefined = await this.findDuplicate();
      if (dup) {
        this.confirmSwitchExisting(dup);
        return;
      }
      await this.saveAndUse(this.siteName(r), r.settings.private_site);
      const params: AuthPageParams = { thenMain: true };
      router.pushUrl({ url: 'pages/AuthPage', params: params });
    } catch (err) {
      const e = err as Error;
      this.errorText = e?.message ?? '进入失败';
    } finally {
      this.entering = false;
    }
  }

  /** 公开站点游客进入 */
  private async enterGuest(): Promise<void> {
    const r = this.result;
    if (!r || this.entering) {
      return;
    }
    this.entering = true;
    this.errorText = '';
    try {
      const dup: ServerConfig | undefined = await this.findDuplicate();
      if (dup) {
        this.confirmSwitchExisting(dup);
        return;
      }
      await this.saveAndUse(this.siteName(r), false);
      // 清栈后进主页，避免留下 ServerManagePage 或重复的 MainPage
      router.clear();
      router.replaceUrl({ url: 'pages/MainPage' });
    } catch (err) {
      const e = err as Error;
      this.errorText = e?.message ?? '进入失败';
    } finally {
      this.entering = false;
    }
  }

  private confirmSwitchExisting(cfg: ServerConfig): void {
    AlertDialog.show({
      title: '服务端已存在',
      message: `「${cfg.name}」已添加过，是否直接切换到它？`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {
          // 不切换
        }
      },
      secondaryButton: {
        value: '切换',
        fontColor: Color.White,
        backgroundColor: $r('app.color.accent'),
        action: (): void => {
          this.doSwitchExisting(cfg);
        }
      }
    });
  }

  private async doSwitchExisting(cfg: ServerConfig): Promise<void> {
    try {
      await ServiceRegistry.useServer(cfg);
      NodeDataStore.getInstance().clear();
      await ServiceRegistry.getAuth().restore();
      AppStorage.setOrCreate(AppKeys.SERVER_SEQ, Date.now());
      this.saved = true;
      if (this.addMode) {
        router.back();
      } else {
        router.clear();
        router.replaceUrl({ url: 'pages/MainPage' });
      }
    } catch (err) {
      const e = err as Error;
      this.errorText = e?.message ?? '切换失败';
    }
  }

  /** 首启跳过：不配置服务端进主页，各 Tab 显示空态 */
  private async skip(): Promise<void> {
    try {
      await ServiceRegistry.getServerStore().putSetting('onboarded', '1');
    } catch (e) {
      // 标记失败不阻塞进入
    }
    router.clear();
    router.replaceUrl({ url: 'pages/MainPage' });
  }

  private buildTitleBar(): HdsNavigationTitleBarOptions {
    const style: TitleBarStyleOptions = {
      blurStrategy: BlurStrategy.ENABLE,
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.GRADIENT_BLUR
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
      }
    };
    if (this.addMode) {
      return {
        avoidLayoutSafeArea: true,
        enableComponentSafeArea: true,
        content: {
          title: { mainTitle: '添加服务端' },
          backIcon: {
            icon: $r('sys.symbol.arrow_left'),
            action: (): void => { router.back(); }
          }
        },
        style: style
      };
    }
    // 首启：栈里没有来源页，不显示返回箭头
    return {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: {
        title: { mainTitle: '连接服务端' }
      },
      style: style
    };
  }

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 14 }) {
          Text('连接到 Komari')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text('选择协议并输入你自建面板的域名，例如 komari.example.com')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          UrlInput({
            https: $https,
            rest: $rest
          })

          Button(this.probing ? '连接中…' : '测试连接')
            .fontSize(15)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.accent'))
            .width('100%')
            .height(44)
            .enabled(this.inputValid() && !this.probing && !this.entering)
            .onClick((): void => {
              this.probe();
            })

          if (this.errorText.length > 0) {
            Text(this.errorText)
              .fontSize(13)
              .fontColor($r('app.color.status_bad'))
              .width('100%')
          }

          // ===== 探测成功 =====
          if (this.result) {
            Column({ space: 10 }) {
              Row({ space: 8 }) {
                Circle({ width: 8, height: 8 })
                  .fill($r('app.color.status_ok'))
                Text('连接成功')
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                if (this.result.version.version.length > 0) {
                  Text(`v${this.result.version.version}`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                }
              }
              .width('100%')

              if (this.result.settings.sitename.length > 0) {
                Text(this.result.settings.sitename)
                  .fontSize(14)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
              }

              Row({ space: 6 }) {
                Text(this.result.settings.private_site ? '私有站点 · 需要登录' : '公开站点 · 可游客浏览')
                  .fontSize(12)
                  .fontColor(this.result.settings.private_site ? $r('app.color.status_warn') : $r('app.color.status_ok'))
              }
              .width('100%')
            }
            .padding(14)
            .borderRadius(20)
            .backgroundColor($r('app.color.card_bg'))
            .width('100%')

            if (this.result.settings.private_site) {
              Button(this.entering ? '进入中…' : '下一步：登录')
                .fontSize(15)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.accent'))
                .width('100%')
                .height(44)
                .enabled(!this.entering && !this.probing)
                .onClick((): void => {
                  this.loginNext();
                })
            } else {
              Button('以游客身份进入')
                .fontSize(15)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.status_ok'))
                .width('100%')
                .height(44)
                .enabled(!this.entering && !this.probing)
                .onClick((): void => {
                  this.enterGuest();
                })

              Button('使用账号登录进入')
                .fontSize(13)
                .fontColor($r('app.color.accent'))
                .backgroundColor(Color.Transparent)
                .width('100%')
                .enabled(!this.entering && !this.probing)
                .onClick((): void => {
                  this.loginNext();
                })
            }
          }

          // ===== 首启跳过：未保存过任何服务端时可见 =====
          if (!this.addMode && !this.saved) {
            Column({ space: 6 }) {
              Button('跳过，暂不添加服务端')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .backgroundColor(Color.Transparent)
                .width('100%')
                .height(40)
                .enabled(!this.entering && !this.probing)
                .onClick((): void => {
                  this.skip();
                })
              Text('跳过后可直接进入应用，之后可以在「设置 → 管理我的服务端」中添加')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .margin({ top: 10 })
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
    .titleBar(this.buildTitleBar())
    .titleMode(HdsNavigationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .backgroundColor($r('app.color.page_bg'))
  }
}
