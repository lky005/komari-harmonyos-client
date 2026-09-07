/**
 * MainPage —— 主界面（HDS 沉浸光感架构）
 *
 * HdsNavigation（根容器，标题+搜索框，IMMERSIVE_GRADIENT_BLUR 滚动渐变模糊）
 *   └── HdsTabs（底部悬浮光感 Tab 栏）
 *         ├── Tab0 NodesPage（节点列表）
 *         ├── Tab1 PingPage
 *         └── Tab2 设置面板
 *
 * 添加服务端弹层挂本页（Stack 宿主 + bindSheet）：节点/Ping 空态
 * 「去添加服务端」直接弹出 ConnectPanel（与管理页添加同款、内联账密登录），
 * 不再进二级页面。
 *
 * 切页方式（2026-09-07 从横滑改为原地淡入）：
 *   3 个 TabContent 保留（页签栏布局不变），但内容按 currentTab 条件渲染——
 *   非当前 TabContent 为空壳，当前页根容器挂 PAGE_TRANSITION
 *   （出现=淡入+0.96→1 张开，消失=快速淡出），即"原地淡出+张开"效果；
 *   HdsTabs.scrollable(false) 关掉左右横滑手势，animationDuration(0) 关掉
 *   自带切页动画，视觉完全由转场接管，切页只认页签点击。
 *   坑：不能合并成单 TabContent + 整条自定义 bar 构建器——HdsTabs 悬浮栏
 *   会收缩成内容宽度，页签挤在中间（真机实测）。
 *   页面销毁重建后轮询自动停启（两页均在 aboutToDisappear 清理定时器），
 *   滚动偏移在切页前保存、新列表构建完成后延迟恢复。
 *   Ping 页数据经模块级缓存跨重建保留（见 PingPage.ets），重建即秒开不闪加载圈。
 *
 * 材质：支持 IMMERSIVE 时强制 IMMERSIVE + EXQUISITE（最高档，带玻璃反射）；
 * ADAPTIVE 类型会跟随系统沉浸光感设置（默认均衡 GENTLE），故不可用。
 * 不支持 IMMERSIVE 时降级 ADAPTIVE + SMOOTH。
 * 避坑：titleBar 不设不透明背景色，否则覆盖沉浸光感材质层。
 */

import {
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsNavigationTitleBarOptions,
  HdsTabs,
  HdsTabsController,
  ScrollEffectType,
  BlurStrategy,
  BottomBuilderShowType,
  hdsMaterial
} from '@kit.UIDesignKit';
import { curves } from '@kit.ArkUI';
import { vibrator } from '@kit.SensorServiceKit';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AppKeys } from '../common/constants/AppKeys';
import { NodesPage } from './NodesPage';
import { PingPage } from './PingPage';
import { SettingsPane } from './SettingsPane';
import { ConnectPanel } from '../view/ConnectPanel';

/**
 * 页签切换转场（优雅快版）：
 *   出现 = 淡入 + 0.98→1 轻张（幅度刻意小，只提供"活"的气息不抢戏），
 *   curves.springMotion(0.5, 0.78) 物理弹簧——起步依旧快，拖尾比 0.4/0.85
 *   更慢更柔（降阻尼换更长的自然衰减，无明显回弹）；
 *   消失 = 纯淡出 150ms EaseOut，快速让位。
 *   对比：AnimateParam 官方默认 1000ms + EaseInOut（拖）；springMotion 默认
 *   参数是 response 0.55 / damping 0.825。
 */
const PAGE_TRANSITION = TransitionEffect.asymmetric(
  TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.99, y: 0.99 }))
    .animation({ curve: curves.springMotion(0.5, 0.78) }),
  TransitionEffect.OPACITY.animation({ duration: 150, curve: Curve.EaseOut })
);

@Entry
@Component
struct MainPage {
  @State searchKeyword: string = '';
  @State currentTab: number = 0;
  @State currentTitle: string = '';
  @State materialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
  @State materialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.ADAPTIVE;
  @StorageProp(AppKeys.NAV_INDICATOR_HEIGHT) navIndicatorHeight: number = 0;
  @StorageProp(AppKeys.NODES_TOTAL) nodesTotal: number = 0;
  @StorageProp(AppKeys.NODES_ONLINE) nodesOnline: number = 0;

