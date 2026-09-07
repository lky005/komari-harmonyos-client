/**
 * ConnectPanel —— 连接/添加服务端表单（首启引导页与「添加服务端」弹层共用）
 *
 * 两种形态：
 *   - chrome=false：纯表单。仅用于 ConnectPage（首启引导专用页，replaceUrl 清栈进入），
 *     标题与滚动联动由页面自己的 HdsNavigation 负责（bindToScrollable 绑的是页面 scroller）；
 *   - chrome=true：自带嵌套 HdsNavigation。用于 ServerManagePage / MainPage 的 bindSheet
 *     承载，标题栏材质/渐变模糊与 ServerEditSheet 完全一致（IMMERSIVE + EXQUISITE）。
 *
 * 两种形态统一流程（对齐 ServerEditSheet，登录不跳二级页）：
 *   地址卡：左侧协议按钮弹菜单气泡选 HTTPS/HTTP（与输入框分离、带区分度），
 *   粘贴完整链接自动解析协议；连接测试成功后内联账号卡，「保存并进入」在面板内
 *   完成保存+登录——填了账密先 probeLogin 预检（凭据错停在原状不落盘），没填账密
 *   按游客进入（私有站点拦下要求填写）。成功后：弹层 onClose() 收层（SERVER_SEQ
 *   已 bump，宿主页自行刷新）；页面 router.clear 清栈进主页。
 *   saveAndUse 落盘后立即 restore() 建立登录态（与编辑弹层收尾一致），
 *   否则设置页状态卡会一直显示「检测中…」直到重启。
 *
 * 跳过入口不在此组件（首启引导的「跳过」由 ConnectPage 标题栏右上角承载）。
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
import { AuthService } from '../service/AuthService';
import { makeServerConfig, makeServerId } from '../storage/ServerStore';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';
import { AppKeys } from '../common/constants/AppKeys';
import { ParsedUrl, validateHostRest, buildBaseUrl, resolveScheme, parsePastedUrl, isPrivateHost } from './UrlInput';

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
  /** 弹层模式下的关闭回调 */
  onClose: () => void = (): void => {};

  @State https: boolean = true;
  @State rest: string = '';
  @State probing: boolean = false;
  @State result: ProbeResult | undefined = undefined;
  @State errorText: string = '';
  @State entering: boolean = false;
  /** 内联登录的账号输入（两种形态共用，连接成功后展示） */
  @State username: string = '';
  @State password: string = '';
  @State remember: boolean = true;
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

  /** 保存配置 → useServer → 建立登录态 → 清缓存 → 通知宿主页重建 */
  private async saveAndUse(siteName: string, privateSite: boolean): Promise<void> {
    const baseUrl: string = buildBaseUrl(this.https, this.rest);
    const authMode: AuthMode = privateSite ? AuthMode.Password : AuthMode.Guest;
    const cfg: ServerConfig = makeServerConfig(siteName, baseUrl, authMode);
    await ServiceRegistry.getServerStore().saveServer(cfg);
    await ServiceRegistry.useServer(cfg);
    NodeDataStore.getInstance().clear();
    // 立即建立登录态（对齐 ServerEditSheet 收尾）：游客配置直接进 Guest，
    // 私有站点无凭据为 NeedsLogin。restore() 不抛网络异常。
    await ServiceRegistry.getAuth().restore();
    AppStorage.setOrCreate(AppKeys.SERVER_SEQ, Date.now());
  }

  private siteName(r: ProbeResult): string {
    return r.settings.sitename.length > 0 ? r.settings.sitename : buildBaseUrl(this.https, this.rest);
  }

  /**
   * 「保存并进入」（两种形态统一入口）：对齐 ServerEditSheet 的「保存并切换」。
   * 填了账密先 probeLogin 预检（凭据错停在原状，不落盘不切换），保存后立即登录；
   * 没填账密按游客保存进入（私有站点拦下要求填写）。
   * 成功去向：弹层 onClose() 收层；页面清栈进主页。
   */
  private async saveAndEnter(): Promise<void> {
    const r = this.result;
    if (!r || this.entering) {
      return;
    }
    if (!this.inputValid()) {
      this.errorText = '请输入正确的域名或 IP，例如 panel.example.com';
      return;
    }
    const hasUser: boolean = this.username.trim().length > 0;
    const hasPwd: boolean = this.password.length > 0;
    if (hasUser && !hasPwd) {
      this.errorText = '请输入密码';
      return;
    }
    if (!hasUser && hasPwd) {
      this.errorText = '请输入用户名';
      return;
    }
    if (r.settings.private_site && !hasUser) {
      this.errorText = '私有站点需要登录，请填写账号密码';
      return;
    }
    this.entering = true;
    this.errorText = '';
    try {
      if (hasUser && hasPwd) {
        const eff: ParsedUrl = resolveScheme(this.https, this.rest);
        await AuthService.probeLogin(buildBaseUrl(eff.https, eff.rest), this.username.trim(), this.password);
      }
      await this.saveAndUse(this.siteName(r), r.settings.private_site);
      if (hasUser && hasPwd) {
        // saveAndUse 的 restore() 先置 NeedsLogin，登录成功即覆盖为 Authenticated
        await ServiceRegistry.getAuth().login(this.username.trim(), this.password, '', this.remember);
      }
      this.finishEnter();
    } catch (err) {
      const e = err as Error;
      this.errorText = e?.message ?? '保存失败';
    } finally {
      this.entering = false;
    }
  }

  /** 进入成功后的去向：弹层收层回宿主页；引导页清栈进主页 */
  private finishEnter(): void {
    if (this.sheetMode) {
      this.onClose();
    } else {
      router.clear();
      router.replaceUrl({ url: 'pages/MainPage' });
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
      this.finishEnter();
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
      this.finishEnter();
    } catch (err) {
      const e = err as Error;
      this.errorText = e?.message ?? '切换失败';
    }
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
      // 两种形态统一用「卡片 + 左标签右控件」排版（与 ServerEditSheet 一致）
      this.serverInfoCard()

      this.probeRow()

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(13)
          .fontColor($r('app.color.status_bad'))
          .width('100%')
      }

      this.resultSection()
    }
    .width('100%')
    // 弹层形态与 ServerEditSheet 同边距（横向 16 / 底部 20）；页面形态由 ConnectPage 外层提供 16
    .padding(this.chrome ? { left: 16, right: 16, bottom: 20 } : { left: 0, right: 0, top: 0, bottom: 0 })
  }

  /**
   * 地址卡：左侧协议按钮（accent_soft 浅底与输入框区分，点击弹系统菜单气泡
   * 选 HTTPS/HTTP），右侧地址输入框；粘贴完整链接自动解析协议。
   * HTTP/内网/无效地址警告按需显示。
   */
  @Builder
  serverInfoCard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(this.https ? 'HTTPS' : 'HTTP')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_emphasize'))
          .backgroundColor($r('app.color.accent_soft'))
          .textAlign(TextAlign.Center)
          .constraintSize({ minWidth: 68 })
          .padding({ left: 12, right: 12, top: 13, bottom: 13 })
          .borderRadius(12)
          .bindMenu([
            {
              value: 'HTTPS',
              action: (): void => {
                this.https = true;
              }
            },
            {
              value: 'HTTP',
              action: (): void => {
                this.https = false;
              }
            }
          ])
        TextInput({ text: this.rest, placeholder: 'panel.example.com' })
          .height(44)
          .fontSize(15)
          .backgroundColor($r('app.color.page_bg'))
          .borderRadius(12)
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
      // 两种形态统一：结果卡 + 内联账号卡 + 按钮，登录不跳二级页
      this.resultCard()
      this.accountCard()
      this.enterActions()
    }
  }

  /**
   * 连接结果条：两行紧凑、不套卡片（省一屏空间）。
   * 行1 状态+版本；行2 站点名 · 私有/公开语义。
   */
  @Builder
  resultCard() {
    if (this.result) {
      Column({ space: 4 }) {
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

        Row({ space: 6 }) {
          if (this.result.settings.sitename.length > 0) {
            Text(this.result.settings.sitename)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(this.result.settings.private_site ? '私有站点，需要登录' : '公开站点，可游客浏览')
            .fontSize(12)
            .fontColor(this.result.settings.private_site ? $r('app.color.status_warn') : $r('app.color.status_ok'))
            .maxLines(1)
        }
        .width('100%')
      }
      .padding({ left: 4, right: 4 })
      .width('100%')
    }
  }

  /** 账号卡（无卡头）：用户名/密码/记住密码；说明压成一句，操作语义由结果条与按钮承担 */
  @Builder
  accountCard() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text('用户名')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .width(64)
        TextInput({ text: this.username, placeholder: '请输入用户名' })
          .height(44)
          .fontSize(15)
          .backgroundColor($r('app.color.page_bg'))
          .layoutWeight(1)
          .onChange((v: string): void => {
            this.username = v;
          })
      }
      .width('100%')

      Row({ space: 12 }) {
        Text('密码')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .width(64)
        TextInput({ text: this.password, placeholder: '请输入密码' })
          .type(InputType.Password)
          .height(44)
          .fontSize(15)
          .backgroundColor($r('app.color.page_bg'))
          .layoutWeight(1)
          .onChange((v: string): void => {
            this.password = v;
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text('记住密码')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
        Toggle({ type: ToggleType.Checkbox, isOn: this.remember })
          .onChange((on: boolean): void => {
            this.remember = on;
          })
        Text('仅本机加密保存，过期自动重登')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
          .maxLines(2)
      }
      .width('100%')
      .onClick((): void => {
        this.remember = !this.remember;
      })
    }
    .padding(14)
    .borderRadius(20)
    .backgroundColor($r('app.color.card_bg'))
    .width('100%')
  }

  /** 按钮组：主按钮与游客按钮并排一行（私有站点无游客按钮，主按钮占满），层级对齐 ServerEditSheet */
  @Builder
  enterActions() {
    Row({ space: 12 }) {
      Button(this.entering ? '保存中…' : '保存并进入')
        .fontSize(15)
        .fontColor(Color.White)
        .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
        .layoutWeight(1)
        .height(44)
        .enabled(!this.entering && !this.probing)
        .onClick((): void => {
          this.saveAndEnter();
        })

      if (this.result && !this.result.settings.private_site) {
        Button('以游客身份进入')
          .fontSize(14)
          .fontColor($r('sys.color.ohos_id_color_emphasize'))
          .backgroundColor($r('app.color.accent_soft'))
          .layoutWeight(1)
          .height(44)
          .enabled(!this.entering && !this.probing)
          .onClick((): void => {
            this.enterGuest();
          })
      }
    }
    .width('100%')
  }
}
