/**
 * ServerEditSheet —— 服务端编辑半模态弹层（ServerManagePage 用）
 *
 * 把「编辑服务端信息」与「账号登录/切换」合并成一个动作面：
 *   - 信息段：名称 + 协议/域名（UrlInput，复用引导页防错逻辑）；
 *   - 账号段：当前保存的状态 + 账号密码（LoginForm，2FA 已按产品决策移除）；
 *   - 「保存并切换」：保存信息 → 设为当前服务端 → 填了账号密码就登录，
 *     否则 restore() 恢复既有会话 → bump SERVER_SEQ 通知各页重建轮询。
 *
 * 域名变更 = 条目迁移：删旧条目并清理旧 id 的本地凭据，避免孤儿 Asset 条目；
 * 目标地址已被其他条目占用时直接报错，不做合并。
 *
 * 注意：本组件不持有 @State cfg —— 父组件用「条件构建 + 关闭即置空」保证
 * 每次打开弹层都是全新实例，aboutToAppear 从 cfg 重新初始化各输入项。
 *
 * 顶部标题栏：bindSheet 没有可挂 hdsMaterial 系统材质的挂点，
 * 用 backgroundBlurStyle + 底部渐变蒙层近似 HDS 的「渐变模糊 + 玻璃材质」；
 * 内容 Stack 叠在标题栏下滚动，上滑时从模糊栏下方自然淡出。
 * 系统关闭叉号已由父组件 showClose:false 关掉，关闭按钮在标题栏右侧自绘，
 * 避免与内容卡片重叠。
 */

import { AuthMode, ServerConfig } from '../model/KomariTypes';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';
import { AppKeys } from '../common/constants/AppKeys';
import { makeServerConfig, makeServerId } from '../storage/ServerStore';
import { KeyFactory } from '../storage/SecretStore';
import { UrlInput, ParsedUrl, parsePastedUrl, validateHostRest, buildBaseUrl } from './UrlInput';
import { LoginForm } from './LoginForm';

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

  aboutToAppear(): void {
    this.editName = this.cfg.name;
    const p: ParsedUrl = parsePastedUrl(this.cfg.baseUrl);
    this.https = p.https;
    this.rest = p.rest;
    this.username = this.cfg.username;
    this.remember = this.cfg.rememberPassword;
  }

  /** 已保存的认证状态（按本地配置展示，非活跃服务端也能看） */
  private statusLabel(): string {
    if (this.cfg.authMode === AuthMode.ApiKey) {
      return 'API Key 登录（管理员权限，永不过期）';
    }
    if (this.cfg.authMode === AuthMode.Guest) {
      return '游客模式';
    }
    if (this.cfg.username.length > 0) {
      return this.cfg.rememberPassword ? `已保存账号 ${this.cfg.username}（记住密码）` : `已保存账号 ${this.cfg.username}`;
    }
    return '未登录';
  }

  /**
   * 按当前输入落盘服务端配置；域名变更时迁移条目并清理旧凭据。
   * 返回保存后的配置。
   */
  private async persistEdits(): Promise<ServerConfig> {
    const baseUrl: string = buildBaseUrl(this.https, this.rest);
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
    this.busy = true;
    this.errorText = '';
    try {
      const cfg: ServerConfig = await this.persistEdits();
      await ServiceRegistry.useServer(cfg);
      NodeDataStore.getInstance().clear();

      const auth = ServiceRegistry.getAuth();
      if (this.username.trim().length > 0 && this.password.length > 0) {
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

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 内容层：整高滚动，顶部 padding 让出固定标题栏（滚动时内容穿到模糊栏下方）
      Scroll() {
        Column({ space: 14 }) {
          // ===== 服务端信息 =====
          Column({ space: 10 }) {
            Text('服务端信息')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')

            TextInput({ text: this.editName, placeholder: '名称（显示在列表里）' })
              .height(44)
              .fontSize(15)
              .backgroundColor($r('app.color.page_bg'))
              .onChange((v: string): void => {
                this.editName = v;
              })

            UrlInput({
              https: $https,
              rest: $rest
            })
          }
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 账号 =====
          Column({ space: 10 }) {
            Text('账号')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')

            Text(`当前：${this.statusLabel()}`)
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
              .width('100%')

            LoginForm({
              username: $username,
              password: $password,
              remember: $remember
            })

            if (this.cfg.rememberPassword && this.password.length === 0) {
              Text('本机已记住密码，不填密码直接保存即可沿用自动重登')
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
            }
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
            .backgroundColor($r('app.color.accent'))
            .width('100%')
            .height(44)
            .enabled(!this.busy)
            .onClick((): void => {
              this.saveAndSwitch();
            })

          Button('以游客身份使用此服务端')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .backgroundColor(Color.Transparent)
            .width('100%')
            .height(40)
            .enabled(!this.busy)
            .onClick((): void => {
              this.useGuest();
            })
        }
        .padding({ left: 16, right: 16, top: 68, bottom: 20 })
        .width('100%')
        .constraintSize({ minHeight: '100%' })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })

      // 固定标题栏：玻璃模糊 + 底部渐变过渡（近似 HDS 渐变模糊材质）
      Column() {
        Row({ space: 8 }) {
          Text('编辑服务端')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Blank()
          SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
            .fontSize(22)
            .fontColor([$r('app.color.text_tertiary')])
            .onClick((): void => {
              this.onClose();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 8 })

        // 渐变过渡条：从栏底色渐隐到透明，内容上滑淡出更接近系统观感
        Row()
          .width('100%')
          .height(14)
          .linearGradient({
            angle: 180,
            colors: [[$r('app.color.page_bg'), 0.0], [Color.Transparent, 1.0]]
          })
      }
      .width('100%')
      .backgroundBlurStyle(BlurStyle.Regular)
    }
    .width('100%')
    .height('100%')
  }
}