  private tabsController: HdsTabsController = new HdsTabsController();
  private nodesScroller: Scroller = new Scroller();
  private pingScroller: Scroller = new Scroller();
  private tabOffsets: number[] = [0, 0, 0];
  /** 设置页引用：onPageShow 时调 refreshAuthState，getCurrentScroller 时调 getScroller */
  private settingsPane: SettingsPane | null = null;
  /** 添加服务端弹层（主页空态直接弹出，不进二级页面；与管理页添加同款面板） */
  @State addSheetShow: boolean = false;

  /** 指定 Tab 的 scroller（设置页 scroller 由 SettingsPane 内部管理，经 getScroller() 暴露） */
  private scrollerForTab(index: number): Scroller {
    if (index === 0) {
      return this.nodesScroller;
    } else if (index === 1) {
      return this.pingScroller;
    }
    return this.settingsPane?.getScroller() ?? this.nodesScroller;
  }

  /**
   * 当前 Tab 对应的 scroller，供 bindToScrollable 动态单向绑定。
   * 三个 Tab 统一使用 List 容器，均参与联动（滚动渐变模糊）。
   * 内容不足时的弹性回弹由 edgeEffect 的 alwaysEnabled:true 保证（API 11+）。
   */
  private getCurrentScroller(): Scroller {
    return this.scrollerForTab(this.currentTab);
  }

  /**
   * 页签点击震感：sharp 预设（haptic.effect.sharp）短促脆响，与转场快速起步
   * 同拍。usage='touch' 走系统触摸通道受设置里的触摸振动开关约束。
   * 失败一律静默（无振动器/不支持该预设）。
   */
  private tabHaptic(): void {
    try {
      vibrator.startVibration(
        { type: 'preset', effectId: vibrator.HapticFeedback.EFFECT_SHARP, count: 1 },
        { usage: 'touch' }
      ).catch((): void => {
        // 设备不支持该预设效果，静默
      });
    } catch (e) {
      // 无振动器等环境异常，静默
    }
  }

  /** 切换活跃 Tab：先存当前页滚动偏移，换页后延迟恢复目标页偏移（轮询随页面销毁/重建自动停启） */
  private switchTab(index: number): void {
    if (this.currentTab === index) {
      return;
    }
    this.tabHaptic();
    try {
      this.tabOffsets[this.currentTab] = this.getCurrentScroller().currentOffset().yOffset;
    } catch (e) {
      // 忽略：取不到偏移就当没滚过
    }
    this.currentTab = index;
    if (index === 0) {
      this.currentTitle = '';
    } else if (index === 1) {
      this.currentTitle = 'Ping 监控';
    } else {
      this.currentTitle = '设置';
    }
    // 仅当目标页滚动过（记录偏移>0）才恢复位置；
    // 未滚动过的 Tab 保持列表初始联动状态（bindToScrollable 初始化自带偏移，
    // scrollTo(0) 会抹掉它导致内容顶到玻璃标题栏后面）。
    // if/else 换页后新列表要等本帧渲染完才存在，延迟一拍再 scrollTo（闭包捕获 index）。
    if (this.tabOffsets[index] > 0) {
      const target: number = index;
      const targetOffset: number = this.tabOffsets[index];
      setTimeout((): void => {
        try {
          this.scrollerForTab(target).scrollTo({ xOffset: 0, yOffset: targetOffset });
        } catch (e) {
          // 目标页构建失败等异常场景直接放弃恢复
        }
      }, 100);
    }
  }

