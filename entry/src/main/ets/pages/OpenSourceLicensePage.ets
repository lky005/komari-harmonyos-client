/**
 * OpenSourceLicensePage —— 开源许可（二级页）
 *
 * 2026-09-16 从 AboutPage 拆出：组件声明卡列表过长，直排在关于页挤占主体内容，
 * 改为独立二级页。风格与刷新与性能 / 关于等二级页一致：
 *   HdsNavigation MINI 标题栏 + 渐变模糊 + IMMERSIVE/EXQUISITE 材质。
 *
 * 交互：
 *   - 有离线全文的许可（Apache-2.0）：点击「查看许可」→ bindSheet 弹层看离线版
 *   - 无离线全文的许可（CC BY / CC BY-SA）：点击「查看许可」→ 跳转系统浏览器
 *   - 「项目主页」→ 始终跳转系统浏览器
 */

import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { COMPONENTS, LicenseComponent, isSafeHttpUrl } from '../common/LicenseData';
import { LicenseSheet } from '../view/LicenseSheet';

@Entry
@Component
struct OpenSourceLicensePage {
  @State sheetShow: boolean = false;
  @State currentComponent: LicenseComponent | null = null;
  private scroller: Scroller = new Scroller();

  /** 跳转系统浏览器（仅放行 http/https） */
  private async openLink(url: string): Promise<void> {
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

  /** 点击「查看许可」：有离线全文则弹层，否则跳转浏览器 */
  private onViewLicense(c: LicenseComponent): void {
    if (c.licenseBlocks.length > 0) {
      this.currentComponent = c;
      this.sheetShow = true;
    } else {
      this.openLink(c.licenseUrl);
    }
  }

  @Builder
  licenseSheetBuilder() {
    if (this.currentComponent !== null) {
      LicenseSheet({
        title: this.currentComponent.licenseName,
        url: this.currentComponent.licenseUrl,
        blocks: this.currentComponent.licenseBlocks,
        onClose: (): void => {
          this.sheetShow = false;
        }
      })
    }
  }

  /** 胶囊按钮（与 AboutPage 同款） */
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

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          // ===== 说明卡：本应用许可 + 感谢语 + MaxMind 署名 =====
          Column({ space: 8 }) {
            Text('开源许可')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Text('LK监控 在开发中使用了以下优秀的开源组件与公开数据，感谢原作者与开源社区的贡献。')
              .fontSize(13)
              .lineHeight(20)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Text('本应用自身以 GNU GPL-3.0 许可开源发布，完整协议见项目仓库中的 LICENSE 文件。')
              .fontSize(13)
              .lineHeight(20)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            // MaxMind GeoLite EULA 第 3 条要求按示例原句署名，故逐字保留英文
            Text('This product includes GeoLite Data created by MaxMind, available from https://www.maxmind.com.')
              .fontSize(13)
              .lineHeight(20)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 组件声明卡列表 =====
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
              Row({ space: 10 }) {
                this.pillButton(c.licenseName, (): void => {
                  this.onViewLicense(c);
                })
                this.pillButton('项目主页', (): void => {
                  this.openLink(c.homeUrl);
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
    .bindSheet($$this.sheetShow, this.licenseSheetBuilder(), {
      // 与 AboutPage 许可弹层同款：内容自带标题栏与关闭按钮，dragBar 会形成双重头部
      height: SheetSize.LARGE,
      dragBar: false,
      showClose: false
    })
  }
}
