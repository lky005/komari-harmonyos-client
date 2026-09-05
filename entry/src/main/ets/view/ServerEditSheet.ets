/**
 * ServerEditSheet —— 服务端编辑半模态弹层（ServerManagePage 用）
 *
 * 把「编辑服务端信息」与「账号登录/切换」合并成一个动作面：
 *   - 信息段：名称/协议/地址 两列表单行，标签在左控件在右；粘贴解析、
 *     内网提醒等防错逻辑复用 UrlInput.ets 导出的纯函数——组件本体不再
 *     嵌入，其白底输入框只适合灰色页面背景，放进白卡会隐形；
 *   - 账号段：状态/用户名/密码/记住密码 同样两列（LoginForm 保留给
 *     AuthPage，2FA 已按产品决策移除）；
 *   - 「保存并切换」：保存信息 → 设为当前服务端 → 填了账号密码就登录，
 *     否则 restore() 恢复既有会话 → bump SERVER_SEQ 通知各页重建轮询。
 *   - 「以游客身份使用」用 accent_soft 次级填充，与实心 accent 主按钮分层。
 *
 * 域名变更 = 条目迁移：删旧条目并清理旧 id 的本地凭据，避免孤儿 Asset 条目；
 * 目标地址已被其他条目占用时直接报错，不做合并。
 *
 * 注意：本组件不持有 @State cfg —— 父组件用「条件构建 + 关闭即置空」保证
 * 每次打开弹层都是全新实例，aboutToAppear 从 cfg 重新初始化各输入项。
 *
 * 顶部材质：弹层内直接嵌套 HdsNavigation（SDK 定义 pathInfos 为可选参数，
 * 支持无路由栈的纯容器用法），titleBar 走与 ServerManagePage 完全相同的
 * GRADIENT_BLUR + IMMERSIVE/EXQUISITE 系统材质——滚动渐变模糊与关闭按钮
 * 材质均由系统渲染。此前手工 backgroundBlurStyle + linearGradient 方案
 * 弃用：不透明色向 Color.Transparent 插值会经过半透明深色像素，
 * 在标题栏下方渲染出一条黑灰线（淡出到黑的经典伪影）。
 * avoidLayoutSafeArea 关闭：弹层顶端已在状态栏之下，无需再避让。
 */

import { AuthMode, ServerConfig } from '../model/KomariTypes';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';
import { AppKeys } from '../common/constants/AppKeys';
import { makeServerConfig, makeServerId } from '../storage/ServerStore';
import { KeyFactory } from '../storage/SecretStore';
import { AuthService } from '../service/AuthService';
import {
  HdsNavigation,
  HdsNavigationTitleMode,
  ScrollEffectType,
  BlurStrategy,
  hdsMaterial
} from '@kit.UIDesignKit';
import { ParsedUrl, parsePastedUrl, validateHostRest, buildBaseUrl, isPrivateHost, resolveScheme } from './UrlInput';

@Component
export struct ServerEditSheet {
  /** 正在编辑的服务端（父组件打开弹层时传入） */
  cfg: ServerConfig = makeServerConfig('', '', AuthMode.Guest);
  /** 保存成功 / 用户放弃时由子组件通知父组件关弹层 */
  onClose: () => void = (): void => {};

  @State editName: string = '';
  @State https: boolean = true;
  @State rest: string = '';
  @State username: string = '';
  @State password: string = '';
  @State remember: boolean = true;
  @State busy: boolean = false;
  @State errorText: string = '';
  /** 本机实际存储的凭据（退出登录会清掉 session/密码，状态行按实际值显示而非配置标志） */
  @State sessionSaved: boolean = false;
  @State passwordSaved: boolean = false;
  @State apiKeySaved: boolean = false;

  aboutToAppear(): void {
    this.editName = this.cfg.name;
    const p: ParsedUrl = parsePastedUrl(this.cfg.baseUrl);
    this.https = p.https;
    this.rest = p.rest;
    this.username = this.cfg.username;
    this.remember = this.cfg.rememberPassword;
    this.reloadCreds();
  }

  /** 读取该服务端在本机实际存的凭据，读完刷新状态行 */
  private async reloadCreds(): Promise<void> {
    try {
      const secrets = ServiceRegistry.getSecrets();
      this.sessionSaved = (await secrets.get(KeyFactory.sessionToken(this.cfg.id))).length > 0;
      this.passwordSaved = (await secrets.get(KeyFactory.password(this.cfg.id))).length > 0;
      this.apiKeySaved = (await secrets.get(KeyFactory.apiKey(this.cfg.id))).length > 0;
    } catch (e) {
      // 读不到按未存处理
    }
  }

