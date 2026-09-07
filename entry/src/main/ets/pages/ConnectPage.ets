/**
 * ConnectPage —— 首启引导页（全屏页面形态，首启专用）
 *
 * 仅两个入口，均为 replaceUrl 清栈进入（栈深 1，标题栏必须显式 hideBackButton，
 * 见 build 末尾）：Index 首启未引导、启动兜底。主页空态「去添加服务端」
 * 已改为 MainPage 直接弹添加弹层，不再进本页。
 *
 * 表单主体 ConnectPanel 为两种形态共用组件（弹层形态同款）：
 * 连接测试成功后内联账号卡，登录在页面内完成（不跳二级登录页）。
 * 排版目标：一屏不滚动放下完整流程——标题栏小标题 + 右上角「跳过」，
 * 内容区从地址卡直接开始。
 *
 * 引导流程（对应设计文档 5.4 私有站点闸门，顺序不能反）：
 *   1. 地址卡：左侧协议按钮弹菜单气泡选 HTTPS/HTTP（粘贴完整链接自动解析）
 *   2. 输入校验（仅 http/https；host 合法性）+ http/内网黄色小字提醒（放行不阻断）
 *   3. 临时 RpcClient 调 rpc.ping 自检 → getPublicSettings 拿站点名/私有标记 → getVersion
 *   4. 内联账密「保存并进入」：填了账密先预检再落盘登录；不填按游客进入
 *      （私有站点拦下要求填写）——成功清栈进主页
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
import { ServiceRegistry } from '../common/ServiceRegistry';
import { ConnectPanel } from '../view/ConnectPanel';

@Entry
@Component
struct ConnectPage {
  private scroller: Scroller = new Scroller();

  /** 首启跳过：不配置服务端进主页，各 Tab 显示空态 */
  private async skip(): Promise<void> {
    try {
      await ServiceRegistry.getServerStore().putSetting('onboarded', '1');
    } catch (e) {
      // 标记失败不阻塞进入
    }
    router.clear();
    router.replaceUrl({ url: 'pages/MainPage' });
  }

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
    return {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: {
        // 引导页标题（MINI 小标题不占额外空间）；「跳过」在右上角，
        // menu 槽只支持图标，文字按钮走 stackBuilder
        title: { mainTitle: '连接 Komari' },
        stackBuilder: (): void => { this.skipButton(); }
      },
      style: style
    };
  }

  /** 标题栏右上角「跳过」：文字按钮，热区上下扩满标题栏 */
  @Builder
  skipButton() {
    Row() {
      Blank()
      Text('跳过')
        .fontSize(14)
        .fontColor($r('sys.color.ohos_id_color_emphasize'))
        .padding({ left: 12, right: 16, top: 14, bottom: 14 })
        .onClick((): void => {
          this.skip();
        })
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Center)
  }

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column() {
          ConnectPanel({
            chrome: false,
            sheetMode: false
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
    .titleBar(this.buildTitleBar())
    .titleMode(HdsNavigationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    // 首启引导页没有可返回的来源（replaceUrl 清栈进入），必须显式隐藏——
    // HdsNavigation 对未配置 backIcon 的页面默认渲染返回按钮，与栈深无关
    .hideBackButton(true)
    .backgroundColor($r('app.color.page_bg'))
  }
}
