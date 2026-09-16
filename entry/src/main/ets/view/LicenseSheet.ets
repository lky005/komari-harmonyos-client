/**
 * LicenseSheet —— 协议全文弹层（顶部在线链接卡，下方离线内置全文或官方链接提示）
 *
 * 2026-09-16 从 AboutPage 提取，供 AboutPage 与 OpenSourceLicensePage 共用。
 * 与 PrivacySheet / RevokeSheet 同款：嵌套 HdsNavigation、xmark 关闭、
 * GRADIENT_BLUR + IMMERSIVE/EXQUISITE 材质。
 */

import { common } from '@kit.AbilityKit';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { isSafeHttpUrl, isCapsHeading, NUM_HEAD_RE } from '../common/LicenseData';

@Component
export struct LicenseSheet {
  /** 弹层标题：取组件声明的协议名，不再硬编码 Apache */
  title: string = '';
  url: string = '';
  /** 离线内置的协议全文分块；空数组 = 该协议不内置全文，只给官方链接与说明 */
  blocks: string[] = [];
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
          if (this.blocks.length > 0) {
            Column({ space: 8 }) {
              Text('协议全文（离线内置）')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              Column({ space: 12 }) {
                ForEach(this.blocks, (block: string, idx: number) => {
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
          } else {
            Column({ space: 6 }) {
              Text('协议全文（官方网页）')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              Text('该协议为通用许可协议，完整文本未随应用内置。请点击上方链接前往官方网页查看全文。')
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
          }
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
export struct NumberedBlock {
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
