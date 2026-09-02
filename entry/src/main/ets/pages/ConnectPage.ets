/**
 * ConnectPage —— 首次连接页
 *
 * 流程（对应设计文档 5.4 私有站点闸门，顺序不能反）：
 *   1. 输入地址 → 临时 RpcClient 调 rpc.ping 自检连通性
 *   2. public:getPublicSettings 拿站点名 + 是否私有站点
 *   3. public:getVersion 拿版本（顺带确认 JSON-RPC 通路）
 *   4. 保存 ServerConfig → useServer →（私有站点或用户选择登录时先登录）
 *   5. replaceUrl 进 MainPage
 *
 * 私有站点下游客拿不到节点列表，"游客进入"按钮必须禁用。
 */

import { router } from '@kit.ArkUI';
import { AuthMode, PublicSettings, ServerConfig, VersionInfo } from '../model/KomariTypes';
import { HeaderProvider, HttpRpcClient } from '../service/RpcClient';
import { KomariApi } from '../service/KomariApi';
import { makeServerConfig } from '../storage/ServerStore';
import { ServiceRegistry } from '../common/ServiceRegistry';

interface ProbeResult {
  settings: PublicSettings;
  version: VersionInfo;
}

@Entry
@Component
struct ConnectPage {
  @State url: string = '';
  @State probing: boolean = false;
  @State result: ProbeResult | undefined = undefined;
  @State errorText: string = '';
  @State wantLogin: boolean = false;
  @State username: string = '';
  @State password: string = '';
  @State remember: boolean = true;
  @State entering: boolean = false;

  /** 输入规范化：无协议时默认补 https:// */
  private cleanUrl(): string {
    let u: string = this.url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.length > 0 && !u.startsWith('http://') && !u.startsWith('https://')) {
      u = `https://${u}`;
    }
    return u;
  }

  private async probe(): Promise<void> {
    const baseUrl: string = this.cleanUrl();
    if (baseUrl.length === 0) {
      this.errorText = '请输入服务端地址';
      return;
    }
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
      // 私有站点必须登录
      this.wantLogin = settings.private_site;
    } catch (err) {
      const e = err as Error;
      this.result = undefined;
      this.errorText = e?.message ?? '连接失败';
    } finally {
      this.probing = false;
    }
  }

  /** 保存配置 → useServer →（可选登录）→ 进主页 */
  private async enter(withLogin: boolean): Promise<void> {
    const r = this.result;
    if (!r) {
      return;
    }
    this.entering = true;
    this.errorText = '';
    try {
      const baseUrl: string = this.cleanUrl();
      const siteName: string = r.settings.sitename && r.settings.sitename.length > 0 ? r.settings.sitename : baseUrl;
      const cfg: ServerConfig = makeServerConfig(siteName, baseUrl,
        r.settings.private_site ? AuthMode.Password : AuthMode.Guest);
      await ServiceRegistry.getServerStore().saveServer(cfg);
      await ServiceRegistry.useServer(cfg);

      if (withLogin) {
        if (this.username.trim().length === 0 || this.password.length === 0) {
          this.errorText = '请输入用户名和密码';
          this.entering = false;
          return;
        }
        const auth = ServiceRegistry.getAuth();
        await auth.login(this.username.trim(), this.password, '', this.remember);
      }
      // 通知列表类页面重建轮询（从"服务端管理 → 添加"进来时 MainPage 已在栈里）
      AppStorage.setOrCreate('komari_server_seq', Date.now());
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

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          Text('连接到 Komari')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text('输入你自建 Komari 面板的地址，例如 komari.example.com')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          TextInput({ text: this.url, placeholder: 'https://your-komari.example.com' })
            .height(44)
            .fontSize(15)
            .backgroundColor($r('app.color.card_bg'))
            .onChange((v: string): void => {
              this.url = v;
            })

          Button(this.probing ? '连接中…' : '测试连接')
            .fontSize(15)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.accent'))
            .width('100%')
            .height(44)
            .enabled(!this.probing && !this.entering)
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
            .borderRadius(12)
            .backgroundColor($r('app.color.card_bg'))
            .width('100%')

            // 登录表单：私有站点强制显示，公开站点可展开
            if (this.result.settings.private_site || this.wantLogin) {
              this.loginForm(true)
            } else {
              Button('以游客身份进入')
                .fontSize(15)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.status_ok'))
                .width('100%')
                .height(44)
                .enabled(!this.entering && !this.probing)
                .onClick((): void => {
                  this.enter(false);
                })

              Button(this.wantLogin ? '收起登录' : '使用账号登录（可查看隐藏节点）')
                .fontSize(13)
                .fontColor($r('app.color.accent'))
                .backgroundColor(Color.Transparent)
                .width('100%')
                .enabled(!this.entering && !this.probing)
                .onClick((): void => {
                  this.wantLogin = !this.wantLogin;
                })
            }
          }
        }
        .padding(20)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  loginForm(required: boolean) {
    Column({ space: 10 }) {
      Text(required ? '该站点为私有，请登录后继续' : '账号登录')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      TextInput({ text: this.username, placeholder: '用户名' })
        .height(44)
        .fontSize(15)
        .backgroundColor($r('app.color.card_bg'))
        .onChange((v: string): void => {
          this.username = v;
        })

      TextInput({ text: this.password, placeholder: '密码' })
        .type(InputType.Password)
        .height(44)
        .fontSize(15)
        .backgroundColor($r('app.color.card_bg'))
        .onChange((v: string): void => {
          this.password = v;
        })

      Row({ space: 8 }) {
        Toggle({ type: ToggleType.Checkbox, isOn: this.remember })
          .onChange((on: boolean): void => {
            this.remember = on;
          })
        Text('记住密码（30 天过期后自动重登）')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')

      Button(this.entering ? '进入中…' : '登录并进入')
        .fontSize(15)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.accent'))
        .width('100%')
        .height(44)
        .enabled(!this.entering && !this.probing)
        .onClick((): void => {
          this.enter(true);
        })
    }
    .padding(14)
    .borderRadius(12)
    .backgroundColor($r('app.color.card_bg'))
    .width('100%')
  }
}
