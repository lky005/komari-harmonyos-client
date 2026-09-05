/**
 * MpChartDemoPage —— @ohos/mpchart 沙箱隔离测试页（2026-09-04）
 *
 * 职责：在独立页面中挂载 MpLineChart（mpchart 包装组件），注入与 ChartDemoPage 完全相同的
 *       5 组极端模拟数据，用于 A/B 对比验证 mpchart 版本的表现。
 * 与业务页面零耦合：不引用 NodeDetailPage 任何状态，仅依赖 view/MpLineChart。
 *
 * 验收场景（与 ChartDemoPage 一致，便于对比）：
 *  1. 典型波峰 —— Y 轴最大刻度自动上浮，波峰不刺破画布天花板
 *  2. 短数据(N=10) —— 折线从最左端平铺至最右端
 *  3. 绝对平线(全5.0) —— 除零保护，Y 轴刻度规整不崩盘
 *  4. 全零数据(全0.0) —— Y 轴底线锁死为 0，无负数刻度
 *  5. 极端单点(N=1) / 空数组 —— 空态提示文本与单点容错
 *
 * 与 ChartDemoPage 的差异：
 *  - 使用 MpLineChart（基于 @ohos/mpchart）而非手写 LineChart
 *  - 高度 150vp（mpchart 内部 Canvas 需要足够高度渲染 Y 轴标签）
 *  - 线宽 1vp（细折线）
 */

import { router } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { MpLineChart } from '../view/MpLineChart';

interface SceneDef {
  id: number;
  label: string;
  values: number[];
}

@Entry
@Component
struct MpChartDemoPage {
  @State currentScene: number = 0;
  @State scene5Empty: boolean = false;

  private readonly scroller: Scroller = new Scroller();
  private readonly EMPTY_ARRAY: number[] = [];
  private readonly scenes: SceneDef[] = [
    { id: 0, label: '波峰破顶', values: [3.0, 3.2, 9.9, 3.5, 3.1] },
    { id: 1, label: '短数据N=10', values: [1.2, 2.5, 1.8, 3.1, 2.7, 4.0, 3.5, 2.9, 3.8, 4.5] },
    { id: 2, label: '绝对平线', values: [5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0] },
    { id: 3, label: '全零数据', values: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0] },
    { id: 4, label: '单点/空数组', values: [7.5] },
  ];

  // ===== 数据获取 =====
  private activeValues(): number[] {
    if (this.currentScene === 4) {
      return this.scene5Empty ? this.EMPTY_ARRAY : this.scenes[4].values;
    }
    return this.scenes[this.currentScene].values;
  }

  private activeTimestamps(): number[] {
    const n: number = this.activeValues().length;
    const now: number = Date.now();
    const step: number = 5 * 60 * 1000;
    const arr: number[] = [];
    for (let i: number = 0; i < n; i++) {
      arr.push(now - (n - 1 - i) * step);
    }
    return arr;
  }

  private dataCount(): number {
    return this.activeValues().length;
  }

  private dataMin(): number {
    const v: number[] = this.activeValues();
    if (v.length === 0) return 0;
    let m: number = Infinity;
    for (const x of v) {
      if (x < m) m = x;
    }
    return m;
  }

  private dataMax(): number {
    const v: number[] = this.activeValues();
    if (v.length === 0) return 0;
    let m: number = -Infinity;
    for (const x of v) {
      if (x > m) m = x;
    }
    return m;
  }

  private dataAvg(): number {
    const v: number[] = this.activeValues();
    if (v.length === 0) return 0;
    let s: number = 0;
    for (const x of v) {
      s += x;
    }
    return s / v.length;
  }

  private valuesText(): string {
    const v: number[] = this.activeValues();
    return v.length > 0 ? `[${v.join(', ')}]` : '[] (空数组)';
  }

  private sceneHint(): string {
    switch (this.currentScene) {
      case 0:
        return '波峰 9.9：mpchart Y 轴应自动上浮，波峰顶点不得触及画布顶部。对比手写版是否一致。';
      case 1:
        return 'N=10：折线应从最左端平铺至最右端，mpchart 默认有左右 padding，观察是否与手写版一致。';
      case 2:
        return '全 5.0 平线：mpchart 内部除零保护应生效，Y 轴刻度规整，折线呈水平直线。';
      case 3:
        return '全 0.0：mpchart Y 轴底线应锁死为 0，不得出现负数刻度。';
      case 4:
        return this.scene5Empty
          ? '空数组：应显示空态提示文本，mpchart 不绘制任何图形。'
          : '单点 N=1：mpchart 单点应正常渲染，观察是否与手写版居中一致。';
      default:
        return '';
    }
  }

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          // ===== 场景切换按钮组 =====
          Text('测试场景')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.scenes, (scene: SceneDef, idx: number) => {
              Text(scene.label)
                .fontSize(13)
                .fontColor(this.currentScene === idx ? Color.White : $r('app.color.text_primary'))
                .backgroundColor(this.currentScene === idx ? $r('app.color.accent') : $r('app.color.card_bg'))
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .borderRadius(16)
                .margin({ right: 8, bottom: 8 })
                .onClick((): void => {
                  this.currentScene = idx;
                })
            }, (scene: SceneDef) => `mp-scene-${scene.id}`)
          }
          .width('100%')

          // ===== 场景5 子切换 =====
          if (this.currentScene === 4) {
            Row({ space: 8 }) {
              Text('单点 N=1')
                .fontSize(12)
                .fontColor(!this.scene5Empty ? Color.White : $r('app.color.text_primary'))
                .backgroundColor(!this.scene5Empty ? $r('app.color.accent') : $r('app.color.card_bg'))
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .borderRadius(14)
                .onClick((): void => {
                  this.scene5Empty = false;
                })
              Text('空数组 []')
                .fontSize(12)
                .fontColor(this.scene5Empty ? Color.White : $r('app.color.text_primary'))
                .backgroundColor(this.scene5Empty ? $r('app.color.accent') : $r('app.color.card_bg'))
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .borderRadius(14)
                .onClick((): void => {
                  this.scene5Empty = true;
                })
            }
            .width('100%')
          }

          // ===== 数据摘要 =====
          Column({ space: 8 }) {
            Row() {
              Text(`点数: ${this.dataCount()}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
              Text(`最小: ${this.dataMin().toFixed(2)}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
              Text(`最大: ${this.dataMax().toFixed(2)}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
              Text(`平均: ${this.dataAvg().toFixed(2)}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
            }
            .width('100%')

            Text(`数值: ${this.valuesText()}`)
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== mpchart 折线图 =====
          Column({ space: 8 }) {
            Text('MpLineChart（mpchart · 高度 150vp · 线宽 1vp）')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')

            MpLineChart({
              values: this.activeValues(),
              timestamps: this.activeTimestamps(),
              unit: 'ms',
              timeRangeHours: 1,
              chartHeight: 150,
              lineWidthVp: 1,
              emptyText: '空态：暂无数据（场景5 空数组）'
            })
          }
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 验收要点 =====
          Column({ space: 6 }) {
            Text('验收要点')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Text(this.sceneHint())
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')
        }
        .padding({ left: 16, right: 16, bottom: 20 })
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .clip(false)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: {
        title: {
          mainTitle: 'MpChart 沙箱测试',
          subTitle: 'Debug · @ohos/mpchart 极端数据验收'
        },
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
        },
        originalStyle: {
          backgroundStyle: { backgroundColor: Color.Transparent }
        },
        scrollEffectStyle: {
          backgroundStyle: { backgroundColor: Color.Transparent }
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .backgroundColor($r('app.color.page_bg'))
  }
}
