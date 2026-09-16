/**
 * PingPage —— Ping 任务列表（MainPage Tab2）
 *
 * 数据：getPublicPingTasks（任务）+ getPingMetricStats（近 1h 统计，一次拉全部任务）
 * 分组：stats[].task_id 是字符串，与任务 id 用 String() 对齐。
 * 判空：min/max/avg/latest 是 *float64 + omitempty，可能缺失 → fmtMs 里兜底。
 * loss 是 0~100 的百分比（源码 publicPingLossRate 已确认），不是次数；
 * 实测骨架统计条目可能连 loss/valid 都省略，渲染需 Number(...?? 0) 兜底。
 *
 * 连接状态 / 数据新鲜度：与 NodesPage 共用 FreshnessBanner（NodeDataStore 单一数据源），
 * 三级降级口径一致。本页的 getPublicPingTasks 是「单请求探针」，
 * 传输层失败会上报给数据层，从而驱动两页的离线提示同步。
 */

import { PingTask, PingTaskStats, KomariClient } from '../model/KomariTypes';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore, ConnectivityState } from '../common/NodeDataStore';
import { AppKeys } from '../common/constants/AppKeys';
import { KomariApi, PingStatsParams } from '../service/KomariApi';
import { router } from '@kit.ArkUI';
import { FormatUtil } from '../common/FormatUtil';
import { SessionState } from '../service/AuthService';
import { RpcException } from '../service/RpcClient';
import { FreshnessBanner, FreshnessUtil, freshnessTransition } from '../view/FreshnessBanner';
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

/**
 * 模块级缓存（2026-09-07 原地淡入切页模型下 PingPage 每次切 Tab 都会销毁重建，
 * 组件状态会丢；这里跨实例保留最近一次成功数据，重建时秒开、后台静默刷新）。
 * 以 serverSeq 为键：切服务端后旧缓存自然失效。
 */
interface PingPageCache {
  serverSeq: number;
  nodeEntries: NodePingEntry[];
  lastRefresh: string;
}

let pageCache: PingPageCache | null = null;

