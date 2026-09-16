/**
 * NodesPage —— 节点列表（MainPage Tab1 内容）
 *
 * 顶部标题与搜索框已移至 MainPage 的 HdsNavigation titleBar。
 * 本组件只负责：分组筛选 + 排序 + 节点列表 + 下拉刷新。
 * 搜索关键词通过 AppStorage(AppKeys.SEARCH_KEYWORD) 从 titleBar 同步。
 * 列表 Scroller 由外部传入，供 HdsNavigation.bindToScrollable 联动滚动渐变模糊。
 *
 * 数据流（改造后）：
 *   - 静态信息（节点名称/型号/系统）：NodeDataStore 缓存 30 分钟
 *   - 实时指标（CPU/内存/网络）：递归 setTimeout 轮询（间隔可配置，默认 5 秒）
 *   - 并发限制：NodeDataStore 内置 ConcurrencyLimiter（默认 3，可配置）
 *   - 卡片通过订阅模式独立更新，不触发全量重绘
 *   - 排序锁定：静默轮询不重排卡片位置，仅主动操作时重算
 *   - 下拉刷新：强制穿透 30 分钟缓存，按 FetchOutcome 判定成败
 *     （断网时不再误报"刷新成功"）
 *   - 连接状态与数据新鲜度：由 NodeDataStore 单一数据源驱动，FreshnessBanner 统一呈现，
 *     三级降级 = 正常 → 陈旧提示条（缓存仍展示）→ 硬过期空态（不再展示陈旧卡片）
 */

import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { KomariClient } from '../model/KomariTypes';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { AppKeys } from '../common/constants/AppKeys';
import { FormatUtil } from '../common/FormatUtil';
import { NodeUtil } from '../common/NodeUtil';
import { SessionState } from '../service/AuthService';
import { NodeCard } from '../view/NodeCard';
import { NodeDataStore, FetchOutcome, ConnectivityState } from '../common/NodeDataStore';
import { FreshnessBanner, FreshnessUtil, freshnessTransition } from '../view/FreshnessBanner';

interface DetailParam {
  uuid: string;
}

@Component
export struct NodesPage {
  @State uuids: string[] = [];
  @State orderedUuids: string[] = [];   // 锁定的有序列表，静默轮询不改变
  @State groups: string[] = [];
  @State selectedGroup: string = '';
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State lastRefresh: string = '';
  @State onlineCount: number = 0;
  @State refreshing: boolean = false;    // 下拉刷新状态
  /**
   * 连接状态与数据新鲜度 —— 统一从 NodeDataStore 单一数据源读取。
   * 这两个维度刻意与 errorMsg 分开：errorMsg 只承载业务提示（如"需要登录"），
   * 网络类问题一律走 FreshnessBanner，避免各页面口径不一致。
   */
  @State connState: ConnectivityState = ConnectivityState.Online;
  @State lastSuccessAt: number = 0;
  @State dataExpired: boolean = false;
  /** 多服务端管理切换后 bump，本组件收到变化即清空并重建轮询 */
  @StorageProp(AppKeys.SERVER_SEQ) @Watch('onServerChanged') serverSeq: number = 0;
  @StorageProp(AppKeys.SEARCH_KEYWORD) @Watch('onKeywordChange') keyword: string = '';

  /** 递归 setTimeout 定时器（不用 setInterval，防重叠堆积） */
  private pollTimer: number = -1;
  private polling: boolean = false;
  private unsubscribeInfo: (() => void) | undefined = undefined;
  private unsubscribeConn: (() => void) | undefined = undefined;

  /** 由 MainPage 传入，供 HdsNavigation.bindToScrollable 联动 */
  scroller: Scroller = new Scroller();
  /** 空态「去添加服务端」回调：MainPage 直接弹添加弹层，不进二级页面 */
  onAddServer: () => void = (): void => {};
  /** MainPage 借此拿到本组件引用，用于切 Tab 时暂停/恢复轮询 */
  pageRef: (p: NodesPage) => void = (p: NodesPage): void => {};

