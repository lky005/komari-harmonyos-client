/**
 * PingDetailPage —— 单节点 × 单 Ping 任务的延迟详情
 *
 * 参数（router）：{ taskId, taskName, uuid, entityName }
 * 数据：
 *   - getPingRecords(uuid, taskId, hours)：hours 是**字符串**（与 queryMetrics 不同！），
 *     records[].value < 0 表示丢包，画图前剔除并计数
 *   - getPingMetricStats：服务端聚合（avg/min/max/p50/p99），字段可空，FormatUtil.ms 兜底
 *
 * 该站 ping_record_preserve_time = 24h，范围只给 1h/6h/24h。
 */

import { router } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { PingRecordItem, PingTaskStats } from '../model/KomariTypes';
import { FormatUtil } from '../common/FormatUtil';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { MpLineChart } from '../view/MpLineChart';

export interface PingDetailParam {
  taskId: number;
  taskName: string;
  uuid: string;
  entityName: string;
}

interface DownsampleResult {
  values: number[];
  timestamps: number[];
}

@Component
struct StatCell {
  label: string = '';
  value: string = '';

  build() {
    Column({ space: 2 }) {
      Text(this.label)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
      Text(this.value)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }
}

@Entry
@Component
struct PingDetailPage {
  @State rangeIdx: number = 0;
  @State values: number[] = [];
  @State timestamps: number[] = [];
  @State stats: PingTaskStats | undefined = undefined;
  @State sampleCount: number = 0;
  @State lossCount: number = 0;
  @State loading: boolean = false;
  @State errorText: string = '';
  private scroller: Scroller = new Scroller();
  private taskId: number = 0;
  private taskName: string = '';
  private uuid: string = '';
  private entityName: string = '';
  private rangeLabels: string[] = ['1小时', '6小时', '24小时'];
  private rangeHours: number[] = [1, 6, 24];

  aboutToAppear(): void {
    // 直连/异常进入时 getParams 可能为空，先判空避免崩溃
    const p = router.getParams() as PingDetailParam | undefined;
    if (!p || !p.uuid || p.uuid.length === 0) {
      this.errorText = '参数缺失';
      return;
    }
    this.taskId = p.taskId;
    this.taskName = p.taskName;
    this.uuid = p.uuid;
    this.entityName = p.entityName;
    this.load();
  }

  private async load(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      const hours: number = this.rangeHours[this.rangeIdx];
      const res = await ServiceRegistry.getApi()
        .getPingRecords(this.uuid, `${this.taskId}`, hours);

      // 按时间升序排一遍，不信任服务端顺序
      const records: PingRecordItem[] = res.records.slice(0);
      records.sort((a: PingRecordItem, b: PingRecordItem): number => {
        return Date.parse(a.time) - Date.parse(b.time);
      });

      // value < 0 是丢包，不是负延迟；画图剔除、计数展示
      const clean: number[] = [];
      const cleanTs: number[] = [];
      let lost: number = 0;
      records.forEach((r: PingRecordItem): void => {
        if (typeof r.value === 'number' && !isNaN(r.value)) {
          if (r.value >= 0) {
            clean.push(r.value);
            cleanTs.push(Date.parse(r.time));
          } else {
            lost++;
          }
        }
      });
      const sampled = this.downsamplePair(clean, cleanTs, 480);
      this.values = sampled.values;
      this.timestamps = sampled.timestamps;
      this.sampleCount = records.length;
      this.lossCount = lost;

      // 服务端统计聚合
      const statsRes = await ServiceRegistry.getApi().getPingMetricStats({
        hours: hours,
        task_ids: [this.taskId],
        max_points: 50
      });
      let picked: PingTaskStats | undefined = undefined;
      statsRes.stats.forEach((s: PingTaskStats): void => {
        if (!picked && s.entity_id === this.uuid && s.task_id === `${this.taskId}`) {
          picked = s;
        }
      });
      this.stats = picked;
    } catch (err) {
      const e = err as Error;
      this.values = [];
      this.timestamps = [];
      this.stats = undefined;
      this.errorText = e?.message ?? '查询失败';
    } finally {
      this.loading = false;
    }
  }

