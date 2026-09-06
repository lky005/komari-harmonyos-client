/**
 * AboutPage —— 关于（二级页，2026-09-07 新增）
 *
 * 样式与开源许可/刷新与性能等二级页一致：HdsNavigation MINI 标题栏 +
 * 渐变模糊 + IMMERSIVE/EXQUISITE 材质。内容为纯展示的说明页：
 *   应用身份卡（图标 + 名称 + 版本 + 一句话定位，居中）；
 *   应用介绍卡（只读查看与隐私口径）；
 *   功能一览卡（图标 + 标题 + 说明的条目行）；
 *   其他信息卡（版本/系统要求/上游项目/源码许可 + 开源许可入口行，整行可点）；
 *   底部免责与反馈小字。
 * 版本号运行时从包信息读取（bundleManager），不与 app.json5 重复维护。
 */

import { router } from '@kit.ArkUI';
import { bundleManager } from '@kit.AbilityKit';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';

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

  private openLicenses(): void {
    router.pushUrl({ url: 'pages/OpenSourceLicensePage' });
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
                Text('开源许可')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                Text('组件声明与协议全文')
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
              this.openLicenses();
            })
          }
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
  }
}
