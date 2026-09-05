/**
 * ConnectPanel —— 连接/添加服务端表单主体（首启引导页与「添加服务端」弹层共用）
 *
 * 两种形态：
 *   - chrome=false：纯表单。用于 ConnectPage 页面内嵌，标题与滚动联动由页面自己的
 *     HdsNavigation 负责（bindToScrollable 绑的是页面 scroller）；
 *   - chrome=true：自带嵌套 HdsNavigation。用于 ServerManagePage 的 bindSheet 承载，
 *     标题栏材质/渐变模糊与 ServerEditSheet 完全一致（IMMERSIVE + EXQUISITE）。
 *
 * sheetMode=true 时保存/切换成功不走路由跳转，改为 onClose() 收掉弹层
 * （SERVER_SEQ 已 bump，管理页列表自行刷新；loginNext 会先收弹层再进登录页）。
 */

import { router, promptAction } from '@kit.ArkUI';
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
import { HeaderProvider, HttpRpcClient, RpcException } from '../service/RpcClient';
import { KomariApi } from '../service/KomariApi';
import { makeServerConfig, makeServerId } from '../storage/ServerStore';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';
import { AppKeys } from '../common/constants/AppKeys';
import { ParsedUrl, UrlInput, validateHostRest, buildBaseUrl, resolveScheme, parsePastedUrl, isPrivateHost } from './UrlInput';
import { AuthPageParams } from '../pages/AuthPage';

interface ProbeResult {
  settings: PublicSettings;
  version: VersionInfo;
}

@Component
export struct ConnectPanel {
  /** true = 自带嵌套 HdsNavigation（弹层形态），false = 纯表单（页面内嵌） */
  chrome: boolean = false;
  /** true = 弹层模式：保存成功后 onClose() 收层，不做路由跳转 */
  sheetMode: boolean = false;
  /** 仅页面形态使用：首启引导显示「跳过」区 */
  showSkip: boolean = false;
  /** 弹层模式下的关闭回调 */
  onClose: () => void = (): void => {};

  @State https: boolean = true;
  @State rest: string = '';
  @State probing: boolean = false;
  @State result: ProbeResult | undefined = undefined;
  @State errorText: string = '';
  @State entering: boolean = false;
  /** 本次会话已保存过服务端（保存后隐藏跳过区） */
  @State saved: boolean = false;
  /** 进行中的探测客户端引用，取消时靠它中止在途请求 */
  private probeClient: HttpRpcClient | undefined = undefined;
  /** 取消标记：被取消的探测不回填结果、不报错误 */
  private cancelled: boolean = false;
  private scroller: Scroller = new Scroller();

  private inputValid(): boolean {
    return validateHostRest(this.rest);
  }

  private async probe(): Promise<void> {
    if (!this.inputValid()) {
      this.errorText = '请输入正确的域名或 IP，例如 panel.example.com';
      return;
    }
    // 文本里残留显式协议头时以文本为准，协议按钮同步跟随，避免拼出 http://https://x
    const eff: ParsedUrl = resolveScheme(this.https, this.rest);
    this.https = eff.https;
    this.rest = eff.rest;
    const baseUrl: string = buildBaseUrl(eff.https, eff.rest);
    this.cancelled = false;
    this.probing = true;
    this.errorText = '';
    this.result = undefined;
    try {
      // 探测阶段不带任何凭据，与登录态无关
      const emptyHeaders: Record<string, string> = {};
      const provider: HeaderProvider = (): Record<string, string> => emptyHeaders;
      const client = new HttpRpcClient(baseUrl, provider, 8000);
      this.probeClient = client;
      const api = new KomariApi(client);

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
      if (this.cancelled) {
        // 请求都已返回但用户已放弃：不回填结果
        return;
      }
      this.result = { settings: settings, version: version };
    } catch (err) {
      this.result = undefined;
      if (this.cancelled) {
        return;
      }
      // 4xx = 服务器在线但拒绝了请求：按协议给出可操作的说明，而不是裸状态码
      if (err instanceof RpcException && err.code >= 400 && err.code < 500) {
        this.errorText = this.https
          ? `HTTP ${err.code}：服务器在线，但它不是 Komari 面板（或接口不可用），请确认地址是否填对`
          : `HTTP ${err.code}：请求被服务端拒绝——若它是 HTTPS 站点，请切换协议后重试`;
      } else {
        const e = err as Error;
        this.errorText = e?.message ?? '连接失败';
      }
    } finally {
      this.probing = false;
      this.probeClient = undefined;
    }
  }