  /** 轮询由 MainPage 切 Tab 时控制：仅可见 Tab 保持轮询 */
  private paused: boolean = false;

  pausePolling(): void {
    this.paused = true;
    this.stopPolling();
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
    // 订阅节点列表变化（静态信息更新后通知）
    this.unsubscribeInfo = store.subscribeInfo((): void => {
      this.uuids = store.getAllUuids();
      this.updateGroups();
      this.updateStats();
      // 节点增删时同步有序列表：数量变化或 orderedUuids 为空时重算
      if (this.orderedUuids.length === 0 || this.orderedUuids.length !== this.uuids.length) {
        this.recomputeOrder();
      }
    });
    // 订阅连接状态变化：即时切换离线提示；网络恢复时立即对齐一次（不必等下一个轮询周期）
    this.unsubscribeConn = store.subscribeConnectivity((): void => {
      this.syncConnectivity();
      if (!this.paused && store.isNetworkAvailable()) {
        this.startPolling();
      }
    });
    // 立即读一次缓存（秒开）
    this.uuids = store.getAllUuids();
    this.updateGroups();
    this.updateStats();
    this.syncConnectivity();
    if (this.uuids.length > 0) {
      this.loading = false;
      this.recomputeOrder();
    }
    this.startPolling();
  }

  aboutToDisappear(): void {
    this.stopPolling();
    this.unsubscribeInfo?.();
    this.unsubscribeInfo = undefined;
    this.unsubscribeConn?.();
    this.unsubscribeConn = undefined;
  }

