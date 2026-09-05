/**
 * MainPage —— 主界面（HDS 沉浸光感架构）
 *
 * HdsNavigation（根容器，标题+搜索框，IMMERSIVE_GRADIENT_BLUR 滚动渐变模糊）
 *   └── HdsTabs（底部悬浮光感 Tab 栏）
 *         ├── Tab1 NodesPage（节点列表）
 *         ├── Tab2 PingPage
 *         └── Tab3 设置面板
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
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AppKeys } from '../common/constants/AppKeys';
import { NodesPage } from './NodesPage';
import { PingPage } from './PingPage';
import { SettingsPane } from './SettingsPane';

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
  /** Tab 内容组件引用：切 Tab 时暂停不可见页的轮询，只保留当前页 */
  private nodesPage: NodesPage | null = null;
  private pingPage: PingPage | null = null;
  /** 设置页引用：onPageShow 时调 refreshAuthState，getCurrentScroller 时调 getScroller */
  private settingsPane: SettingsPane | null = null;

  /**
   * 当前 Tab 对应的 scroller，供 bindToScrollable 动态单向绑定。
   * 三个 Tab 统一使用 List 容器，均参与联动（滚动渐变模糊）。
   * 内容不足时的弹性回弹由 edgeEffect 的 alwaysEnabled:true 保证（API 11+）。
   * 设置页 scroller 由 SettingsPane 内部管理，通过 getScroller() 暴露。
   */
  private getCurrentScroller(): Scroller {
    if (this.currentTab === 0) {
      return this.nodesScroller;
    } else if (this.currentTab === 1) {
      return this.pingScroller;
    }
    return this.settingsPane?.getScroller() ?? this.nodesScroller;
  }

  /** 切换活跃 Tab：恢复滚动偏移 + 只保留当前 Tab 的轮询 */
  private switchTab(index: number): void {
    if (this.currentTab === index) {
      return;
    }
    this.currentTab = index;
    if (index === 0) {
      this.currentTitle = '';
    } else if (index === 1) {
      this.currentTitle = 'Ping 监控';
    } else {
      this.currentTitle = '设置';
    }
    // 暂停不可见页轮询，恢复当前页轮询（设置 Tab 无轮询）
    if (this.nodesPage) {
      index === 0 ? this.nodesPage.resumePolling() : this.nodesPage.pausePolling();
    }
    if (this.pingPage) {
      index === 1 ? this.pingPage.resumePolling() : this.pingPage.pausePolling();
    }
    // 仅当用户滚动过该 Tab（记录偏移>0）才恢复位置；
    // 未滚动过的 Tab 保持列表初始联动状态（bindToScrollable 初始化自带偏移，
    // scrollTo(0) 会抹掉它导致内容顶到玻璃标题栏后面）
    if (this.tabOffsets[index] > 0) {
      const targetScroller = this.getCurrentScroller();
      try {
        targetScroller.scrollTo({
          xOffset: 0,
          yOffset: this.tabOffsets[index]
        });
      } catch (e) {
        // 目标 Tab 尚未懒构建完成时忽略
      }
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
    // 从 AuthPage / ServerManagePage 返回时刷新设置页认证状态
    this.settingsPane?.refreshAuthState();
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
          Search({ value: this.searchKeyword, placeholder: '搜索节点 / IP / 标签' })
            .layoutWeight(1)
            .height(42)
            .textFont({ size: 14 })
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
      .backgroundColor(Color.White)
      .borderRadius(23)
      .shadow({ radius: 10, color: '#0D050505', offsetX: 0, offsetY: 1 })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  // ===== 底部 Tab 项（严格水平居中对齐，使用绝对定位圆点避免推偏） =====

  @Builder
  tabBarItem(index: number, title: string, symbol: Resource, showHealthDot: boolean = false) {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(symbol)
          .fontSize(22)
          .fontColor([this.currentTab === index ? $r('app.color.accent') : $r('app.color.text_secondary')])

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
        .fontColor(this.currentTab === index ? $r('app.color.accent') : $r('app.color.text_secondary'))
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
      HdsTabs({ controller: this.tabsController }) {
        TabContent() {
          NodesPage({ scroller: this.nodesScroller, pageRef: (p: NodesPage): void => {
            this.nodesPage = p;
          } })
        }
        .clip(false)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        .tabBar(this.tabBarItem(0, '节点', $r('sys.symbol.square_grid_2x2'), true))
        .onWillHide((): void => {
          const offset = this.nodesScroller.currentOffset();
          this.tabOffsets[0] = offset.yOffset;
        })

        TabContent() {
          PingPage({ scroller: this.pingScroller, pageRef: (p: PingPage): void => {
            this.pingPage = p;
          } })
        }
        .clip(false)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        .tabBar(this.tabBarItem(1, 'Ping', $r('sys.symbol.ohos_wifi'), false))
        .onWillHide((): void => {
          const offset = this.pingScroller.currentOffset();
          this.tabOffsets[1] = offset.yOffset;
        })

        TabContent() {
          SettingsPane({ pageRef: (p: SettingsPane): void => {
            this.settingsPane = p;
          } })
        }
        .clip(false)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
        .tabBar(this.tabBarItem(2, '设置', $r('sys.symbol.gearshape'), false))
        .onWillHide((): void => {
          const scroller = this.settingsPane?.getScroller();
          if (scroller) {
            const offset = scroller.currentOffset();
            this.tabOffsets[2] = offset.yOffset;
          }
        })
      }
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .barOverlap(true)
      .barPosition(BarPosition.End)
      .barBackgroundColor(Color.Transparent)
      .barBackgroundBlurStyle(BlurStyle.NONE)
      .blurStrategy(BlurStrategy.ENABLE)
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
    .titleBar(this.buildTitleBarOptions())
    .bindToScrollable([this.getCurrentScroller()])
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .backgroundColor($r('app.color.page_bg'))
  }
}