  /** 取消测试：中止在途请求，probe 由自身 finally 收尾复位 probing */
  private cancelProbe(): void {
    this.cancelled = true;
    this.errorText = '';
    this.probeClient?.cancelAll();
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
      if (this.sheetMode) {
        // 先收弹层再进登录页，避免 AuthPage 压在弹层底下
        this.onClose();
      }
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
      if (this.sheetMode) {
        this.onClose();
      } else {
        // 清栈后进主页，避免留下 ServerManagePage 或重复的 MainPage
        router.clear();
        router.replaceUrl({ url: 'pages/MainPage' });
      }
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
        backgroundColor: $r('sys.color.ohos_id_color_emphasize'),
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
      if (this.sheetMode) {
        this.onClose();
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

  private sheetTitleBar(): HdsNavigationTitleBarOptions {
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
    return {
      // 与 ServerEditSheet 一致：弹层内容自己处理安全区
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: true,
      content: {
        title: { mainTitle: '添加服务端' },
        backIcon: {
          // 纯 xmark 符号：backIcon 槽位自带玻璃圆底，用带圆的 xmark_circle_fill
          // 会圆叠圆渲染出黑色叉底；纯符号粗细与各页返回箭头一致
          icon: $r('sys.symbol.xmark'),
          action: (): void => {
            this.onClose();
          }
        }
      },
      style: style
    };
  }

  build() {
    if (this.chrome) {
      HdsNavigation() {
        Scroll(this.scroller) {
          this.formColumn()
        }
        .align(Alignment.Top)
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .clip(false)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      }
      .titleBar(this.sheetTitleBar())
      .titleMode(HdsNavigationTitleMode.MINI)
      .bindToScrollable([this.scroller])
      .backgroundColor($r('app.color.page_bg'))
    } else {
      this.formColumn()
    }
  }

  @Builder
  formColumn() {
    Column({ space: 14 }) {
      if (this.chrome) {
        // 弹层形态：与 ServerEditSheet 同款「卡片 + 左标签右控件」布局
        this.serverInfoCard()
      } else {
        // 页面形态：沿用 UrlInput 扁平表单（引导语境，含防错提醒）
        UrlInput({
          https: $https,
          rest: $rest
        })
      }

      this.probeRow()

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(13)
          .fontColor($r('app.color.status_bad'))
          .width('100%')
      }

      this.resultSection()

      if (this.showSkip && !this.saved) {
        this.skipSection()
      }
    }
    .width('100%')
    // 弹层形态与 ServerEditSheet 同边距（横向 16 / 底部 20）；页面形态由 ConnectPage 外层提供 20
    .padding(this.chrome ? { left: 16, right: 16, bottom: 20 } : { left: 0, right: 0, top: 0, bottom: 0 })
  }

  /** 弹层形态：服务端信息卡——布局间距逐项对齐 ServerEditSheet（卡片 padding 14 / 行距 12 / 标签宽 64） */
  @Builder
  serverInfoCard() {
    Column({ space: 12 }) {
      Text('服务端信息')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Row({ space: 12 }) {
        Text('协议')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .width(64)
        Row({ space: 8 }) {
          this.sheetPill('HTTPS', true)
          this.sheetPill('HTTP', false)
        }
        .layoutWeight(1)
      }
      .width('100%')

      Row({ space: 12 }) {
        Text('地址')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .width(64)
        TextInput({ text: this.rest, placeholder: 'panel.example.com' })
          .height(44)
          .fontSize(15)
          .backgroundColor($r('app.color.page_bg'))
          .layoutWeight(1)
          .onChange((v: string): void => {
            // 粘贴完整链接时自动解析协议与路径；普通输入直接透传
            if (v.indexOf('://') >= 0) {
              const p: ParsedUrl = parsePastedUrl(v);
              this.https = p.https;
              this.rest = p.rest;
            } else {
              this.rest = v;
            }
          })
      }
      .width('100%')

      if (!this.https) {
        Text('HTTP 为明文传输，登录密码可能被窃听，建议改用 HTTPS')
          .fontSize(11)
          .fontColor($r('app.color.status_warn'))
          .width('100%')
      }
      if (isPrivateHost(this.rest)) {
        Text('这是内网或本机地址，仅在同一网络下可以访问')
          .fontSize(11)
          .fontColor($r('app.color.status_warn'))
          .width('100%')
      }
      if (this.rest.length > 0 && !validateHostRest(this.rest)) {
        Text('不是有效的域名或 IPv4 地址，暂不支持 IPv6')
          .fontSize(11)
          .fontColor($r('app.color.status_bad'))
          .width('100%')
      }
    }
    .padding(14)
    .borderRadius(20)
    .backgroundColor($r('app.color.card_bg'))
    .width('100%')
  }

  /** 协议二选一按钮：样式与 ServerEditSheet.pill 一致（选中实心主色、未选中 page_bg、上下 8） */
  @Builder
  sheetPill(label: string, value: boolean) {
    Text(label)
      .fontSize(12)
      .fontColor(this.https === value ? Color.White : $r('app.color.text_secondary'))
      .backgroundColor(this.https === value ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.page_bg'))
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .borderRadius(8)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .onClick((): void => {
        this.https = value;
      })
  }

  @Builder
  probeRow() {
    Row({ space: 10 }) {
      Button(this.probing ? '连接中…' : '测试连接')
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .layoutWeight(1)
          .height(44)
          // 输入非法不禁用按钮（避免随输入反复可用/禁用"抽搐"），点下时用气泡提示
          .enabled(!this.probing && !this.entering)
          .onClick((): void => {
            if (!this.inputValid()) {
              promptAction.showToast({ message: '请输入正确的域名或 IP（暂不支持 IPv6）' });
              return;
            }
            this.probe();
          })

        if (this.probing) {
          Button('取消测试')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.card_bg'))
            .layoutWeight(1)
            .height(44)
            .onClick((): void => {
              this.cancelProbe();
            })
        }
      }
      .width('100%')
  }

  @Builder
  resultSection() {
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
            .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
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
            .fontColor($r('sys.color.ohos_id_color_emphasize'))
            .backgroundColor(Color.Transparent)
            .width('100%')
            .enabled(!this.entering && !this.probing)
            .onClick((): void => {
              this.loginNext();
            })
        }
      }
  }

  @Builder
  skipSection() {
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