  /** 等距抽稀，数值与时间戳共用同一组索引，保证 Tooltip 时间对齐 */
  private downsamplePair(values: number[], timestamps: number[], max: number): DownsampleResult {
    if (values.length <= max) {
      return { values: values.slice(), timestamps: timestamps.slice() } as DownsampleResult;
    }
    const outV: number[] = [];
    const outT: number[] = [];
    const step: number = values.length / max;
    for (let i = 0; i < max; i++) {
      const idx: number = Math.floor(i * step);
      outV.push(values[idx]);
      outT.push(timestamps[idx]);
    }
    return { values: outV, timestamps: outT } as DownsampleResult;
  }

  private lossPercent(): string {
    if (this.sampleCount === 0) {
      return '-';
    }
    return `${((this.lossCount / this.sampleCount) * 100).toFixed(1)}%`;
  }

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (this.errorText.length > 0) {
            Text(`⚠ ${this.errorText}`)
              .fontSize(12)
              .fontColor($r('app.color.status_warn'))
              .width('100%')
          }
          // 时间范围（卡片容器，与 NodeDetailPage 首元素视觉对齐，掩盖顶部空隙）
          Row({ space: 8 }) {
            ForEach(this.rangeLabels, (label: string, idx: number) => {
              Text(label)
                .fontSize(12)
                .fontColor(this.rangeIdx === idx ? Color.White : $r('app.color.text_secondary'))
                .backgroundColor(this.rangeIdx === idx ? $r('app.color.accent') : $r('app.color.page_bg'))
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .borderRadius(14)
                .onClick((): void => {
                  if (this.rangeIdx !== idx) {
                    this.rangeIdx = idx;
                    this.load();
                  }
                })
            }, (label: string) => label)
            Blank()
            Text(`采样 ${this.sampleCount} · 丢包 ${this.lossCount}（${this.lossPercent()}）`)
              .fontSize(11)
              .fontColor(this.lossCount > 0 ? $r('app.color.status_warn') : $r('app.color.text_tertiary'))
          }
          .width('100%')
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))

          if (this.errorText.length > 0) {
            Text(`⚠ ${this.errorText}`)
              .fontSize(12)
              .fontColor($r('app.color.status_warn'))
              .width('100%')
          }

          // 延迟折线
          Column({ space: 8 }) {
            Text('延迟曲线')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            if (this.loading) {
              Column() {
                LoadingProgress()
                  .width(28)
                  .height(28)
                  .color($r('app.color.accent'))
              }
              .width('100%')
              .height(150)
              .justifyContent(FlexAlign.Center)
            } else {
              MpLineChart({
                values: this.values,
                timestamps: this.timestamps,
                unit: 'ms',
                timeRangeHours: this.rangeHours[this.rangeIdx],
                lineColor: $r('app.color.accent'),
                line1Label: '延迟',
                emptyText: this.errorText.length > 0 ? '查询失败' : '该时间范围内暂无记录',
                chartHeight: 150
              })
              .margin({ top: 28 })
            }
          }
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // 统计卡
          Column({ space: 10 }) {
            Text('统计（服务端聚合）')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Row({ space: 8 }) {
              StatCell({ label: '平均', value: FormatUtil.ms(this.stats?.avg) })
              StatCell({ label: '最新', value: FormatUtil.ms(this.stats?.latest) })
              StatCell({ label: '最小', value: FormatUtil.ms(this.stats?.min) })
              StatCell({ label: '最大', value: FormatUtil.ms(this.stats?.max) })
            }
            .width('100%')
            Row({ space: 8 }) {
              StatCell({ label: 'P50', value: FormatUtil.ms(this.stats?.p50) })
              StatCell({ label: 'P99', value: FormatUtil.ms(this.stats?.p99) })
              StatCell({ label: '丢包率', value: this.stats ? `${this.stats.loss.toFixed(1)}%` : '-' })
              StatCell({ label: '有效样本', value: this.stats ? `${this.stats.valid}` : '-' })
            }
            .width('100%')
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
      .clip(false)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: {
        title: {
          mainTitle: this.taskName.length > 0 ? this.taskName : 'Ping 详情',
          subTitle: this.entityName
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
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .backgroundColor($r('app.color.page_bg'))
  }
}
