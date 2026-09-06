/**
 * OpenSourceLicensePage —— 开源许可（二级页，2026-09-07 新增；同日弹层化）
 *
 * 样式与刷新与性能等二级页一致：HdsNavigation MINI 标题栏 + 渐变模糊 + 材质。
 * 卡片底部两枚胶囊按钮：
 *   许可证按钮 → 弹层展示 Apache-2.0 离线全文（顶部在线链接 + 下方协议全文），
 *                履行 Apache-2.0 的保留声明义务；
 *   项目主页按钮 → 弹层内嵌 Web 直接加载项目网页。
 * 弹层设计与服务端编辑页一致：bindSheet LARGE + 嵌套 HdsNavigation
 * （xmark 关闭、GRADIENT_BLUR + IMMERSIVE/EXQUISITE 材质、dragBar/showClose 关闭）。
 * 仅放行 http/https 外链。
 */

import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { APACHE_LICENSE_20 } from '../common/constants/ApacheLicense20Text';

/** 开源组件声明项 */
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

@Entry
@Component
struct OpenSourceLicensePage {
  private scroller: Scroller = new Scroller();
  /** 当前弹层：'none' 关闭，'license' 协议全文，'home' 项目主页 */
  @State sheetMode: string = 'none';
  @State sheetShow: boolean = false;
  @State active: LicenseComponent = COMPONENTS[0];

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

  /** 胶囊按钮：椭圆灰色填充底，accent 文字（与协议二选一未选中态同底色） */
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

  @Builder
  sheetBuilder() {
    if (this.sheetMode === 'license') {
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

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          Text('LK监控 在开发中使用了以下优秀的开源组件，感谢原作者与开源社区的贡献。')
            .fontSize(13)
            .lineHeight(20)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 4, right: 4 })

          Text('本应用自身以 GNU GPL-3.0 许可开源发布，完整协议见项目仓库中的 LICENSE 文件。')
            .fontSize(13)
            .lineHeight(20)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 4, right: 4 })

          ForEach(COMPONENTS, (c: LicenseComponent) => {
            Column({ space: 8 }) {
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
            .padding(14)
            .borderRadius(20)
            .backgroundColor($r('app.color.card_bg'))
            .width('100%')
          }, (c: LicenseComponent) => c.name + '_' + c.version)

          Text('以上组件依其自带的开源许可证使用。许可证弹层内置离线全文，也可通过在线链接与项目主页查看最新内容。')
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
        title: { mainTitle: '开源许可' },
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
      // 与服务端编辑弹层同款：LARGE 高度 + 嵌套 HdsNavigation 自带标题栏与关闭按钮
      height: SheetSize.LARGE,
      dragBar: false,
      showClose: false
    })
  }
}

/** 协议全文弹层：顶部在线链接卡，下方离线内置的 Apache-2.0 全文 */
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