@Component
export struct PingPage {
  @State entries: PingEntry[] = [];
  @State nodeEntries: NodePingEntry[] = [];
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State lastRefresh: string = '';
  /** 连接状态与数据新鲜度：与 NodesPage 同源（NodeDataStore 单一数据源），保证两页提示口径一致 */
  @State connState: ConnectivityState = ConnectivityState.Online;
  @State lastSuccessAt: number = 0;
  @State dataExpired: boolean = false;
  /** 多服务端管理切换后 bump，本组件收到变化即重置轮询 */
  @StorageProp(AppKeys.SERVER_SEQ) @Watch('onServerChanged') serverSeq: number = 0;
  private timerId: number = -1;
  private refreshing: boolean = false;
  private unsubscribeConn: (() => void) | undefined = undefined;
  /** 由 MainPage 传入，供 HdsNavigation.bindToScrollable 联动滚动渐变模糊 */
  scroller: Scroller = new Scroller();
  /** 空态「去添加服务端」回调：MainPage 直接弹添加弹层，不进二级页面 */
  onAddServer: () => void = (): void => {};
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
    const store = NodeDataStore.getInstance();
    this.syncConnectivity();
    // 有同服务端的缓存数据则先铺底：重建后立即渲染卡片，不闪加载圈。
    // 数据已硬过期时不铺底 —— 否则会先闪一屏陈旧卡片、再被过期空态替换。
    if (pageCache && pageCache.serverSeq === this.serverSeq && pageCache.nodeEntries.length > 0
      && !this.dataExpired) {
      this.entries = [];
      this.nodeEntries = pageCache.nodeEntries;
      this.lastRefresh = pageCache.lastRefresh;
      this.loading = false;
    }
    // 订阅连接状态变化：即时切换离线提示；网络恢复时立即对齐（不必等下一个 10s 周期）
    this.unsubscribeConn = store.subscribeConnectivity((): void => {
      this.syncConnectivity();
      if (!this.paused && store.isNetworkAvailable()) {
        this.refreshOnce();
      }
    });
    this.startPolling();
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.unsubscribeConn?.();
    this.unsubscribeConn = undefined;
  }

  /** 从 NodeDataStore 同步连接状态与数据新鲜度（与 NodesPage 同一数据源） */
  private syncConnectivity(): void {
    const store = NodeDataStore.getInstance();
    this.connState = store.getConnectivityState();
    this.lastSuccessAt = store.getLastSuccessAt();
    this.dataExpired = store.isDataExpired();
    if (this.dataExpired) {
      // 过期数据不得通过模块级缓存在页面重建时复活
      pageCache = null;
    }
  }

  /**
   * 是否展示连接/新鲜度提示条。
   * 硬过期时不展示 —— 内容区已由 expiredCard 接管，且空态自带「重新连接」，
   * 再叠一条提示条就是同一件事说两遍、两个按钮做同一件事。
   */
  private showBanner(): boolean {
    if (this.dataExpired) {
      return false;
    }
    return FreshnessUtil.shouldShow(this.connState, this.lastSuccessAt);
  }

  /**
   * 链路是否可信（与 MainPage / NodesPage 同义）。
   * 不可信时 Ping 统计同样来自缓存快照，把丢包率涂成红/绿会被读成"当前状态"——
   * 那和 NodeCard 把"我看不到"说成"节点挂了"是同一类误读，故一律切灰。
   */
  private isLinkOk(): boolean {
    return this.connState === ConnectivityState.Online;
  }

  /**
   * 丢包率配色：链路不可信 → 灰；可信 → >5% 红，否则绿。
   * 灰用 text_secondary 而非 health_none —— 后者是圆点 / 指示灯的颜色，
   * 当 12vp 文字色用在白卡上只有 2.56:1 对比度，不达标。
   */
  private lossColor(loss: number): Resource {
    if (!this.isLinkOk()) {
      return $r('app.color.text_secondary');
    }
    return loss > 5 ? $r('app.color.status_bad') : $r('app.color.status_ok');
  }

  private onServerChanged(): void {
    pageCache = null;  // 切服务端：旧缓存立即失效，避免闪现错误服务端的数据
    this.entries = [];
    this.nodeEntries = [];
    this.errorMsg = '';
    this.lastRefresh = '';
    this.loading = true;
    this.syncConnectivity();
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

  private isNeedsLogin(): boolean {
    try {
      return ServiceRegistry.getAuth().getState() === SessionState.NeedsLogin;
    } catch (e) {
      return false;
    }
  }

  private async refreshOnce(): Promise<void> {
    // paused：页面不可见时不发请求（SERVER_SEQ 变化也会触发本方法，隐藏页直接跳过）
    if (this.refreshing || this.paused) {
      return;
    }
    // 退后台不发请求（与 NodesPage/NodeDetailPage 的前台闸一致，切回前台由下个周期恢复）
    if (!NodeDataStore.getInstance().isForeground()) {
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
      this.syncConnectivity();
      pageCache = { serverSeq: this.serverSeq, nodeEntries: nodeNext, lastRefresh: this.lastRefresh };
    } catch (err) {
      const e = err as RpcException;
      // 上报给数据层：本页是「单请求探针」，传输失败即代表服务端不可达
      NodeDataStore.getInstance().reportFetchFailure(e);
      // 传输层失败统一由 FreshnessBanner 呈现，errorMsg 只留业务类错误（避免同一问题两处提示）
      this.errorMsg = (e && e.transport === true) ? '' : (e?.message ?? '刷新失败');
      this.syncConnectivity();
    } finally {
      this.refreshing = false;
    }
  }

  /** 统计值兜底：服务端可能缺省 */
  private fmtMs(v: number | undefined): string {
    return FormatUtil.ms(v);
  }

  private openDetailByItem(item: NodePingItem): void {
    const name: string = item.stats.name && item.stats.name.length > 0
      ? item.stats.name
      : item.stats.entity_id.substring(0, 8);
    const param: PingDetailParam = {
      taskId: item.task.id,
      taskName: item.task.name,
      uuid: item.stats.entity_id,
      entityName: name,
      initialStats: item.stats
    };
    router.pushUrl({ url: 'pages/PingDetailPage', params: param });
  }

  private typeLabel(t: PingTask): string {
    const ty: string = t.type && t.type.length > 0 ? t.type.toUpperCase() : 'ICMP';
    return ty;
  }

  /** 引导页跳过后可能没有任何服务端配置 */
  private hasServer(): boolean {
    return ServiceRegistry.getActiveConfig() !== undefined;
  }

  @Builder
  noServerCard() {
    ListItem() {
      Column({ space: 10 }) {
        Text('未添加服务端')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text('添加你的 Komari 面板后，这里会显示 Ping 监控')
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
        Button('去添加服务端')
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .height(40)
          .onClick((): void => {
            // 主页直接弹「添加服务端」弹层（与管理页添加同款），
            // 不再跳转任何二级页面
            this.onAddServer();
          })
      }
      .width('100%')
      .height(360)
      .justifyContent(FlexAlign.Center)
    }
  }

  /** 数据硬过期空态（与 NodesPage 同一策略与文案） */
  @Builder
  expiredCard() {
    ListItem() {
      Column({ space: 10 }) {
        // 红色由空态承载（提示条在硬过期时已退场）：图标用 expired_bar 的鲜红保证
        // 28vp 图形在 page_bg 上的可辨识度（对比度约 3.5:1），标题用 expired_text 的深红
        SymbolGlyph($r('sys.symbol.ohos_wifi'))
          .fontSize(28)
          .fontColor([$r('app.color.expired_bar')])
        Text('数据已过期')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.expired_text'))
        Text(`上次更新在${FreshnessUtil.ageText(this.lastSuccessAt)}，联网后自动恢复`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
        Button('重新连接')
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .height(40)
          .onClick((): void => {
            this.refreshOnce();
          })
      }
      .width('100%')
      .height(360)
      .justifyContent(FlexAlign.Center)
    }
  }

  build() {
    // List 铺满整个内容区，Header 收进 List 内部，使其能随卡片滚到标题栏后
    List({ scroller: this.scroller, space: 10 }) {
      // ===== Header：连接提示条 + 更新时刻 + 错误提示（滚动时穿透渐变模糊） =====
      ListItem() {
        Column({ space: 8 }) {
          // 连接异常 / 数据陈旧：与 NodesPage 共用同一组件与文案口径
          if (this.showBanner()) {
            // 包一层容器挂 transition —— 自定义组件对通用属性的支持面较窄
            Column() {
              FreshnessBanner({
                state: this.connState,
                lastSuccessAt: this.lastSuccessAt,
                onRetry: (): void => {
                  this.refreshOnce();
                }
              })
            }
            .width('100%')
            .transition(freshnessTransition())
          }

          // 更新时刻：此前 lastRefresh 只在状态里、未渲染，与 NodesPage 口径不一致
          if (this.lastRefresh.length > 0) {
            Text(`更新于 ${this.lastRefresh}`)
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.End)
          }

          // 业务类错误提示（网络类已由上方提示条承载）
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
        if (!this.hasServer()) {
          this.noServerCard()
        } else if (this.loading || this.lastRefresh.length === 0) {
          // 首次拉取中，不闪"暂无 Ping 任务"
          ListItem() {
            Column({ space: 8 }) {
              LoadingProgress()
                .width(28)
                .height(28)
                .color($r('sys.color.ohos_id_color_emphasize'))
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
              if (this.errorMsg.length > 0) {
                Text(this.errorMsg)
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
              } else if (this.isNeedsLogin()) {
                Text('私有站点，登录后可查看')
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
              }
            }
            .width('100%')
            .height(360)
            .justifyContent(FlexAlign.Center)
          }
        }
      } else if (this.dataExpired) {
        // 数据已硬过期：不再展示陈旧卡片（与 NodesPage 同一策略）
        this.expiredCard()
      } else {
        // ===== 按节点拆分的 Ping 卡片 =====
        ForEach(this.nodeEntries, (entry: NodePingEntry) => {
          ListItem() {
            Column({ space: 8 }) {
              // 节点名称（卡片标题）：本身不挂点击，由整卡的 onClick 统一进 Ping 详情
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
                    .fontColor($r('sys.color.ohos_id_color_emphasize'))
                    .backgroundColor($r('app.color.chip_bg'))
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(8)
                  Text(`平均 ${this.fmtMs(item.stats.avg)}`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_secondary'))
                  Blank()
                  Text(`丢包 ${Number(item.stats.loss ?? 0).toFixed(1)}%`)
                    .fontSize(12)
                    .fontColor(this.lossColor(Number(item.stats.loss ?? 0)))
                  Text('›')
                    .fontSize(16)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
                .onClick((event: ClickEvent): void => {
                  this.openDetailByItem(item);
                })
              }, (item: NodePingItem) => `${item.task.id}_${item.stats.entity_id}`)
            }
            .padding(14)
            .borderRadius(20)
            .backgroundColor($r('app.color.card_bg'))
            .width('100%')
            // 整卡可点 → 第一个 Ping 任务详情；具体任务行的 onClick 已 stopPropagation 优先接管
            .onClick((): void => {
              if (entry.items.length > 0) {
                this.openDetailByItem(entry.items[0]);
              }
            })
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
