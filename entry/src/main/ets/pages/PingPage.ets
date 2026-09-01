/**
 * PingPage —— Ping 任务列表（MainPage Tab2）
 *
 * 数据：getPublicPingTasks（任务）+ getPingMetricStats（近 1h 统计，一次拉全部任务）
 * 分组：stats[].task_id 是字符串，与任务 id 用 String() 对齐。
 * 判空：min/max/avg/latest 是 *float64 + omitempty，可能缺失 → fmtMs 里兜底。
 * loss 是 0~100 的百分比（源码 publicPingLossRate 已确认），不是次数。
 */

import { PingTask, PingTaskStats } from '../model/KomariTypes';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { KomariApi, PingStatsParams } from '../service/KomariApi';

interface PingEntry {
  task: PingTask;
  stats: PingTaskStats[];
}

@Component
export struct PingPage {
  @State entries: PingEntry[] = [];
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State lastRefresh: string = '';
  private timerId: number = -1;
  private refreshing: boolean = false;

  aboutToAppear(): void {
    this.startPolling();
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private startPolling(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
    }
    this.refreshOnce();
    this.timerId = setInterval((): void => {
      this.refreshOnce();
    }, 10000);
  }

  private async refreshOnce(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    if (!ServiceRegistry.getActiveConfig()) {
      this.errorMsg = '服务端未连接';
      return;
    }
    const api: KomariApi = ServiceRegistry.getApi();
    this.refreshing = true;
    try {
      const tasks: PingTask[] = await api.getPublicPingTasks();
      const ids: number[] = tasks.map((t: PingTask): number => t.id);

      const statsAll: PingTaskStats[] = [];
      if (ids.length > 0) {
        // 任务多时分批，避免单请求参数过长；正常场景一批即可
        const params: PingStatsParams = { hours: 1, task_ids: ids, max_points: 50 };
        const res = await api.getPingMetricStats(params);
        res.stats.forEach((s: PingTaskStats): void => {
          statsAll.push(s);
        });
      }

      const next: PingEntry[] = [];
      tasks.forEach((t: PingTask): void => {
        const own: PingTaskStats[] = statsAll.filter(
          (s: PingTaskStats): boolean => s.task_id === `${t.id}`
        );
        next.push({ task: t, stats: own });
      });
      this.entries = next;
      this.errorMsg = '';
      const d: Date = new Date();
      const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
      this.lastRefresh = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
    } catch (err) {
      const e = err as Error;
      this.errorMsg = e?.message ?? '刷新失败';
    } finally {
      this.refreshing = false;
    }
  }

  /** 统计值兜底：服务端可能缺省 */
  private fmtMs(v: number | undefined): string {
    if (v === undefined || isNaN(v)) {
      return '-';
    }
    return `${v.toFixed(1)} ms`;
  }

  private entityLabel(s: PingTaskStats): string {
    if (s.name && s.name.length > 0) {
      return s.name;
    }
    return s.entity_id.length > 8 ? s.entity_id.substring(0, 8) : s.entity_id;
  }

  private typeLabel(t: PingTask): string {
    const ty: string = t.type && t.type.length > 0 ? t.type.toUpperCase() : 'ICMP';
    return ty;
  }

  build() {
    Column() {
      Row() {
        Text('Ping 监控')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (this.lastRefresh.length > 0) {
          Text(`更新于 ${this.lastRefresh}`)
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12 })

      if (this.errorMsg.length > 0) {
        Text(`⚠ ${this.errorMsg}`)
          .fontSize(12)
          .fontColor($r('app.color.status_warn'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 6 })
      }

      if (this.entries.length === 0 && !this.loading) {
        Column({ space: 8 }) {
          Text(this.errorMsg.length > 0 ? '加载失败' : '暂无 Ping 任务')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.entries, (entry: PingEntry) => {
            ListItem() {
              Column({ space: 8 }) {
                Row({ space: 8 }) {
                  Text(entry.task.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text(this.typeLabel(entry.task))
                    .fontSize(11)
                    .fontColor($r('app.color.accent'))
                    .backgroundColor($r('app.color.chip_bg'))
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .borderRadius(10)
                }
                .width('100%')

                if (entry.stats.length === 0) {
                  Text('暂无统计数据')
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .width('100%')
                } else {
                  ForEach(entry.stats, (s: PingTaskStats) => {
                    Row({ space: 8 }) {
                      Text(this.entityLabel(s))
                        .fontSize(13)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .constraintSize({ maxWidth: '34%' })
                      Text(`平均 ${this.fmtMs(s.avg)}`)
                        .fontSize(12)
                        .fontColor($r('app.color.text_secondary'))
                      Blank()
                      Text(`丢包 ${s.loss.toFixed(1)}%`)
                        .fontSize(12)
                        .fontColor(s.loss > 5 ? $r('app.color.status_bad') : $r('app.color.status_ok'))
                    }
                    .width('100%')
                  }, (s: PingTaskStats) => `${s.task_id}_${s.entity_id}`)
                }
              }
              .padding(14)
              .borderRadius(12)
              .backgroundColor($r('app.color.card_bg'))
              .width('100%')
            }
          }, (entry: PingEntry) => `${entry.task.id}_${entry.stats.length}`)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 12 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