  /** 已保存的认证状态（按本机实际存储的凭据展示，非活跃服务端也能看） */
  private statusLabel(): string {
    if (this.cfg.authMode === AuthMode.ApiKey) {
      return this.apiKeySaved ? '已用 API Key 登录，管理员权限，不会过期' : '未登录';
    }
    if (this.cfg.authMode === AuthMode.Guest) {
      return '游客身份浏览，未登录账号';
    }
    if (this.cfg.username.length === 0) {
      return '未登录';
    }
    if (this.sessionSaved) {
      return this.passwordSaved
        ? `已登录 ${this.cfg.username}，密码已记住，过期可自动重登`
        : `已登录 ${this.cfg.username}，密码未保存`;
    }
    if (this.passwordSaved) {
      return `已记住账号 ${this.cfg.username}，可静默重登`;
    }
    return '未登录';
  }

  /**
   * 按当前输入落盘服务端配置；域名变更时迁移条目并清理旧凭据。
   * 返回保存后的配置。
   */
  private async persistEdits(): Promise<ServerConfig> {
    // 与引导页一致：文本里残留显式协议头时以文本为准，并同步回协议按钮
    const eff: ParsedUrl = resolveScheme(this.https, this.rest);
    this.https = eff.https;
    this.rest = eff.rest;
    const baseUrl: string = buildBaseUrl(eff.https, eff.rest);
    const newId: string = makeServerId(baseUrl);
    const store = ServiceRegistry.getServerStore();

    if (newId !== this.cfg.id) {
      const list: ServerConfig[] = await store.listServers();
      let conflict: boolean = false;
      list.forEach((s: ServerConfig): void => {
        if (s.id === newId) {
          conflict = true;
        }
      });
      if (conflict) {
        throw new Error('该地址已存在另一个服务端，请先删除它或直接切换');
      }
      // 旧条目的凭据一并清理，避免孤儿 Asset 条目
      const secrets = ServiceRegistry.getSecrets();
      const aliases: string[] = [
        KeyFactory.sessionToken(this.cfg.id),
        KeyFactory.password(this.cfg.id),
        KeyFactory.apiKey(this.cfg.id)
      ];
      for (let i = 0; i < aliases.length; i++) {
        await secrets.remove(aliases[i]);
      }
      await store.removeServer(this.cfg.id);
    }

    const name: string = this.editName.trim().length > 0 ? this.editName.trim() : baseUrl;
    const cfg: ServerConfig = makeServerConfig(name, baseUrl, this.cfg.authMode);
    cfg.username = this.username.trim();
    cfg.rememberPassword = this.remember;
    await store.saveServer(cfg);
    return cfg;
  }

  private async saveAndSwitch(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (!validateHostRest(this.rest)) {
      this.errorText = '请输入正确的域名或 IP，例如 panel.example.com';
      return;
    }
    // 想登录但凭据没填全时直接提示，不发请求（本机已存会话时允许只改地址不重登）
    const hasUser: boolean = this.username.trim().length > 0;
    const hasPwd: boolean = this.password.length > 0;
    if (hasUser && !hasPwd && !this.sessionSaved) {
      this.errorText = '请输入密码';
      return;
    }
    if (!hasUser && hasPwd) {
      this.errorText = '请输入用户名';
      return;
    }
    this.busy = true;
    this.errorText = '';
    try {
      // 填全了账号密码：先对目标地址做登录预检——凭据错了就停在原服务端，
      // 不落盘不切换（否则切坏的新配置会让其他页面进入无服务端/检测中状态）
      if (hasUser && hasPwd) {
        const eff: ParsedUrl = resolveScheme(this.https, this.rest);
        await AuthService.probeLogin(buildBaseUrl(eff.https, eff.rest), this.username.trim(), this.password);
      }

      const cfg: ServerConfig = await this.persistEdits();
      await ServiceRegistry.useServer(cfg);
      NodeDataStore.getInstance().clear();

      const auth = ServiceRegistry.getAuth();
      if (hasUser && hasPwd) {
        await auth.login(this.username.trim(), this.password, '', this.remember);
      } else {
        // 未填账号密码：恢复该服务端已有的会话（可能是游客/已记住的 token）
        await auth.restore();
      }
      AppStorage.setOrCreate(AppKeys.SERVER_SEQ, Date.now());
      this.onClose();
    } catch (err) {
      const e = err as Error;
      this.errorText = e?.message ?? '保存失败';
    } finally {
      this.busy = false;
    }
  }

