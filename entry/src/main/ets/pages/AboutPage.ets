/**
 * AboutPage —— 关于（二级页，2026-09-07 新增）
 *
 * 样式与开源许可/刷新与性能等二级页一致：HdsNavigation MINI 标题栏 +
 * 渐变模糊 + IMMERSIVE/EXQUISITE 材质。内容为纯展示的说明页：
 *   应用身份卡（图标 + 名称 + 版本 + 一句话定位，居中）；
 *   应用介绍卡（只读查看与隐私口径）；
 *   功能一览卡（图标 + 标题 + 说明的条目行）；
 *   其他信息卡（版本/系统要求/上游项目/源码许可 + 隐私说明/开源许可入口行，整行可点）；
 *   底部免责与反馈小字。
 * 隐私说明入口 → bindSheet LARGE 弹层（与许可弹层同款：嵌套 HdsNavigation、
 * xmark 关闭、GRADIENT_BLUR + IMMERSIVE/EXQUISITE 材质）：标题/盾牌/日期 +
 * 离线声明全文，链接卡置文末。
 * 开源许可（2026-09-07 自二级页合并，设置页入口与二级页已删）：说明文字 +
 * 组件声明卡直排在本页，胶囊按钮弹层看 Apache-2.0 全文 / 项目主页；
 * 三个弹层共用一个 bindSheet，按 sheetMode 路由。
 * 版本号运行时从包信息读取（bundleManager），不与 app.json5 重复维护。
 */

import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { PrivacyPolicy, PolicyBlock, PolicySpan } from '../common/constants/PrivacyPolicy';
import { PrivacyGate, RevokeState } from '../common/PrivacyGate';
import { PrivacyRevoke, RevokeOutcome } from '../common/PrivacyRevoke';
import { APACHE_LICENSE_20 } from '../common/constants/ApacheLicense20Text';
import { isPrivateHost } from '../view/UrlInput';

/** 开源组件声明项（自开源许可二级页合并入此） */
interface LicenseComponent {
  name: string;
  version: string;
  origin: string;
  copyright: string;
  licenseName: string;
  licenseUrl: string;
  homeUrl: string;
}

const COMPONENTS: LicenseComponent[] = [
  {
    name: '@ohos/mpchart',
    version: '3.0.30',
    origin: 'OpenHarmony 图表库，移植自 MPAndroidChart 3.1.0',
    copyright: 'Copyright 2020 Philipp Jahoda',
    licenseName: 'Apache License 2.0',
    licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
    homeUrl: 'https://gitcode.com/openharmony-tpc/ohos_mpchart'
  }
];

/** 仅放行 http/https 外链（拦截其余 scheme） */
function isSafeHttpUrl(url: string): boolean {
  return url.startsWith('http://') || url.startsWith('https://');
}

/** 官方文本每行自带前导缩进与 72 列硬换行：逐行剥掉缩进后，段内行用空格
 * 重新拼成自然长句，交由 Text 按屏幕宽度自然折行（措辞一字不动）。
 * 仅文书抬头（首块）保留换行，维持三行形式。 */
function flattenBlock(block: string, sep: string): string {
  return block.split('\n')
    .map((l: string): string => l.trim())
    .filter((l: string): boolean => l.length > 0)
    .join(sep)
    .replace(/ {2,}/g, ' ');
}

const LICENSE_BLOCKS: string[] = APACHE_LICENSE_20.split('\n\n')
  .map((b: string, i: number): string => flattenBlock(b, i === 0 ? '\n' : ' '))
  .filter((b: string): boolean => b.length > 0);

/** 条款标题形如 "2. Grant of Copyright License."，与后续正文同行出现，渲染时拆开（第 1 组=标题，第 2 组=剩余正文，可为空串） */
const NUM_HEAD_RE: RegExp = /^\s*(\d+\.\s+[^.]+\.)([\s\S]*)$/;

/** 全大写的小节分隔标题（TERMS AND CONDITIONS… / END OF TERMS AND CONDITIONS / APPENDIX…） */
function isCapsHeading(block: string): boolean {
  const t: string = block.trim();
  return t === t.toUpperCase() && /[A-Z]/.test(t);
}

/** 功能一览条目 */
interface FeatureItem {
  icon: Resource;
  title: string;
  desc: string;
}

