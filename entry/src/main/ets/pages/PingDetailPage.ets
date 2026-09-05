/**
 * PingDetailPage —— 单节点 × 单 Ping 任务的延迟详情
 *
 * 参数（router）：{ taskId, taskName, uuid, entityName, initialStats? }
 *   initialStats 是列表页已拉到的 1h 统计，用于统计卡首帧直显，load() 完成后被权威数据覆盖
 * 数据：
 *   - getPingRecords(uuid, taskId, hours)：hours 是**字符串**（与 queryMetrics 不同！），
 *     records[].value < 0 表示丢包，画图前剔除并计数
 *   - getPingMetricStats：服务端聚合（avg/min/max/p50/p99），字段可空，FormatUtil.ms 兜底；
 *     与 records 并行请求，失败时单独走本地兜底，不拖垮整页
 *
 * 加载策略（stale-while-revalidate）：
 *   记录按 serverId|uuid|taskId|hours 缓存在 PingRecordStore（进程内），
 *   有效期 = 设置页「刷新与性能 → Ping 详情缓存」（PollConfig.pingCacheTtl，0=关闭）：
 *   - 有效期内：直接渲染缓存，不发网络
 *   - 过期/无缓存：有缓存先渲染缓存再后台刷新；无缓存才显示加载转圈
 *   - 后台刷新失败保留已渲染的缓存图，仅在顶部提示
 *
 * 该站 ping_record_preserve_time = 24h，范围只给 1h/6h/24h。
 */

import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { PingMetricStatsResponse, PingRecordItem, PingRecordsResponse, PingTaskStats } from '../model/KomariTypes';
import { FormatUtil } from '../common/FormatUtil';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';
import { PingCacheHit, PingRecordStore } from '../common/PingRecordStore';
import { MpLineChart } from '../view/MpLineChart';

export interface PingDetailParam {
  taskId: number;
  taskName: string;
  uuid: string;
  entityName: string;
  /** 列表页已拉到的 1h 统计，统计卡首帧直显用，可缺省 */
  initialStats?: PingTaskStats;
}

interface DownsampleResult {
  values: number[];
  timestamps: number[];
}

/** 记录清洗结果：clean 为剔除丢包后的延迟序列，lost 为丢包数 */
interface CleanStats {
  clean: number[];
  lost: number;
}