  private async useGuest(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (!validateHostRest(this.rest)) {
      this.errorText = '请输入正确的域名或 IP，例如 panel.example.com';
      return;
    }
    this.busy = true;
    this.errorText = '';
    try {
      const cfg: ServerConfig = await this.persistEdits();
      cfg.authMode = AuthMode.Guest;
      await ServiceRegistry.getServerStore().saveServer(cfg);
      await ServiceRegistry.useServer(cfg);
      NodeDataStore.getInstance().clear();
      // useAsGuest 不清除已保存凭据，之后可随时在登录页切回账号
      await ServiceRegistry.getAuth().useAsGuest();
      AppStorage.setOrCreate(AppKeys.SERVER_SEQ, Date.now());
      this.onClose();
    } catch (err) {
      const e = err as Error;
      this.errorText = e?.message ?? '操作失败';
    } finally {
      this.busy = false;
    }
  }

  private scroller: Scroller = new Scroller();

  /** 协议二选一按钮：选中实心 accent，未选中 page_bg（样式沿用 UrlInput 引导页的 pill） */
  @Builder
  pill(label: string, value: boolean) {
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

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 14 }) {
          // ===== 服务端信息 =====
          Column({ space: 12 }) {
            Text('服务端信息')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')

            Row({ space: 12 }) {
              Text('名称')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width(64)
              TextInput({ text: this.editName, placeholder: '显示在列表里的名字' })
                .height(44)
                .fontSize(15)
                .backgroundColor($r('app.color.page_bg'))
                .layoutWeight(1)
                .onChange((v: string): void => {
                  this.editName = v;
                })
            }
            .width('100%')

            Row({ space: 12 }) {
              Text('协议')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width(64)
              Row({ space: 8 }) {
                this.pill('HTTPS', true)
                this.pill('HTTP', false)
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

          // ===== 账号 =====
          Column({ space: 12 }) {
            Text('账号')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')

            Row({ space: 12 }) {
              Text('状态')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width(64)
              Text(this.statusLabel())
                .fontSize(13)
                .lineHeight(18)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
            }
            .width('100%')

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

            Row() {
              Text('记住密码')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width(64)
              Toggle({ type: ToggleType.Checkbox, isOn: this.remember })
                .onChange((on: boolean): void => {
                  this.remember = on;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            .onClick((): void => {
              this.remember = !this.remember;
            })

            Text('不填账号密码：保存后沿用现在的登录状态\n填了账号和密码：保存后立即用该账号重新登录')
              .fontSize(12)
              .lineHeight(19)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')

            if (this.cfg.rememberPassword && this.password.length === 0) {
              Text('这台手机已记住该账号的密码，会话过期会自动重新登录，无需重填')
                .fontSize(12)
                .lineHeight(19)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }

            Text('勾选「记住密码」后，密码加密保存在本机系统安全存储中，仅本应用可读、不会上传，只用于会话过期后自动重新登录；取消勾选会立即删除已保存的密码。')
              .fontSize(11)
              .lineHeight(17)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
          }
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          if (this.errorText.length > 0) {
            Text(this.errorText)
              .fontSize(13)
              .fontColor($r('app.color.status_bad'))
              .width('100%')
          }

          Button(this.busy ? '保存中…' : '保存并切换到此服务端')
            .fontSize(15)
            .fontColor(Color.White)
            .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
            .width('100%')
            .height(44)
            .enabled(!this.busy)
            .onClick((): void => {
              this.saveAndSwitch();
            })

          Button('以游客身份使用此服务端')
            .fontSize(14)
            .fontColor($r('sys.color.ohos_id_color_emphasize'))
            .backgroundColor($r('app.color.accent_soft'))
            .width('100%')
            .height(44)
            .enabled(!this.busy)
            .onClick((): void => {
              this.useGuest();
            })
        }
        .padding({ left: 16, right: 16, bottom: 20 })
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
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: true,
      content: {
        title: { mainTitle: '编辑服务端' },
        backIcon: {
          // 纯 xmark 符号：backIcon 槽位自带玻璃圆底，用带圆的 xmark_circle_fill
          // 会圆叠圆渲染出黑色叉底；纯符号粗细与各页返回箭头一致
          icon: $r('sys.symbol.xmark'),
          action: (): void => {
            this.onClose();
          }
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