/** infoRow 入参：@Builder 必须按引用传对象字面量才随 @State 动态重渲染 */
interface InfoRowParam {
  label: string;
  value: string;
}

const FEATURES: FeatureItem[] = [
  {
    icon: $r('sys.symbol.gauge_with_dots_needle_33percent'),
    title: '节点与指标',
    desc: 'CPU、内存、磁盘、实时网速与 GPU 用量，支持历史曲线'
  },
  {
    icon: $r('sys.symbol.stopwatch'),
    title: 'Ping 监控',
    desc: '按任务查看延迟曲线与丢包统计'
  },
  {
    icon: $r('sys.symbol.square_stack_3d'),
    title: '多服务端',
    desc: '添加多台 Komari 服务器，随时切换'
  },
  {
    icon: $r('sys.symbol.circle_lefthalf_inset_filled'),
    title: '深浅色',
    desc: '跟随系统自动切换'
  }
];

@Entry
@Component
struct AboutPage {
  @State versionName: string = '';
  /** 当前弹层：'none' 关闭，'privacy' 隐私说明，'revoke' 撤回隐私授权，'license' 协议全文，'home' 项目主页 */
  @State sheetMode: string = 'none';
  @State sheetShow: boolean = false;
  @State active: LicenseComponent = COMPONENTS[0];
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.versionName = info.versionName;
    } catch (e) {
      // 读不到包信息时版本显示占位符，不阻塞页面
      this.versionName = '';
    }
  }

  private versionText(): string {
    return this.versionName.length > 0 ? this.versionName : '—';
  }

  /** 弹层路由：隐私说明 / 撤回授权 / 协议全文 / 项目主页（同一 bindSheet 承载，动画一致） */
  @Builder
  sheetBuilder() {
    if (this.sheetMode === 'privacy') {
      PrivacySheet({
        onClose: (): void => {
          this.sheetShow = false;
        }
      })
    } else if (this.sheetMode === 'revoke') {
      RevokeSheet({
        onClose: (): void => {
          this.sheetShow = false;
        }
      })
    } else if (this.sheetMode === 'license') {
      LicenseSheet({
        url: this.active.licenseUrl,
        onClose: (): void => {
          this.sheetShow = false;
        }
      })
    } else if (this.sheetMode === 'home') {
      WebSheet({
        title: '项目主页',
        url: this.active.homeUrl,
        onClose: (): void => {
          this.sheetShow = false;
        }
      })
    } else {
      Column()
    }
  }

  private openPrivacySheet(): void {
    this.sheetMode = 'privacy';
    this.sheetShow = true;
  }

  private openRevokeSheet(): void {
    this.sheetMode = 'revoke';
    this.sheetShow = true;
  }

  private openLicenseSheet(c: LicenseComponent): void {
    if (!isSafeHttpUrl(c.licenseUrl)) {
      return;
    }
    this.active = c;
    this.sheetMode = 'license';
    this.sheetShow = true;
  }

  private openHomeSheet(c: LicenseComponent): void {
    if (!isSafeHttpUrl(c.homeUrl)) {
      return;
    }
    this.active = c;
    this.sheetMode = 'home';
    this.sheetShow = true;
  }

  /** 胶囊按钮：椭圆灰底、accent 文字（原开源许可二级页同款） */
  @Builder
  pillButton(label: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor($r('sys.color.ohos_id_color_emphasize'))
      .backgroundColor($r('app.color.page_bg'))
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .borderRadius(999)
      .onClick((): void => {
        action();
      })
  }

  /** 信息行：左标签（宽 64）+ 右值（与设置页登录状态卡同款） */
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

  /** 功能条目行：圆角小底图标 + 标题/说明，一顺溜居左 */
  @Builder
  featureRow(item: FeatureItem) {
    Row({ space: 12 }) {
      Column() {
        SymbolGlyph(item.icon)
          .fontSize(16)
          .fontColor([$r('sys.color.ohos_id_color_emphasize')])
      }
      .justifyContent(FlexAlign.Center)
      .width(30)
      .height(30)
      .borderRadius(9)
      .backgroundColor($r('app.color.page_bg'))

      Column({ space: 2 }) {
        Text(item.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text(item.desc)
          .fontSize(12)
          .lineHeight(17)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
  }

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          // ===== 应用身份卡：图标 + 名称 + 版本 + 定位语，居中 =====
          Column({ space: 2 }) {
            Image($r('app.media.startIcon'))
              .width(76)
              .height(76)
              .borderRadius(20)
              .margin({ bottom: 8 })
              .shadow({ radius: 10, color: 'rgba(0,0,0,0.08)', offsetY: 3 })
            Text($r('app.string.app_name'))
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text('版本 ' + this.versionText())
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ top: 2 })
            Text('把 Komari 服务器面板装进手机')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 8 })
          }
          .alignItems(HorizontalAlign.Center)
          .padding({ left: 14, right: 14, top: 24, bottom: 20 })
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 应用介绍 =====
          Column({ space: 8 }) {
            Text('应用介绍')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Text('在手机上查看 Komari 服务器监控数据，不开电脑也能随时了解每台机器的运行状态。应用只调用 Komari 的公开接口做只读查看，不会对服务器做任何管理操作；密码与会话保存在系统的加密存储中，不落明文。')
              .fontSize(13)
              .lineHeight(21)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 功能一览 =====
          Column({ space: 12 }) {
            Text('功能一览')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            ForEach(FEATURES, (item: FeatureItem, idx: number) => {
              Column({ space: 10 }) {
                if (idx > 0) {
                  Divider()
                    .color($r('app.color.page_bg'))
                    .strokeWidth(1)
                    .width('100%')
                }
                this.featureRow(item)
              }
              .width('100%')
            }, (item: FeatureItem) => item.title)
          }
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 其他信息：纯信息行 + 开源许可入口行 =====
          Column({ space: 12 }) {
            Text('其他信息')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')

            this.infoRow({ label: '版本', value: this.versionText() })
            this.infoRow({ label: '系统要求', value: 'HarmonyOS 6.1.1 及以上' })
            this.infoRow({ label: '上游项目', value: 'Komari（MIT 许可）' })
            this.infoRow({ label: '源码许可', value: 'GNU GPL-3.0' })

            Divider()
              .color($r('app.color.page_bg'))
              .strokeWidth(1)
              .width('100%')

            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('隐私说明')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                Text('声明全文与政策版本')
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text('›')
                .fontSize(18)
                .fontColor($r('app.color.text_tertiary'))
            }
            .alignItems(VerticalAlign.Center)
            .width('100%')
            .onClick((): void => {
              this.openPrivacySheet();
            })

            Divider()
              .color($r('app.color.page_bg'))
              .strokeWidth(1)
              .width('100%')

            // 撤回隐私授权：与「隐私说明」同一张卡、同款入口行，仅点击后弹层不同
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text('撤回隐私授权')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                Text('撤回同意并清除本机全部数据')
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text('›')
                .fontSize(18)
                .fontColor($r('app.color.text_tertiary'))
            }
            .alignItems(VerticalAlign.Center)
            .width('100%')
            .onClick((): void => {
              this.openRevokeSheet();
            })
          }
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 开源许可：原二级页说明合并入此，胶囊按钮弹层看全文/主页 =====
          Column({ space: 8 }) {
            Text('开源许可')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Text('LK监控 在开发中使用了以下优秀的开源组件，感谢原作者与开源社区的贡献。')
              .fontSize(13)
              .lineHeight(20)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Text('本应用自身以 GNU GPL-3.0 许可开源发布，完整协议见项目仓库中的 LICENSE 文件。')
              .fontSize(13)
              .lineHeight(20)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')

            ForEach(COMPONENTS, (c: LicenseComponent) => {
              Column({ space: 8 }) {
                Divider()
                  .color($r('app.color.page_bg'))
                  .strokeWidth(1)
                  .width('100%')
                Row({ space: 8 }) {
                  Text(c.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(c.version)
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .width('100%')
                Text(c.origin)
                  .fontSize(13)
                  .lineHeight(19)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                Text(c.copyright)
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                Divider()
                  .color($r('app.color.page_bg'))
                  .strokeWidth(1)
                  .width('100%')
                Row({ space: 10 }) {
                  this.pillButton(c.licenseName, (): void => {
                    this.openLicenseSheet(c);
                  })
                  this.pillButton('项目主页', (): void => {
                    this.openHomeSheet(c);
                  })
                }
                .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
            }, (c: LicenseComponent) => c.name + '_' + c.version)
          }
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 底部小字：授权与反馈口径，与 README 一致 =====
          Text('本应用为自由软件，您可以在 GNU GPL-3.0 许可下使用、修改与再分发，程序不提供任何形式的担保。多服务端等功能测试尚不充分，遇到问题欢迎反馈。')
            .fontSize(11)
            .lineHeight(18)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .padding({ left: 4, right: 4 })
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 20 })
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
        title: { mainTitle: '关于' },
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
    .bindSheet($$this.sheetShow, this.sheetBuilder(), {
      // 隐私说明 / 协议全文 / 项目主页 共用：LARGE 高度 + 嵌套 HdsNavigation 自带标题栏与关闭按钮
      height: SheetSize.LARGE,
      dragBar: false,
      showClose: false
    })
  }
}

