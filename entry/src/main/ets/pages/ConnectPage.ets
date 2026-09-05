/**
 * ConnectPage —— 首启引导页（全屏页面形态）
 *
 * 表单主体已抽为 ConnectPanel 共用组件（「设置 → 管理我的服务端 → 添加服务端」
 * 走的是 ServerManagePage 里的同款弹层）。本页只保留引导语境：大标题、说明文案、
 * 跳过入口（在面板内），以及页面级 HdsNavigation 标题与滚动联动。
 *
 * 引导流程（对应设计文档 5.4 私有站点闸门，顺序不能反）：
 *   1. 协议按钮（https 默认 / http）+ 域名输入（粘贴完整链接自动解析）
 *   2. 输入校验（仅 http/https；host 合法性）+ http/内网黄色小字提醒（放行不阻断）
 *   3. 临时 RpcClient 调 rpc.ping 自检 → getPublicSettings 拿站点名/私有标记 → getVersion
 *   4. 保存 ServerConfig → useServer
 *      私有站点 → AuthPage(thenMain=true) 登录后清栈进主页
 *      公开站点 → 游客直接进，或选择登录后进
 *   5. 跳过：记 onboarded 标记，不配置服务端直接进主页（三 Tab 显示空态）
 */

import { router } from '@kit.ArkUI';
import {
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsNavigationTitleBarOptions,
  TitleBarStyleOptions,
  ScrollEffectType,
  BlurStrategy,
  hdsMaterial
} from '@kit.UIDesignKit';
import { ConnectPanel } from '../view/ConnectPanel';

@Entry
@Component
struct ConnectPage {
  private scroller: Scroller = new Scroller();

  private buildTitleBar(): HdsNavigationTitleBarOptions {
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
    // 首启/清栈重进时栈里没有来源页，不显示返回箭头
    return {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: {
        title: { mainTitle: '连接服务端' }
      },
      style: style
    };
  }

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 14 }) {
          Text('连接到 Komari')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text('选择协议并输入你自建面板的域名，例如 komari.example.com')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          ConnectPanel({
            chrome: false,
            sheetMode: false,
            showSkip: true
          })
        }
        .padding({ left: 20, right: 20, bottom: 20 })
        .width('100%')
        .constraintSize({ minHeight: '100%' })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .clip(false)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .titleBar(this.buildTitleBar())
    .titleMode(HdsNavigationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .backgroundColor($r('app.color.page_bg'))
  }
}