@Component
struct StatCell {
  // 必须用 @Prop：普通成员只在首帧创建时赋值，父组件数据到位后不会同步，
  // 统计卡会永远停留在加载态的 '-'（本次统计空白的真正根因）
  @Prop label: string = '';
  @Prop value: string = '';

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
  @State statsLocal: boolean = false;
  @State sampleCount: number = 0;
  @State lossCount: number = 0;
  @State loading: boolean = false;
  @State errorText: string = '';
  private scroller: Scroller = new Scroller();
  private taskId: number = 0;
  private taskName: string = '';
  private uuid: string = '';
  private entityName: string = '';
  /** 竞态防护：每次 load 递增，应用结果前校验，迟到的旧响应直接丢弃 */
  private loadSeq: number = 0;
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
    // 列表页带来的 1h 统计先上屏（默认范围就是 1h，口径一致）
    const pre: PingTaskStats | undefined = p.initialStats;
    if (pre && typeof pre.avg === 'number' && typeof pre.loss === 'number') {
      this.stats = pre;
      this.statsLocal = false;
    }
    this.load();
  }

  private async load(): Promise<void> {
    const seq: number = ++this.loadSeq;
    const hours: number = this.rangeHours[this.rangeIdx];
    const ttl: number = NodeDataStore.getInstance().getConfig().pingCacheTtl;
    const cache: PingRecordStore = PingRecordStore.getInstance();
    const hit: PingCacheHit | undefined = ttl > 0 ? cache.lookup(this.uuid, this.taskId, hours) : undefined;

    // stale-while-revalidate：有缓存先渲染缓存（本地口径统计），不顶加载转圈
    if (hit) {
      const pre = this.applyRecords(hit.records, seq);
      if (pre !== undefined && pre.clean.length > 0) {
        this.stats = this.computeLocalStats(pre.clean, pre.lost);
        this.statsLocal = true;
      }
    }

    if (hit && hit.ageMs < ttl) {
      this.errorText = '';
      hilog.info(0x0001, 'PingDetail', `cache FRESH ageMs=${hit.ageMs} ttl=${ttl}`);
      return;
    }

    // 有缓存可看时不显示转圈，走后台静默刷新
    this.loading = !hit;
    try {
      // 统计聚合先发出去，与 records 并行（原先串行等 records 返回才发，白等一个 RTT）
      const statsP: Promise<PingMetricStatsResponse | undefined> = this.statsPromise(hours);
      const res: PingRecordsResponse = await ServiceRegistry.getApi()
        .getPingRecords(this.uuid, `${this.taskId}`, hours);
      if (seq !== this.loadSeq) {
        return;
      }
      cache.put(this.uuid, this.taskId, hours, res.records);
      const parsed: CleanStats | undefined = this.applyRecords(res.records, seq);
      hilog.info(0x0001, 'PingDetail', `cache ${hit ? `STALE ageMs=${hit.ageMs}` : 'MISS'} records=${res.records.length}`);

      // 服务端统计聚合；实测（komari.example.com @ 1.4.3，2026-09-05）该接口对任意参数
      // 均返回空 stats，取不到时用本页已拉取的原始记录本地兜底计算，口径一致
      let statsRes: PingMetricStatsResponse | undefined = await statsP;
      if (seq !== this.loadSeq) {
        return;
      }
      let picked: PingTaskStats | undefined = undefined;
      if (statsRes !== undefined) {
        statsRes.stats.forEach((s: PingTaskStats): void => {
          // 实测服务端可能返回只有 id 骨架、数值字段被 omitempty 省略的条目，视为无效
          if (!picked && s.entity_id === this.uuid && s.task_id === `${this.taskId}`
            && typeof s.avg === 'number' && typeof s.loss === 'number') {
            picked = s;
          }
        });
      }
      if (!picked && parsed !== undefined && parsed.clean.length > 0) {
        picked = this.computeLocalStats(parsed.clean, parsed.lost);
        this.statsLocal = true;
      } else if (picked !== undefined) {
        this.statsLocal = false;
      }
      this.stats = picked;
      hilog.info(0x0001, 'PingDetail', `serverStats=${statsRes !== undefined ? statsRes.stats.length : -1} picked=${picked !== undefined} statsLocal=${this.statsLocal}`);
    } catch (err) {
      if (seq !== this.loadSeq) {
        return;
      }
      const e = err as Error;
      if (hit) {
        // 后台刷新失败：保留已渲染的缓存图，只提示
        this.errorText = `刷新失败，当前为缓存数据：${e?.message ?? '网络异常'}`;
      } else {
        this.values = [];
        this.timestamps = [];
        this.stats = undefined;
        this.statsLocal = false;
        this.errorText = e?.message ?? '查询失败';
      }
    } finally {
      if (seq === this.loadSeq) {
        this.loading = false;
      }
    }
  }

  /** 统计聚合请求：失败时返回 undefined 走本地兜底，不拖垮整页（records 已成功就不该白屏） */
  private statsPromise(hours: number): Promise<PingMetricStatsResponse | undefined> {
    return ServiceRegistry.getApi()
      .getPingMetricStats({ hours: hours, task_ids: [this.taskId], max_points: 50 })
      .then((r: PingMetricStatsResponse): PingMetricStatsResponse => r)
      .catch((_e: Error): PingMetricStatsResponse | undefined => undefined);
  }

  /**
   * 记录清洗并上屏：升序、剔丢包、等距抽稀。
   * 返回清洗结果供本地统计兜底；seq 过期（期间用户切换了范围）返回 undefined 且不动 UI。
   */
  private applyRecords(records: PingRecordItem[], seq: number): CleanStats | undefined {
    if (seq !== this.loadSeq) {
      return undefined;
    }
    // 按时间升序排一遍，不信任服务端顺序
    const sorted: PingRecordItem[] = records.slice(0);
    sorted.sort((a: PingRecordItem, b: PingRecordItem): number => {
      return Date.parse(a.time) - Date.parse(b.time);
    });

    // value < 0 是丢包，不是负延迟；画图剔除、计数展示
    const clean: number[] = [];
    const cleanTs: number[] = [];
    let lost: number = 0;
    sorted.forEach((r: PingRecordItem): void => {
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
    this.sampleCount = sorted.length;
    this.lossCount = lost;
    hilog.info(0x0001, 'PingDetail', `records=${sorted.length} clean=${clean.length} lost=${lost}`);
    const result: CleanStats = { clean: clean, lost: lost };
    return result;
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

  /** 服务端统计缺失时的本地兜底：对已拉取的原始记录做同口径聚合（loss 为 0~100 百分比） */
  private computeLocalStats(values: number[], lost: number): PingTaskStats {
    const sorted: number[] = values.slice().sort((a: number, b: number): number => a - b);
    const n: number = sorted.length;
    const sum: number = sorted.reduce((acc: number, v: number): number => acc + v, 0);
    const avg: number = sum / n;
    const variance: number =
      sorted.reduce((acc: number, v: number): number => acc + (v - avg) * (v - avg), 0) / n;
    const pct = (p: number): number => {
      const idx: number = Math.min(n - 1, Math.max(0, Math.ceil(p / 100 * n) - 1));
      return sorted[idx];
    };
    const p50: number = pct(50);
    const p99: number = pct(99);
    const total: number = n + lost;
    const stat: PingTaskStats = {
      entity_id: this.uuid,
      task_id: `${this.taskId}`,
      name: this.taskName,
      type: '',
      interval: 0,
      total: total,
      valid: n,
      loss: total > 0 ? (lost / total) * 100 : 0,
      loss_approximate: false,
      min: sorted[0],
      max: sorted[n - 1],
      avg: avg,
      latest: values[values.length - 1],
      p50: p50,
      p99: p99,
      stddev: Math.sqrt(variance),
      p99_p50_ratio: p50 > 0 ? p99 / p50 : 0
    };
    return stat;
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
          // 时间范围（卡片容器，与 NodeDetailPage 首元素视觉对齐，掩盖顶部空隙）；
          // 采样/丢包单独一行，避免与范围胶囊挤同一行时溢出卡片
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              ForEach(this.rangeLabels, (label: string, idx: number) => {
                Text(label)
                  .fontSize(12)
                  .fontColor(this.rangeIdx === idx ? Color.White : $r('app.color.text_secondary'))
                  .backgroundColor(this.rangeIdx === idx ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.page_bg'))
                  .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                  .borderRadius(14)
                  .onClick((): void => {
                    if (this.rangeIdx !== idx) {
                      this.rangeIdx = idx;
                      this.load();
                    }
                  })
              }, (label: string) => label)
            }
            .width('100%')

            Text(`采样 ${this.sampleCount} · 丢包 ${this.lossCount}（${this.lossPercent()}）`)
              .fontSize(11)
              .fontColor(this.lossCount > 0 ? $r('app.color.status_warn') : $r('app.color.text_tertiary'))
              .width('100%')
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
                  .color($r('sys.color.ohos_id_color_emphasize'))
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
                lineColor: $r('sys.color.ohos_id_color_emphasize'),
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
            Text(this.statsLocal ? '统计（本地计算）' : '统计（服务端聚合）')
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
              StatCell({ label: '丢包率', value: this.stats ? `${Number(this.stats.loss ?? 0).toFixed(1)}%` : '-' })
              StatCell({ label: '有效样本', value: this.stats ? `${this.stats.valid ?? 0}` : '-' })
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
