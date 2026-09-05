/**
 * PingPage —— Ping 任务列表（MainPage Tab2）
 *
 * 数据：getPublicPingTasks（任务）+ getPingMetricStats（近 1h 统计，一次拉全部任务）
 * 分组：stats[].task_id 是字符串，与任务 id 用 String() 对齐。
 * 判空：min/max/avg/latest 是 *float64 + omitempty，可能缺失 → fmtMs 里兜底。
 * loss 是 0~100 的百分比（源码 publicPingLossRate 已确认），不是次数。
 */

import { PingTask, PingTaskStats, KomariClient } from '../model/KomariTypes';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';
import { AppKeys } from '../common/constants/AppKeys';
import { KomariApi, PingStatsParams } from '../service/KomariApi';
import { router } from '@kit.ArkUI';
import { FormatUtil } from '../common/FormatUtil';
import { PingDetailParam } from './PingDetailPage';

interface PingEntry {
  task: PingTask;
  stats: PingTaskStats[];
}

interface NodePingItem {
  task: PingTask;
  stats: PingTaskStats;
}

interface NodePingEntry {
  uuid: string;
  nodeName: string;
  items: NodePingItem[];
}

@Component
export struct PingPage {
  @State entries: PingEntry[] = [];
  @State nodeEntries: NodePingEntry[] = [];
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State lastRefresh: string = '';
  /** 多服务端管理切换后 bump，本组件收到变化即重置轮询 */
  @StorageProp(AppKeys.SERVER_SEQ) @Watch('onServerChanged') serverSeq: number = 0;
  private timerId: number = -1;
  private refreshing: boolean = false;
  /** 由 MainPage 传入，供 HdsNavigation.bindToScrollable 联动滚动渐变模糊 */
  scroller: Scroller = new Scroller();
  /** MainPage 借此拿到本组件引用，用于切 Tab 时暂停/恢复轮询 */
  pageRef: (p: PingPage) => void = (p: PingPage): void => {};

  /** 轮询由 MainPage 切 Tab 时控制：仅可见 Tab 保持轮询 */
  private paused: boolean = false;

  pausePolling(): void {
    this.paused = true;
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  resumePolling(): void {
    if (!this.paused) {
      return;
    }
    this.paused = false;
    this.startPolling();
  }

  aboutToAppear(): void {
    this.pageRef(this);
    this.startPolling();
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private onServerChanged(): void {
    this.entries = [];
    this.nodeEntries = [];
    this.errorMsg = '';
    this.lastRefresh = '';
    this.loading = true;
    this.startPolling();
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
        // stats 接口一次返回全部任务，无需分批；如未来任务量极大再按 id 分片
        const params: PingStatsParams = { hours: 1, task_ids: ids, max_points: 50 };
        const res = await api.getPingMetricStats(params);
        res.stats.forEach((s: PingTaskStats): void => {
          statsAll.push(s);
        });
      }

      // 原始按任务分组（保留备用）
      const next: PingEntry[] = [];
      tasks.forEach((t: PingTask): void => {
        const own: PingTaskStats[] = statsAll.filter(
          (s: PingTaskStats): boolean => s.task_id === `${t.id}`
        );
        next.push({ task: t, stats: own });
      });
      this.entries = next;

      // 获取节点列表，用于排序和名称映射（从全局缓存读取，避免重复请求）
      const store = NodeDataStore.getInstance();
      await store.fetchNodeInfo();
      const nodes: KomariClient[] = store.getAllNodeInfo();

      // 按 entity_id 分组
      const byEntity: Map<string, NodePingItem[]> = new Map();
      statsAll.forEach((s: PingTaskStats): void => {
        const task: PingTask | undefined = tasks.find(
          (t: PingTask): boolean => `${t.id}` === s.task_id
        );
        if (!task) {
          return;
        }
        const list: NodePingItem[] | undefined = byEntity.get(s.entity_id);
        if (list) {
          list.push({ task, stats: s });
        } else {
          byEntity.set(s.entity_id, [{ task, stats: s }]);
        }
      });

      // 按主页节点顺序排序
      const nodeOrder: Map<string, number> = new Map();
      nodes.forEach((n: KomariClient, i: number): void => {
        nodeOrder.set(n.uuid, i);
      });
      const nodeNameMap: Map<string, string> = new Map();
      nodes.forEach((n: KomariClient): void => {
        nodeNameMap.set(n.uuid, n.name);
      });

      const nodeNext: NodePingEntry[] = [];
      byEntity.forEach((items: NodePingItem[], uuid: string): void => {
        const name: string = nodeNameMap.get(uuid)
          || (items[0].stats.name && items[0].stats.name.length > 0 ? items[0].stats.name : uuid.substring(0, 8));
        nodeNext.push({ uuid, nodeName: name, items });
      });

      // 排序：节点列表中存在的按顺序，不存在的排最后
      nodeNext.sort((a: NodePingEntry, b: NodePingEntry): number => {
        const ai: number = nodeOrder.has(a.uuid) ? nodeOrder.get(a.uuid)! : 99999;
        const bi: number = nodeOrder.has(b.uuid) ? nodeOrder.get(b.uuid)! : 99999;
        if (ai !== bi) {
          return ai - bi;
        }
        return a.nodeName.localeCompare(b.nodeName);
      });

      this.nodeEntries = nodeNext;
      this.errorMsg = '';
      this.loading = false;
      this.lastRefresh = FormatUtil.clock(new Date().toISOString());
    } catch (err) {
      const e = err as Error;
      this.errorMsg = e?.message ?? '刷新失败';
    } finally {
      this.refreshing = false;
    }
  }