  /** 从 NodeDataStore 同步连接状态与数据新鲜度（单一数据源，不在此自行判定） */
  private syncConnectivity(): void {
    const store = NodeDataStore.getInstance();
    this.connState = store.getConnectivityState();
    this.lastSuccessAt = store.getLastSuccessAt();
    this.dataExpired = store.isDataExpired();
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
   * 链路是否可信（与 MainPage.isLinkOk 同义）。
   * 不可信时缓存快照的「在线/离线」判断全部失效 —— NodeUtil.isOnline 的 90s 阈值
   * 会让所有节点在断网 90 秒后集体变「离线」，那是"我看不到"而非"服务器挂了"。
   * 此时卡片状态点走 health_none 灰、统计行文字走 text_secondary。
   */
  private isLinkOk(): boolean {
    return this.connState === ConnectivityState.Online;
  }

  private onServerChanged(): void {
    // 切换服务端：旧数据不能留在界面上，先清再重新轮询
    this.uuids = [];
    this.orderedUuids = [];
    this.groups = [];
    this.selectedGroup = '';
    this.errorMsg = '';
    this.loading = true;
    this.onlineCount = 0;
    AppStorage.setOrCreate(AppKeys.NODES_TOTAL, 0);
    AppStorage.setOrCreate(AppKeys.NODES_ONLINE, 0);
    this.syncConnectivity();
    this.startPolling();
  }

  /** 搜索关键词变化：用户主动操作，允许重排 */
  private onKeywordChange(): void {
    this.recomputeOrder();
  }

  /**
   * 重新计算有序列表 —— 只在以下时机调用：
   *   1. 首次加载完成
   *   2. 节点增删（数量变化时）
   *   3. 用户手动下拉刷新完成后
   *   4. 搜索关键词/分组筛选变化时
   * 绝不被静默轮询触发。
   */
  private recomputeOrder(): void {
    this.orderedUuids = this.filtered();
  }

  /**
   * 启动轮询：立即执行一次，之后用递归 setTimeout 调度。
   * 间隔从 NodeDataStore.getConfig() 读取，用户修改设置后下次自动生效。
   */
  private startPolling(): void {
    this.stopPolling();
    this.pollOnce();
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private async pollOnce(): Promise<void> {
    if (this.polling || this.paused) {
      return;
    }
    // 后台时跳过请求（定时器保留，切回前台自动恢复）
    const store = NodeDataStore.getInstance();
    if (!store.isForeground() || !store.isNetworkAvailable()) {
      const interval: number = store.getConfig().listInterval;
      this.pollTimer = setTimeout((): void => {
        this.pollOnce();
      }, interval);
      return;
    }
    if (!ServiceRegistry.getActiveConfig()) {
      this.errorMsg = '服务端未连接';
      return;
    }
    this.polling = true;
    try {
      // 1. 拉取节点列表（静态信息，内部 30 分钟缓存，不会每次都发请求）
      //    静默轮询忽略返回值；成败只体现在连接状态上（由 syncConnectivity 同步）
      await store.fetchNodeInfo();
      // 2. 批量拉取所有节点的实时指标（通过 store 内置限流器）
      const allUuids: string[] = store.getAllUuids();
      const limiter = store.getLimiter();
      await Promise.all(
        allUuids.map((uuid: string): Promise<FetchOutcome | undefined> => {
          return limiter.run((): Promise<FetchOutcome> => store.fetchReport(uuid));
        })
      );
      // 3. 更新统计
      this.updateStats();
      this.loading = false;
      this.errorMsg = '';
      this.lastRefresh = FormatUtil.clock(new Date().toISOString());
      this.syncConnectivity();
    } catch (err) {
      // 数据层的失败已在内部静默处理，这里只兜底装配类异常
      const e = err as Error;
      this.errorMsg = e?.message ?? '';
      this.syncConnectivity();
    } finally {
      this.polling = false;
      // 执行完毕后再延迟调度下一次（递归 setTimeout，防重叠）
      if (!this.paused) {
        const interval: number = NodeDataStore.getInstance().getConfig().listInterval;
        this.pollTimer = setTimeout((): void => {
          this.pollOnce();
        }, interval);
      }
    }
  }

  /**
   * 下拉刷新：强制穿透 30 分钟缓存，全量同步后重排。
   *
   * ⚠️ 必须按 FetchOutcome 判定成败，不能只看有没有抛异常 ——
   * 数据层在离线/网络异常时是「静默 return / catch 吞掉」，不抛异常。
   * 早期版本因此出现「断网下拉仍提示刷新成功」。
   */
  private async forceRefresh(): Promise<void> {
    const store = NodeDataStore.getInstance();
    if (!ServiceRegistry.getActiveConfig()) {
      this.refreshing = false;
      return;
    }
    // 刷新前先记录提示条是否已在展示：
    // 已经在提示"网络已断开"时，失败就无需再用 toast 重复说一遍（同屏两个断网提示很吵）；
    // 反之（刚断、横幅还没出现）才需要 toast 给出手势的即时反馈。
    const bannerWasVisible: boolean = this.showBanner();
    try {
      const infoOutcome: FetchOutcome = await store.fetchNodeInfo(true);
      if (infoOutcome === FetchOutcome.Failed) {
        throw new Error('节点列表刷新失败');
      }
      const allUuids: string[] = store.getAllUuids();
      const limiter = store.getLimiter();
      const outcomes: (FetchOutcome | undefined)[] = await Promise.all(
        allUuids.map((uuid: string): Promise<FetchOutcome | undefined> => {
          return limiter.run((): Promise<FetchOutcome> => store.fetchReport(uuid));
        })
      );
      let failed: number = 0;
      let skipped: number = 0;
      outcomes.forEach((o: FetchOutcome | undefined): void => {
        if (o === FetchOutcome.Failed) {
          failed++;
        } else if (o === undefined || o === FetchOutcome.Skipped) {
          // undefined = 被 clearQueue 取消（断网自愈），Skipped = 离线未发请求
          skipped++;
        }
      });
      // 有节点、但一个都没真正发出去 → 整体失败（典型：断网）
      if (outcomes.length > 0 && outcomes.length === skipped) {
        throw new Error('刷新失败，请检查网络');
      }
      this.updateStats();
      this.recomputeOrder();  // 下拉刷新后允许重排
      this.errorMsg = '';
      this.lastRefresh = FormatUtil.clock(new Date().toISOString());
      this.syncConnectivity();
      try {
        promptAction.showToast({
          message: failed > 0 ? `刷新完成，${failed} 个节点失败` : '刷新成功',
          duration: 1500
        });
      } catch (e) {
        // 忽略
      }
    } catch (err) {
      const e = err as Error;
      // 网络类失败统一由 FreshnessBanner 呈现，不再写 errorMsg（避免同一问题两处提示）
      this.errorMsg = '';
      this.syncConnectivity();
      // 横幅已经在说"断网"了就不重复弹 toast
      if (!bannerWasVisible) {
        try {
          promptAction.showToast({ message: e?.message ?? '刷新失败', duration: 1500 });
        } catch (e2) {
          // 忽略
        }
      }
    } finally {
      this.refreshing = false;
    }
  }

  private updateGroups(): void {
    const store = NodeDataStore.getInstance();
    const groupSet: Set<string> = new Set();
    store.getAllNodeInfo().forEach((n: KomariClient): void => {
      if (n.group && n.group.length > 0) {
        groupSet.add(n.group);
      }
    });
    this.groups = Array.from(groupSet).sort();
  }

  private updateStats(): void {
    const store = NodeDataStore.getInstance();
    let online: number = 0;
    this.uuids.forEach((uuid: string): void => {
      if (NodeUtil.isOnline(store.getLatestReport(uuid))) {
        online++;
      }
    });
    this.onlineCount = online;
    AppStorage.setOrCreate(AppKeys.NODES_TOTAL, this.uuids.length);
    AppStorage.setOrCreate(AppKeys.NODES_ONLINE, online);
  }

  /** gpu_name 探针占位值（与 NodeDetailPage.gpuPlaceholders 一致），不参与搜索 */
  private readonly gpuPlaceholders: string[] = ['none', 'unknown', 'n/a', 'null', ''];

  private filtered(): string[] {
    const kw: string = this.keyword.trim().toLowerCase();
    const store = NodeDataStore.getInstance();
    return this.uuids.filter((uuid: string): boolean => {
      const n: KomariClient | undefined = store.getNodeInfo(uuid);
      if (!n) {
        return false;
      }
      if (this.selectedGroup.length > 0 && n.group !== this.selectedGroup) {
        return false;
      }
      if (kw.length === 0) {
        return true;
      }
      let hay: string =
        `${n.name} ${n.region} ${n.group} ${n.tags} ${n.os} ${n.arch} ${n.cpu_name}`.toLowerCase();
      const gpu: string = n.gpu_name.trim().toLowerCase();
      if (gpu.length > 0 && !this.gpuPlaceholders.includes(gpu)) {
        hay += ` ${gpu}`;
      }
      return hay.includes(kw);
    });
  }

  private openDetail(uuid: string): void {
    const param: DetailParam = { uuid: uuid };
    router.pushUrl({ url: 'pages/NodeDetailPage', params: param });
  }

  private isGuest(): boolean {
    try {
      return ServiceRegistry.getAuth().getState() === SessionState.Guest;
    } catch (e) {
      return false;
    }
  }

  /** 会话缺失（未登录/已过期）：私有站点的节点需要登录后才能看到 */
  private isNeedsLogin(): boolean {
    try {
      return ServiceRegistry.getAuth().getState() === SessionState.NeedsLogin;
    } catch (e) {
      return false;
    }
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
        Text('添加你的 Komari 面板后，这里会显示节点')
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

  /**
   * 数据硬过期空态：超过 dataExpireTtl 没有成功拉取，不再展示陈旧卡片。
   * 文案强调"自动恢复"，避免用户以为数据丢了要手动清理。
   */
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
            this.refreshing = true;
            this.forceRefresh();
          })
      }
      .width('100%')
      .height(360)
      .justifyContent(FlexAlign.Center)
    }
  }

  build() {
    // Refresh 包裹 List，支持原生下拉刷新
    Refresh({ refreshing: $$this.refreshing, offset: 40, friction: 1 }) {
      List({ scroller: this.scroller, space: 10 }) {
        // ===== Header：连接提示条 + 统计行 =====
        ListItem() {
          Column({ space: 8 }) {
            // 连接异常 / 数据陈旧：内联提示条，跟随列表滚动（不吸顶、不遮罩、不弹窗）
            if (this.showBanner()) {
              // 包一层容器挂 transition —— 自定义组件对通用属性的支持面较窄
              Column() {
                FreshnessBanner({
                  state: this.connState,
                  lastSuccessAt: this.lastSuccessAt,
                  onRetry: (): void => {
                    this.refreshing = true;
                    this.forceRefresh();
                  }
                })
              }
              .width('100%')
              .transition(freshnessTransition())
            }

            Row({ space: 12 }) {
              Text(`共 ${this.uuids.length}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
              // 链路不可信时不显示数字：onlineCount 由陈旧快照算出、断网后恒为 0 ——
              // 那是"我不知道"而不是"一个都没在线"。用「—」把话说准，比"把 0 涂灰"更诚实
              // （涂灰也不奏效：本项目 text_tertiary 2.42:1 与 health_none 2.56:1 肉眼几乎分不出）
              Text(this.isLinkOk() ? `在线 ${this.onlineCount}` : '在线 —')
                .fontSize(12)
                .fontColor(this.isLinkOk()
                  ? $r('app.color.status_ok')
                  : $r('app.color.text_secondary'))
              Blank()
              if (this.lastRefresh.length > 0) {
                Text(`更新于 ${this.lastRefresh}`)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
              }
            }
            .width('100%')

            if (this.groups.length > 0) {
              Scroll() {
                Row({ space: 8 }) {
                  this.groupChip('', '全部')
                  ForEach(this.groups, (g: string) => {
                    this.groupChip(g, g)
                  }, (g: string) => g)
                }
              }
              .scrollable(ScrollDirection.Horizontal)
              .width('100%')
              .scrollBar(BarState.Off)
            }

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
        if (this.orderedUuids.length === 0) {
          if (!this.hasServer()) {
            this.noServerCard()
          } else if (this.loading || this.lastRefresh.length === 0) {
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
                Text(this.errorMsg.length > 0
                  ? '加载失败'
                  : (this.keyword.trim().length > 0 ? '无匹配节点' : '暂无节点'))
                  .fontSize(15)
                  .fontColor($r('app.color.text_secondary'))
                if (this.errorMsg.length > 0) {
                  Text('下拉检查服务端后自动重试')
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                } else if (this.keyword.trim().length > 0) {
                  Text('换个关键词，或清空搜索查看全部节点')
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                } else if (this.isNeedsLogin()) {
                  Text('私有站点，登录后可查看节点')
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                } else if (this.isGuest()) {
                  Text('游客模式下隐藏节点不可见，登录后可查看全部节点')
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
          // 数据已硬过期：陈旧卡片不再展示，避免冒充实时数据
          this.expiredCard()
        } else {
          // ===== 节点卡片：用锁定的 orderedUuids，静默轮询不重排 =====
          ForEach(this.orderedUuids, (uuid: string) => {
            ListItem() {
              // linkOk 让卡片知道"我看不到"与"节点挂了"的区别：链路不可信时状态点切灰，
              // 而不是按 90s 阈值把全部节点误报成红色「离线」
              NodeCard({ uuid: uuid, linkOk: this.isLinkOk() })
                .onClick((): void => {
                  this.openDetail(uuid);
                })
            }
          }, (uuid: string) => uuid)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, bottom: 96 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .cachedCount(3, true)
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .clip(false)
    .onRefreshing((): void => {
      this.forceRefresh();
    })
  }

  @Builder
  groupChip(label: string, value: string) {
    Text(label.length === 0 ? value : label)
      .fontSize(12)
      .fontColor(this.selectedGroup === value ? Color.White : $r('app.color.text_secondary'))
      .backgroundColor(this.selectedGroup === value ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.card_bg'))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .borderRadius(14)
      .onClick((): void => {
        this.selectedGroup = value;
        this.recomputeOrder();  // 分组变化时重排
      })
  }
}