/**
 * PrivacySheet —— 隐私说明弹层（关于页「隐私说明」入口）
 *
 * 与开源许可弹层同款：嵌套 HdsNavigation（xmark 关闭、GRADIENT_BLUR +
 * IMMERSIVE/EXQUISITE 材质；导航栏不设标题避免双标题）。唯一声明卡自上而下：
 * 标题居中 → 分层双色盾牌 → 更新日期 → 声明全文（BLOCKS，字数标点换行与
 * 网页可见渲染逐字一致，隐藏块不收录）→ 生效日期；「访问完整隐私政策」
 * 链接卡置于文末（仅放行 http/https、拒绝本机/内网/环回/保留地址）。
 * 排版对齐网页：16fp、1.4 行高、全文统一主色，仅 h5 章节标题加粗、
 * 首段词组加粗；更新日期居中 14fp。
 */
@Component
struct PrivacySheet {
  onClose: () => void = (): void => {};

  /**
   * 托管隐私声明链接：优先取华为云侧动态 URL —— AGC 侧重建设协议后旧
   * agreementId 会失效，硬编码不可靠；取不到时回退本地常量。
   */
  @State policyUrl: string = PrivacyPolicy.URL;

  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const dynamic: string = PrivacyGate.getPolicyUrl();
    if (dynamic.length > 0) {
      this.policyUrl = dynamic;
    }
  }

  /** 仅放行 http/https 且非本机/内网/环回/保留地址（与首启弹层同规则） */
  private urlAllowed(): boolean {
    const url: string = this.policyUrl;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return false;
    }
    const rest: string = url.substring(url.indexOf('://') + 3);
    return rest.length > 0 && !isPrivateHost(rest);
  }

  private openFullPolicy(): void {
    if (!this.urlAllowed()) {
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    (ctx as common.UIAbilityContext).openLink(this.policyUrl).catch((): void => {
      // 打不开浏览器时静默忽略
    });
  }

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          // ===== 声明卡：标题居中 → 盾牌 → 更新日期 → 全文 → 生效日期（间距大气） =====
          Column({ space: 6 }) {
            Text(PrivacyPolicy.TITLE)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .textAlign(TextAlign.Center)
              .width('100%')
              .margin({ top: 6, bottom: 12 })

            SymbolGlyph($r('sys.symbol.security_shield'))
              .fontSize(36)
              .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
              .fontColor([$r('app.color.text_primary'), $r('sys.color.ohos_id_color_emphasize')])
              .alignSelf(ItemAlign.Center)
              .margin({ bottom: 12 })

            Text(PrivacyPolicy.UPDATE_DATE)
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .textAlign(TextAlign.Center)
              .width('100%')
              .margin({ bottom: 10 })
              ForEach(PrivacyPolicy.BLOCKS, (b: PolicyBlock, idx: number): void => {
                if (b.heading) {
                  Text(b.spans[0].text)
                    .fontSize(16)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.text_primary'))
                    .width('100%')
                    .margin({ top: 12 })
                    .copyOption(CopyOptions.LocalDevice)
                } else {
                  Text() {
                    ForEach(b.spans, (s: PolicySpan, si: number): void => {
                      Span(s.text)
                        .fontSize(16)
                        .fontWeight(s.bold ? FontWeight.Bold : FontWeight.Normal)
                        .fontColor($r('app.color.text_primary'))
                    }, (s: PolicySpan, si: number): string => `${idx}_${si}_${s.bold ? 'b' : 'n'}`)
                  }
                  .lineHeight(22)
                  .width('100%')
                  .copyOption(CopyOptions.LocalDevice)
                }
              }, (b: PolicyBlock, idx: number): string => `priv_${idx}_${b.spans.length}`)

              Text(PrivacyPolicy.EFFECTIVE_DATE)
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .margin({ top: 16 })
                .copyOption(CopyOptions.LocalDevice)
          }
          .alignItems(HorizontalAlign.Start)
          .padding(20)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 在线链接卡：入口移至文末，网址降为极小浅灰次级信息 =====
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text('访问完整隐私政策')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .width('100%')
              Text(this.policyUrl)
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text('›')
              .fontSize(18)
              .fontColor($r('app.color.text_tertiary'))
          }
          .alignItems(VerticalAlign.Center)
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')
          .onClick((): void => {
            this.openFullPolicy();
          })
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 20 })
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
      // 弹层顶端已在状态栏之下，无需再避让（与开源许可弹层一致）
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: true,
      content: {
        // 标题已放进声明卡顶部居中，导航栏不再重复展示（避免双标题）
        title: { mainTitle: '' },
        backIcon: {
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

/** 协议全文弹层：顶部在线链接卡，下方离线内置的 Apache-2.0 全文（自开源许可二级页合并入此） */
@Component
struct LicenseSheet {
  url: string = '';
  onClose: () => void = (): void => {};

  private scroller: Scroller = new Scroller();

  private async openUrl(url: string): Promise<void> {
    if (!isSafeHttpUrl(url)) {
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      await (ctx as common.UIAbilityContext).openLink(url);
    } catch (e) {
      // 打不开浏览器时静默忽略
    }
  }

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          // ===== 在线链接卡：意图明确的入口，网址降为极小浅灰次级信息 =====
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text('访问官方协议网页')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .width('100%')
              Text(this.url)
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text('›')
              .fontSize(18)
              .fontColor($r('app.color.text_tertiary'))
          }
          .alignItems(VerticalAlign.Center)
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')
          .onClick((): void => {
            this.openUrl(this.url);
          })

          // ===== 离线全文卡：分块排版（标题居中、大写小节名强调、条款号拆为标题行） =====
          Column({ space: 8 }) {
            Text('协议全文（离线内置）')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Column({ space: 12 }) {
              ForEach(LICENSE_BLOCKS, (block: string, idx: number) => {
                if (idx === 0) {
                  // 文书抬头与条款一顺溜居左，视觉动线不换轨
                  Text(block)
                    .fontSize(14)
                    .lineHeight(21)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .width('100%')
                    .copyOption(CopyOptions.LocalDevice)
                } else if (isCapsHeading(block) || block.startsWith('APPENDIX:')) {
                  Text(block)
                    .fontSize(13)
                    .lineHeight(21)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .width('100%')
                    .copyOption(CopyOptions.LocalDevice)
                } else {
                  NumberedBlock({ block: block })
                }
              }, (block: string, idx: number) => 'lic_' + idx + '_' + block.length)
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 20 })
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
      // 弹层顶端已在状态栏之下，无需再避让（与服务端编辑弹层一致）
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: true,
      content: {
        title: { mainTitle: 'Apache License 2.0' },
        backIcon: {
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

/** 条款块：正文 13/22 行距；匹配 "N. 标题." 时把标题拆成主色加粗行 */
@Component
struct NumberedBlock {
  block: string = '';
  private head: string = '';
  private body: string = '';

  aboutToAppear(): void {
    const m: RegExpExecArray | null = NUM_HEAD_RE.exec(this.block);
    if (m !== null) {
      this.head = m[1];
      this.body = m[2].trim();
    } else {
      this.body = this.block.trim();
    }
  }

  build() {
    Column({ space: 3 }) {
      if (this.head.length > 0) {
        Text(this.head)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }
      Text(this.body)
        .fontSize(13)
        .lineHeight(22)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}

/** 项目主页弹层：内嵌 Web 直接加载项目网页；顶部细进度条 + 首帧加载指示 */
@Component
struct WebSheet {
  title: string = '';
  url: string = '';
  onClose: () => void = (): void => {};

  private controller: webview.WebviewController = new webview.WebviewController();
  @State progress: number = 0;
  @State loading: boolean = true;

  build() {
    HdsNavigation() {
      Column() {
        Stack({ alignContent: Alignment.Top }) {
          Web({ src: this.url, controller: this.controller })
            .domStorageAccess(true)
            .width('100%')
            .height('100%')
            .onPageBegin((_event: OnPageBeginEvent) => {
              this.loading = true;
              this.progress = 0;
            })
            .onProgressChange((event: OnProgressChangeEvent) => {
              this.progress = event.newProgress;
            })
            .onPageEnd((_event: OnPageEndEvent) => {
              this.loading = false;
              this.progress = 100;
            })

          // 顶部细进度条：加载期间贴在标题栏正下方
          if (this.loading) {
            Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(3)
              .color($r('sys.color.ohos_id_color_emphasize'))
          }

          // 首帧指示：尚未收到任何进度时盖住白屏，避免"弹层出来了但页面没反应"的不确定感
          if (this.loading && this.progress === 0) {
            Column({ space: 10 }) {
              LoadingProgress()
                .width(36)
                .height(36)
                .color($r('sys.color.ohos_id_color_emphasize'))
              Text('正在加载网页…')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.page_bg'))
          }
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: true,
      content: {
        title: { mainTitle: this.title },
        backIcon: {
          icon: $r('sys.symbol.xmark'),
          action: (): void => {
            this.onClose();
          }
        }
      },
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .backgroundColor($r('app.color.page_bg'))
  }
}

/**
 * RevokeSheet —— 「撤回隐私授权」弹层（关于页 → 隐私说明下方入口）
 *
 * 与隐私说明 / 许可 / 项目主页共用 AboutPage 的同一个 bindSheet，动画自然一致。
 * 内容 = 说明「将删除什么 + 什么后果」+ 红色主行动按钮；
 * 点按钮走 AlertDialog 二次确认，确认后才真正执行（见 common/PrivacyRevoke.ets）。
 *
 * 失败处理三档（不假装成功）：
 *   - 云端撤销失败 → 本机一个字节没动，提示重试，停留在本页
 *   - 部分数据未清干净 → 列出具体项，确认后再关闭应用
 *   - 全部成功 → 直接 terminateSelf（系统级销毁，走完整生命周期）
 *
 * 执行期间锁住关闭按钮与重复点击，避免中途退出留下"半清理"状态。
 */
@Component
struct RevokeSheet {
  onClose: () => void = (): void => {};

  /** 执行中：防重复点击，并锁住关闭入口 */
  @State busy: boolean = false;

  private scroller: Scroller = new Scroller();

  /** 二次确认：不可逆操作，必须明示删什么、什么后果 */
  private confirmRevoke(): void {
    if (this.busy) {
      return;
    }
    try {
      AlertDialog.show({
        title: '确认撤回隐私授权？',
        message: '将撤回你对《关于Lk监控与隐私的声明》的同意，并永久删除本机保存的'
          + '全部服务端配置、登录凭据、节点缓存与 Ping 记录。\n\n'
          + '此操作不可撤销，完成后应用将关闭。',
        autoCancel: true,
        alignment: DialogAlignment.Center,
        primaryButton: {
          value: '取消',
          action: (): void => {
            // 不撤回
          }
        },
        secondaryButton: {
          value: '确认撤回',
          fontColor: Color.White,
          backgroundColor: $r('app.color.status_bad'),
          action: (): void => {
            this.doRevoke();
          }
        }
      });
    } catch (e) {
      // 弹不出来等同于用户未确认：不做任何清理，保持原状最安全
      hilog.error(0x0000, 'RevokeSheet', 'confirm dialog failed: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 轻提示。失败路径上报必须尽力送达 —— 提示弹不出来会让用户
   * 误以为撤回成功，故这里吞掉异常而不是让它冒泡中断流程。
   */
  private toast(message: string, duration: number): void {
    try {
      promptAction.showToast({ message: message, duration: duration });
    } catch (e) {
      hilog.error(0x0000, 'RevokeSheet', 'toast failed: %{public}s', JSON.stringify(e));
    }
  }

  private async doRevoke(): Promise<void> {
    this.busy = true;
    let outcome: RevokeOutcome;
    try {
      outcome = await PrivacyRevoke.execute();
    } catch (e) {
      // 编排层已逐项兜底，走到这里属预期外异常：不退出，让用户重试
      this.busy = false;
      this.toast('撤回失败，本机数据未做改动，请重试', 2500);
      return;
    }

    if (!outcome.ok) {
      // 云端撤销失败 → 本机未做任何清理，保持原状退出更安全
      this.busy = false;
      this.toast('撤回失败：请检查网络后重试（本机数据未做任何改动）', 3000);
      return;
    }

    if (outcome.failures.length > 0) {
      // 部分失败：如实列出，用户确认后再关闭应用
      try {
        AlertDialog.show({
          title: '已撤回授权，但部分数据未清除',
          message: outcome.failures.join('\n') + '\n\n应用将关闭。如需彻底清除，可重新打开后再执行一次。',
          autoCancel: false,
          alignment: DialogAlignment.Center,
          confirm: {
            value: '知道了',
            action: (): void => {
              this.exitApp();
            }
          }
        });
      } catch (e) {
        // 列表弹不出来也不能卡在这里：授权已撤、数据已清，直接关闭应用
        hilog.error(0x0000, 'RevokeSheet', 'failure dialog failed: %{public}s', JSON.stringify(e));
        this.exitApp();
      }
      return;
    }

    this.exitApp();
  }

  /** 系统级 Ability 销毁：onDestroy 正常回调，不用任何强杀接口，避免闪退 */
  private exitApp(): void {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      this.busy = false;
      return;
    }
    (ctx as common.UIAbilityContext).terminateSelf().catch((e: BusinessError): void => {
      hilog.error(0x0000, 'RevokeSheet', 'terminateSelf failed: %{public}s', JSON.stringify(e));
      this.busy = false;
    });
  }

  /** 待删除项列表行 */
  @Builder
  bullet(text: string) {
    Row({ space: 8 }) {
      Text('·')
        .fontSize(15)
        .fontColor($r('app.color.text_tertiary'))
      Text(text)
        .fontSize(15)
        .lineHeight(22)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
  }

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          // ===== 说明卡：标题居中 → 引导句 → 待删除清单
          //       卡内边距/字号/层级与「隐私说明」弹层对齐 =====
          Column({ space: 12 }) {
            Text('撤回隐私授权')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .textAlign(TextAlign.Center)
              .width('100%')
              .margin({ top: 6, bottom: 2 })

            Text('撤回你对《关于Lk监控与隐私的声明》的同意后，本机保存的下列内容将被永久删除：')
              .fontSize(15)
              .lineHeight(22)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')

            Column({ space: 8 }) {
              this.bullet('全部服务端配置与访问地址')
              this.bullet('登录凭据：密码、API Key、会话 Token')
              this.bullet('本地缓存的节点数据与历史快照')
              this.bullet('Ping 详情记录')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .padding(20)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 后果卡：说明后续流程与不可逆性 =====
          Column({ space: 10 }) {
            Text('完成后应用会关闭。下次打开时，系统会再次弹出华为标准隐私弹窗，'
              + '需要重新同意声明并重新配置服务端，才能继续获取监控数据。')
              .fontSize(15)
              .lineHeight(22)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')

            Text('此操作不可撤销。')
              .fontSize(15)
              .lineHeight(22)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.status_bad'))
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .padding(20)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 红色主行动按钮 =====
          Button(this.busy ? '正在撤回…' : '撤回并清除数据')
            .enabled(!this.busy)
            .fontSize(16)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.status_bad'))
            .width('100%')
            .height(48)
            .borderRadius(24)
            .margin({ top: 4 })
            .onClick((): void => {
              this.confirmRevoke();
            })

          Text('与「退出登录」不同：退出登录只清除会话，本操作会一并删除服务端配置与本机全部缓存。')
            .fontSize(12)
            .lineHeight(18)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 20 })
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
        title: { mainTitle: '' },
        backIcon: {
          icon: $r('sys.symbol.xmark'),
          action: (): void => {
            // 执行中不允许关闭，避免留下"半清理"状态
            if (this.busy) {
              return;
            }
            this.onClose();
          }
        }
      },
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        // 滚动时顶部渐变模糊 —— 与其他弹层一致，这是「顶部样式」的关键
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