  /** 统计值兜底：服务端可能缺省 */
  private fmtMs(v: number | undefined): string {
    return FormatUtil.ms(v);
  }

  private entityLabel(s: PingTaskStats): string {
    if (s.name && s.name.length > 0) {
      return s.name;
    }
    return s.entity_id.length > 8 ? s.entity_id.substring(0, 8) : s.entity_id;
  }

  private openDetail(entry: PingEntry, s: PingTaskStats): void {
    const param: PingDetailParam = {
      taskId: entry.task.id,
      taskName: entry.task.name,
      uuid: s.entity_id,
      entityName: this.entityLabel(s)
    };
    router.pushUrl({ url: 'pages/PingDetailPage', params: param });
  }

  private openDetailByItem(item: NodePingItem): void {
    const name: string = item.stats.name && item.stats.name.length > 0
      ? item.stats.name
      : item.stats.entity_id.substring(0, 8);
    const param: PingDetailParam = {
      taskId: item.task.id,
      taskName: item.task.name,
      uuid: item.stats.entity_id,
      entityName: name
    };
    router.pushUrl({ url: 'pages/PingDetailPage', params: param });
  }

  private typeLabel(t: PingTask): string {
    const ty: string = t.type && t.type.length > 0 ? t.type.toUpperCase() : 'ICMP';
    return ty;
  }

  build() {
    // List 铺满整个内容区，Header 收进 List 内部，使其能随卡片滚到标题栏后
    List({ scroller: this.scroller, space: 10 }) {
      // ===== Header：错误提示（内容自动排在标题栏下方，滚动时穿透渐变模糊） =====
      ListItem() {
        Column({ space: 8 }) {
          // 错误提示
          if (this.errorMsg.length > 0) {
            Text(`⚠ ${this.errorMsg}`)
              .fontSize(12)
              .fontColor($r('app.color.status_warn'))
              .width('100%')
          }
        }
        .width('100%')
      }

      // ===== 空状态 / 加载中 =====
      if (this.nodeEntries.length === 0) {
        if (this.loading || this.lastRefresh.length === 0) {
          // 首次拉取中，不闪"暂无 Ping 任务"
          ListItem() {
            Column({ space: 8 }) {
              LoadingProgress()
                .width(28)
                .height(28)
                .color($r('app.color.accent'))
              if (this.errorMsg.length > 0) {
                Text(`⚠ ${this.errorMsg}`)
                  .fontSize(12)
                  .fontColor($r('app.color.status_warn'))
              }
            }
            .width('100%')
            .height(360)
            .justifyContent(FlexAlign.Center)
          }
        } else {
          ListItem() {
            Column({ space: 8 }) {
              Text(this.errorMsg.length > 0 ? '加载失败' : '暂无 Ping 数据')
                .fontSize(15)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .height(360)
            .justifyContent(FlexAlign.Center)
          }
        }
      } else {
        // ===== 按节点拆分的 Ping 卡片 =====
        ForEach(this.nodeEntries, (entry: NodePingEntry) => {
          ListItem() {
            Column({ space: 8 }) {
              // 节点名称（卡片标题）
              Row({ space: 8 }) {
                Text(entry.nodeName)
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(`${entry.items.length} 项监控`)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')

              // 该节点在各 Ping 任务下的统计
              ForEach(entry.items, (item: NodePingItem) => {
                Row({ space: 8 }) {
                  Text(item.task.name)
                    .fontSize(13)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .constraintSize({ maxWidth: '28%' })
                  Text(this.typeLabel(item.task))
                    .fontSize(10)
                    .fontColor($r('app.color.accent'))
                    .backgroundColor($r('app.color.chip_bg'))
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(8)
                  Text(`平均 ${this.fmtMs(item.stats.avg)}`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                  Blank()
                  Text(`丢包 ${item.stats.loss.toFixed(1)}%`)
                    .fontSize(12)
                    .fontColor(item.stats.loss > 5 ? $r('app.color.status_bad') : $r('app.color.status_ok'))
                  Text('›')
                    .fontSize(16)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .width('100%')
                .padding({ top: 4, bottom: 4 })
                .onClick((): void => {
                  this.openDetailByItem(item);
                })
              }, (item: NodePingItem) => `${item.task.id}_${item.stats.entity_id}`)
            }
            .padding(14)
            .borderRadius(12)
            .backgroundColor($r('app.color.card_bg'))
            .width('100%')
          }
        }, (entry: NodePingEntry) => `${entry.uuid}_${entry.items.length}`)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 96 })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // clip(false) 让列表穿透到渐变模糊标题栏下方；cachedCount 预加载
    // 屏外列表项（官方要求），否则卡片滑入标题栏区域会被回收导致"消失"
    .cachedCount(3, true)
    .clip(false)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
