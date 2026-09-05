/**
 * RefreshPerfPage —— 刷新与性能设置（二级页，2026-09-06 从 SettingsPane 迁出）
 *
 * 样式与服务端管理/Ping 详情二级页一致：HdsNavigation MINI 标题栏 + 渐变模糊。
 * 配置读写走 NodeDataStore.updateConfig，保存后轮询间隔下次生效。
 */

import { router } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { NodeDataStore, PollConfig } from '../common/NodeDataStore';

/** 分段选项定义 */
interface SegmentOption {
  label: string;
  value: number;
}

const LIST_INTERVAL_OPTIONS: SegmentOption[] = [
  { label: '极速 3s', value: 3000 },
  { label: '均衡 5s', value: 5000 },
  { label: '节能 10s', value: 10000 },
  { label: '极简 30s', value: 30000 }
];

const DETAIL_INTERVAL_OPTIONS: SegmentOption[] = [
  { label: '1s', value: 1000 },
  { label: '2s', value: 2000 },
  { label: '5s', value: 5000 }
];

const CONCURRENT_OPTIONS: SegmentOption[] = [
  { label: '2', value: 2 },
  { label: '3', value: 3 },
  { label: '4', value: 4 },
  { label: '5', value: 5 },
  { label: '6', value: 6 }
];

// Ping 详情记录的缓存有效期；关闭 = 每次进入详情页都全量拉取
const PING_CACHE_TTL_OPTIONS: SegmentOption[] = [
  { label: '关闭', value: 0 },
  { label: '5分钟', value: 5 * 60 * 1000 },
  { label: '15分钟', value: 15 * 60 * 1000 },
  { label: '30分钟', value: 30 * 60 * 1000 }
];

@Entry
@Component
struct RefreshPerfPage {
  @State listIntervalIdx: number = 1;   // 默认均衡 5s
  @State detailIntervalIdx: number = 1; // 默认 2s
  @State concurrentIdx: number = 1;     // 默认 3
  @State pingCacheTtlIdx: number = 1;   // 默认 5 分钟
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const cfg: PollConfig = NodeDataStore.getInstance().getConfig();
    this.listIntervalIdx = this.findIdx(LIST_INTERVAL_OPTIONS, cfg.listInterval, 1);
    this.detailIntervalIdx = this.findIdx(DETAIL_INTERVAL_OPTIONS, cfg.detailInterval, 1);
    this.concurrentIdx = this.findIdx(CONCURRENT_OPTIONS, cfg.maxConcurrent, 1);
    this.pingCacheTtlIdx = this.findIdx(PING_CACHE_TTL_OPTIONS, cfg.pingCacheTtl, 1);
  }

  private findIdx(options: SegmentOption[], value: number, fallback: number): number {
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === value) return i;
    }
    return fallback;
  }

  private onListIntervalChange(idx: number): void {
    this.listIntervalIdx = idx;
    NodeDataStore.getInstance().updateConfig({ listInterval: LIST_INTERVAL_OPTIONS[idx].value });
  }

  private onDetailIntervalChange(idx: number): void {
    this.detailIntervalIdx = idx;
    NodeDataStore.getInstance().updateConfig({ detailInterval: DETAIL_INTERVAL_OPTIONS[idx].value });
  }

  private onConcurrentChange(idx: number): void {
    this.concurrentIdx = idx;
    NodeDataStore.getInstance().updateConfig({ maxConcurrent: CONCURRENT_OPTIONS[idx].value });
  }

  private onPingCacheTtlChange(idx: number): void {
    this.pingCacheTtlIdx = idx;
    NodeDataStore.getInstance().updateConfig({ pingCacheTtl: PING_CACHE_TTL_OPTIONS[idx].value });
  }

  /** 分段选择器一组：@Prop 响应父级选中项变化（@Builder 按值传参不触发刷新） */
  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          Column({ space: 14 }) {
            SegmentGroup({
              title: '列表页刷新',
              options: LIST_INTERVAL_OPTIONS,
              hint: '节点列表的自动轮询间隔',
              selectedIdx: this.listIntervalIdx,
              onSelect: (idx: number): void => {
                this.onListIntervalChange(idx);
              }
            })

            SegmentGroup({
              title: '详情页刷新',
              options: DETAIL_INTERVAL_OPTIONS,
              hint: '节点详情页实时指标的刷新间隔',
              selectedIdx: this.detailIntervalIdx,
              onSelect: (idx: number): void => {
                this.onDetailIntervalChange(idx);
              }
            })

            SegmentGroup({
              title: '最大并发',
              options: CONCURRENT_OPTIONS,
              hint: '同时请求实时指标的节点数，越小越省流量',
              selectedIdx: this.concurrentIdx,
              onSelect: (idx: number): void => {
                this.onConcurrentChange(idx);
              }
            })

            SegmentGroup({
              title: 'Ping 详情缓存',
              options: PING_CACHE_TTL_OPTIONS,
              hint: '有效期内再进详情页直接展示缓存，过期后先展示缓存并后台刷新',
              selectedIdx: this.pingCacheTtlIdx,
              onSelect: (idx: number): void => {
                this.onPingCacheTtlChange(idx);
              }
            })
          }
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')
        }
        .padding({ left: 16, right: 16, bottom: 20 })
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
        title: { mainTitle: '刷新与性能' },
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

/** 一组分段选择器；@Prop 选中项变化即时刷新（@Builder 按值传参不会触发 UI 刷新） */
@Component
struct SegmentGroup {
  title: string = '';
  options: SegmentOption[] = [];
  hint: string = '';
  @Prop selectedIdx: number = 0;
  onSelect: (idx: number) => void = (_idx: number): void => {};

  build() {
    Column({ space: 6 }) {
      Text(this.title)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Row({ space: 6 }) {
        ForEach(this.options, (opt: SegmentOption, idx: number) => {
          Text(opt.label)
            .fontSize(12)
            .fontColor(this.selectedIdx === idx ? Color.White : $r('app.color.text_secondary'))
            .backgroundColor(this.selectedIdx === idx ? $r('app.color.accent') : $r('app.color.page_bg'))
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(8)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .onClick((): void => {
              this.onSelect(idx);
            })
        }, (opt: SegmentOption) => opt.label + '_' + this.selectedIdx)
      }
      .width('100%')
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
  }
}