  aboutToAppear(): void {
    // 材质：支持 IMMERSIVE 时强制用 IMMERSIVE 类型 + EXQUISITE 级别（最高档，带玻璃反射）；
    // ADAPTIVE 类型会跟随系统沉浸光感设置（系统默认均衡 GENTLE），导致 EXQUISITE 被静默降级。
    // 不支持 IMMERSIVE 时降级 ADAPTIVE + SMOOTH，避免高级光感被丢弃。
    try {
      const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      console.info(`Komari material types: ${JSON.stringify(types)}`);
      if (types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) < 0) {
        this.materialType = hdsMaterial.MaterialType.ADAPTIVE;
        this.materialLevel = hdsMaterial.MaterialLevel.SMOOTH;
      } else {
        this.materialType = hdsMaterial.MaterialType.IMMERSIVE;
        this.materialLevel = hdsMaterial.MaterialLevel.EXQUISITE;
      }
      console.info(`Komari material set: type=${this.materialType}, level=${this.materialLevel}`);
    } catch (e) {
      console.info(`Komari material detect failed: ${JSON.stringify(e)}`);
      this.materialType = hdsMaterial.MaterialType.ADAPTIVE;
      this.materialLevel = hdsMaterial.MaterialLevel.SMOOTH;
    }
    AppStorage.setOrCreate(AppKeys.SEARCH_KEYWORD, '');
  }

  onPageShow(): void {
    // 从 ServerManagePage 返回时刷新设置页认证状态
    this.settingsPane?.refreshAuthState();
  }

  /** 添加服务端弹层：与 ServerManagePage 的添加入口同款 ConnectPanel（内联账密登录） */
  @Builder
  addSheetBuilder() {
    ConnectPanel({
      chrome: true,
      sheetMode: true,
      onClose: (): void => {
        this.addSheetShow = false;
      }
    })
  }

  /** 获取集群整体健康度指示灯颜色（走资源，深浅色各自定义） */
  private getHealthColor(): ResourceColor {
    if (this.nodesTotal === 0) {
      return $r('app.color.health_none');
    }
    if (this.nodesOnline === this.nodesTotal) {
      return $r('app.color.health_all_ok');
    }
    if (this.nodesOnline > 0) {
      return $r('app.color.health_partial');
    }
    return $r('app.color.status_bad');
  }

  /** 健康度指示灯发光阴影：直接用主色的半透明版本（走资源） */
  private getHealthShadowColor(): ResourceColor {
    if (this.nodesTotal === 0) {
      return $r('app.color.health_none');
    }
    if (this.nodesOnline === this.nodesTotal) {
      return $r('app.color.health_all_ok');
    }
    if (this.nodesOnline > 0) {
      return $r('app.color.health_partial');
    }
    return $r('app.color.status_bad');
  }

  // ===== titleBar 配置（按 Tab 条件化构建）=====

  /**
   * 头部布局范式：父级 HdsNavigation 统一管理安全区与标题。
   * - avoidLayoutSafeArea:true → titleBar 整体避让系统状态栏，
   *   标题文字确定性位于电量/WiFi 图标下方（HDS PaddingOptions 仅支持
   *   start/end，无法手动加 top，必须依赖组件级安全区避让）；
   * - bottomBuilder 仅节点页（Tab0）传入，Ping/设置页彻底不传该键，
   *   物理卸载搜索栏占位（避免 height:0 收起方案残留过渡占位高度）。
   */
  private buildTitleBarOptions(): HdsNavigationTitleBarOptions {
    if (this.currentTab === 0) {
      return {
        avoidLayoutSafeArea: true,
        enableComponentSafeArea: true,
        content: {
          title: { mainTitle: '' },
          stackBuilder: (): void => { this.floatingSearchBar(); }
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
      };
    }
    return {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: {
        title: { mainTitle: this.currentTitle }
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
    };
  }

  // ===== 顶部悬浮搜索栏 =====

  @Builder
  floatingSearchBar() {
    Row() {
      Row() {
        Stack({ alignContent: Alignment.End }) {
          Search({ value: this.searchKeyword, placeholder: '搜索节点 / 地区 / 标签等' })
            .layoutWeight(1)
            .height(42)
            .textFont({ size: 14 })
            .cancelButton({ style: CancelButtonStyle.INVISIBLE })
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_secondary'))
            .backgroundColor(Color.Transparent)
            .onChange((v: string): void => {
              this.searchKeyword = v;
              AppStorage.setOrCreate(AppKeys.SEARCH_KEYWORD, v);
            })

          // 右侧：清除按钮 + 在线/总数计数
          Row({ space: 6 }) {
            if (this.searchKeyword.length > 0) {
              SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
                .fontSize(16)
                .fontColor([$r('app.color.text_tertiary')])
                // 热区扩到 40×40：上下贴满胶囊内高，左侧伸入输入区，右侧止步计数胶囊间隙
                .responseRegion({ x: -16, y: -12, width: 40, height: 40 })
                .onClick((): void => {
                  this.searchKeyword = '';
                  AppStorage.setOrCreate(AppKeys.SEARCH_KEYWORD, '');
                })
            }

            if (this.nodesTotal > 0) {
              Text(`${this.nodesOnline}/${this.nodesTotal}`)
                .fontSize(11)
                .fontColor($r('app.color.text_tertiary'))
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor($r('app.color.search_count_bg'))
                .borderRadius(10)
            }
          }
          .padding({ right: 14 })
        }
        .layoutWeight(1)
      }
      .width('100%')
      .height(46)
      .padding({ left: 16, right: 16, top: 2, bottom: 4 })
      .backgroundColor($r('app.color.search_pill_bg'))
      .borderRadius(23)
      .border({ width: 1, color: $r('app.color.search_pill_border') })
      .shadow({ radius: 10, color: '#0D050505', offsetX: 0, offsetY: 1 })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  // ===== 底部 Tab 项（每项占一个原生页签槽位；严格水平居中对齐，绝对定位圆点避免推偏） =====

  @Builder
  tabBarItem(index: number, title: string, symbol: Resource, showHealthDot: boolean = false) {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(symbol)
          .fontSize(22)
          .fontColor([this.currentTab === index ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.text_secondary')])

        if (showHealthDot) {
          Circle({ width: 7, height: 7 })
            .fill(this.getHealthColor())
            .position({ x: 22, y: 0 })
            .shadow({ radius: 4, color: this.getHealthShadowColor() })
        }
      }
      .width(28)
      .height(24)

      Text(title)
        .fontSize(11)
        .fontColor(this.currentTab === index ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.text_secondary'))
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Normal)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 根布局（HdsNavigation 为页面唯一顶层根容器，全屏穿透） =====

  build() {
    HdsNavigation() {
      // Stack 仅作 bindSheet 宿主（空态「去添加服务端」直接在本页弹添加弹层，
      // 不再进 ServerManagePage 二级页）；不裁剪不影响 HdsTabs 悬浮栏布局
      Stack() {
        HdsTabs({ controller: this.tabsController }) {
        TabContent() {
          if (this.currentTab === 0) {
            Column() {
              NodesPage({
                scroller: this.nodesScroller,
                onAddServer: (): void => {
                  this.addSheetShow = true;
                }
              })
            }
            .width('100%')
            .height('100%')
            .transition(PAGE_TRANSITION)
          }
        }
        .clip(false)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        .tabBar(this.tabBarItem(0, '节点', $r('sys.symbol.square_grid_2x2'), true))

        TabContent() {
          if (this.currentTab === 1) {
            Column() {
              PingPage({
                scroller: this.pingScroller,
                onAddServer: (): void => {
                  this.addSheetShow = true;
                }
              })
            }
            .width('100%')
            .height('100%')
            .transition(PAGE_TRANSITION)
          }
        }
        .clip(false)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        .tabBar(this.tabBarItem(1, 'Ping', $r('sys.symbol.ohos_wifi'), false))

        TabContent() {
          if (this.currentTab === 2) {
            Column() {
              SettingsPane({ pageRef: (p: SettingsPane): void => {
                this.settingsPane = p;
              } })
            }
            .width('100%')
            .height('100%')
            .transition(PAGE_TRANSITION)
          }
        }
        .clip(false)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        .tabBar(this.tabBarItem(2, '设置', $r('sys.symbol.gearshape'), false))
      }
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .barOverlap(true)
      .barPosition(BarPosition.End)
      .barBackgroundColor(Color.Transparent)
      .barBackgroundBlurStyle(BlurStyle.NONE)
      .blurStrategy(BlurStrategy.ENABLE)
      .scrollable(false)
      .animationDuration(0)
      .barFloatingStyle({
        barBottomMargin: (this.navIndicatorHeight > 0 ? this.navIndicatorHeight + 12 : 28),
        // gradientMask 不显式配置，使用官方默认渐变蒙层
        // （浅色 #CCF1F3F5 / 深色 #99000000，高度=页签栏+16vp）：
        // 让内容在悬浮页签下方自然淡出，保证页签可读性，属官方推荐默认用法
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: this.materialLevel
        }
      })
      .onAnimationStart((index: number, targetIndex: number): void => {
        this.switchTab(targetIndex);
      })
      .onChange((index: number): void => {
        this.switchTab(index);
      })
      .backgroundColor(Color.Transparent)
      }
      .width('100%')
      .height('100%')
      .bindSheet($$this.addSheetShow, this.addSheetBuilder(), {
        // 与 ServerManagePage 的添加弹层同款配置：
        // 内容自带标题栏与关闭按钮，dragBar 会形成双重头部
        height: SheetSize.LARGE,
        dragBar: false,
        showClose: false
      })
    }
    .width('100%')
    .height('100%')
    .titleBar(this.buildTitleBarOptions())
    .bindToScrollable([this.getCurrentScroller()])
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .backgroundColor($r('app.color.page_bg'))
  }
}
