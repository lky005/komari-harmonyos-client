/**
 * PrivacyConsentSheet —— 首启《关于Lk监控与隐私的声明》弹层（三步走合规流）
 *
 * 承载在 Index 启动页的 Stack 之上，开屏即入场。形态对齐鸿蒙系统
 * 「高级对话框」模板（量测自参考实现）：20% 轻遮罩、92% 宽小卡、
 * 居中小盾牌 + 居中 20fp 标题（紧凑视觉头部）、16fp 简短协议摘要、
 * 正文内联蓝字链接（Span.onClick 打开协议托管页全文）、底部通栏
 * 等宽文字按钮 + 细分隔线。动效分层：遮罩只淡入淡出，卡片轻张弹簧
 * （同主页页签转场）。返回键/侧滑由 Index.onBackPress 吞掉——
 * 必须做出选择才能离开：
 *   第一步  条款卡：简短摘要 + 可点击声明链接
 *   第二步  点「不同意」后换出挽留卡：解释不同意的后果（无法联网
 *           获取监控数据），提供 [再次阅读] / [退出应用]
 *   第三步  仅当用户在挽留卡显式点按「退出应用」才销毁：
 *           UIAbilityContext.terminateSelf() 走系统完整生命周期
 *           （onDestroy 正常回调），不用任何强杀接口，避免闪退；
 *           不落盘任何标记，下次启动重新弹层。
 *
 * 链接打开前校验：仅 http/https，拒绝本机/内网/环回/保留地址。
 * 条款摘要文案集中在 common/constants/PrivacyPolicy.ets。
 */

import { common } from '@kit.AbilityKit';
import { curves } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PrivacyPolicy } from '../common/constants/PrivacyPolicy';
import { isPrivateHost } from './UrlInput';

const DOMAIN = 0x0000;

/** 卡片入场轻张弹簧（同主页页签转场），退场快淡出 */
const CARD_TRANSITION: TransitionEffect = TransitionEffect.asymmetric(
  TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }))
    .animation({ curve: curves.springMotion(0.5, 0.78) }),
  TransitionEffect.OPACITY.animation({ duration: 150, curve: Curve.EaseOut })
);

/** 遮罩只做淡入淡出（系统对话框分层动效） */
const SCRIM_TRANSITION: TransitionEffect =
  TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut });

@Component
export struct PrivacyConsentSheet {
  /** 用户点「同意」：宿主负责落盘同意标记并放行启动路由 */
  onAgree: () => void = (): void => {};

  /** 0=条款卡，1=挽留卡 */
  @State step: number = 0;
  /** 退出请求已发出：防止重复触发 terminateSelf */
  @State exiting: boolean = false;

  /** 完整政策链接可用性：仅放行 http/https，拒绝本机/内网/环回/保留地址 */
  private fullUrlAllowed(): boolean {
    const url: string = PrivacyPolicy.URL;
    if (url.length === 0) {
      return false;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return false;
    }
    const rest: string = url.substring(url.indexOf('://') + 3);
    return rest.length > 0 && !isPrivateHost(rest);
  }

  private openFullPolicy(): void {
    if (!this.fullUrlAllowed()) {
      return;
    }
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    (ctx as common.UIAbilityContext).openLink(PrivacyPolicy.URL).catch((): void => {
      // 浏览器打开失败静默忽略
    });
  }

  /** 第三步唯一出口：系统级 Ability 销毁，onDestroy 正常回调 */
  private exitApp(): void {
    if (this.exiting) {
      return;
    }
    this.exiting = true;
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      this.exiting = false;
      return;
    }
    (ctx as common.UIAbilityContext).terminateSelf().catch((e: BusinessError): void => {
      // 销毁失败极少见：复位标记允许用户重试，不崩进程
      hilog.error(DOMAIN, 'testTag', 'terminateSelf failed: %{public}s', JSON.stringify(e));
      this.exiting = false;
    });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 半透明遮罩：盖住底下的启动画面，聚焦弹层
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.2)')
        .transition(SCRIM_TRANSITION)

      if (this.step === 0) {
        this.termsCard()
      } else {
        this.retentionCard()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 第一步：条款卡——小盾牌 + 标题区 + 简短摘要（内联可点链接）+ 按钮行 */
  @Builder
  termsCard() {
    Column() {
      SymbolGlyph($r('sys.symbol.security_shield'))
        .fontSize(30)
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
        .fontColor([$r('app.color.text_primary'), $r('sys.color.ohos_id_color_emphasize')])

      Text(PrivacyPolicy.HEADLINE)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 8 })

      Column({ space: 10 }) {
        Text() {
          Span(PrivacyPolicy.SUMMARY_INTRO)
          Span(`《${PrivacyPolicy.TITLE}》`)
            .fontColor($r('sys.color.ohos_id_color_emphasize'))
            .fontWeight(FontWeight.Medium)
            .onClick((): void => {
              this.openFullPolicy();
            })
          Span(PrivacyPolicy.SUMMARY_TAIL)
        }
        .fontSize(16)
        .lineHeight(22)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

        Text(PrivacyPolicy.SUMMARY_BODY)
          .fontSize(16)
          .lineHeight(22)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')

        Text(PrivacyPolicy.SUMMARY_OUTRO)
          .fontSize(16)
          .lineHeight(22)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .margin({ top: 14 })

      this.buttonRow('不同意', (): void => {
        this.step = 1;
      }, '同意', (): void => {
        this.onAgree();
      })
    }
    .padding(24)
    .borderRadius(24)
    .backgroundColor($r('app.color.card_bg'))
    .width('92%')
    .transition(CARD_TRANSITION)
  }

  /** 系统对话框同款通栏按钮：等宽文字键，左弱（次级灰）右强（主题蓝），细分隔线 */
  @Builder
  buttonRow(leftLabel: string, onLeft: () => void, rightLabel: string, onRight: () => void) {
    Row() {
      Button(leftLabel)
        .fontSize(16)
        .fontColor($r('app.color.text_secondary'))
        .backgroundColor(Color.Transparent)
        .layoutWeight(1)
        .height(40)
        .onClick((): void => {
          onLeft();
        })

      Divider()
        .vertical(true)
        .strokeWidth(0.5)
        .height(24)
        .color($r('app.color.divider'))

      Button(rightLabel)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_emphasize'))
        .backgroundColor(Color.Transparent)
        .layoutWeight(1)
        .height(40)
        .onClick((): void => {
          onRight();
        })
    }
    .width('100%')
    .margin({ top: 20 })
  }

  /** 第二步：挽留卡——解释后果，[再次阅读] 回条款卡，[退出应用] 才是唯一出口 */
  @Builder
  retentionCard() {
    Column() {
      Text('确定不同意吗？')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.Center)
        .width('100%')

      Text('不同意将无法使用 Lk监控：本应用需要联网获取并展示监控数据，在您同意声明之前不会建立任何网络连接。\n\n您可以再次阅读声明，或退出应用。')
        .fontSize(16)
        .lineHeight(22)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 16 })

      this.buttonRow('再次阅读', (): void => {
        this.step = 0;
      }, '退出应用', (): void => {
        this.exitApp();
      })
    }
    .padding(24)
    .borderRadius(24)
    .backgroundColor($r('app.color.card_bg'))
    .width('92%')
    .transition(CARD_TRANSITION)
  }
}
