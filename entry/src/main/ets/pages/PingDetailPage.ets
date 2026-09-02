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
import { PingRecordItem, PingTaskStats } from '../model/KomariTypes';
import { FormatUtil } from '../common/FormatUtil';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { LineChart } from '../view/LineChart';

export interface PingDetailParam {
  taskId: number;
  taskName: string;
  uuid: string;
  entityName: string;
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
  @State stats: PingTaskStats | undefined = undefined;
  @State sampleCount: number = 0;
  @State lossCount: number = 0;
  @State loading: boolean = false;
  @State errorText: string = '';
  private taskId: number = 0;
  private taskName: string = '';
  private uuid: string = '';
  private entityName: string = '';
  private rangeLabels: string[] = ['1小时', '6小时', '24小时'];
  private rangeHours: number[] = [1, 6, 24];

  aboutToAppear(): void {
    const p = router.getParams() as PingDetailParam;
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
      let lost: number = 0;
      records.forEach((r: PingRecordItem): void => {
        if (typeof r.value === 'number' && !isNaN(r.value)) {
          if (r.value >= 0) {
            clean.push(r.value);
          } else {
            lost++;
          }
        }
      });
      this.values = this.downsample(clean, 480);
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
      this.stats = undefined;
      this.errorText = e?.message ?? '查询失败';
    } finally {
      this.loading = false;
    }
  }

  /** 简单等距抽稀，24h@60s 有 1440 点，控制 Path 指令串规模 */
  private downsample(input: number[], max: number): number[] {
    if (input.length <= max) {
      return input;
    }
    const out: number[] = [];
    const step: number = input.length / max;
    for (let i = 0; i < max; i++) {
      out.push(input[Math.floor(i * step)]);
    }
    return out;
  }

  private lossPercent(): string {
    if (this.sampleCount === 0) {
      return '-';
    }
    return `${((this.lossCount / this.sampleCount) * 100).toFixed(1)}%`;
  }

  private goBack(): void {
    router.back();
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('←')
          .fontSize(22)
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => {
            this.goBack();
          })
          .padding({ right: 8 })
        Column({ space: 2 }) {
          Text(this.taskName.length > 0 ? this.taskName : 'Ping 详情')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.entityName)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          // 时间范围
          Row({ space: 8 }) {
            ForEach(this.rangeLabels, (label: string, idx: number) => {
              Text(label)
                .fontSize(12)
                .fontColor(this.rangeIdx === idx ? Color.White : $r('app.color.text_secondary'))
                .backgroundColor(this.rangeIdx === idx ? $r('app.color.accent') : $r('app.color.card_bg'))
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
              LineChart({
                values: this.values,
                lineColor: $r('app.color.accent'),
                emptyText: this.errorText.length > 0 ? '查询失败' : '该时间范围内暂无记录'
              })
            }
          }
          .padding(14)
          .borderRadius(12)
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
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')
        }
        .padding({ left: 16, right: 16, bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
