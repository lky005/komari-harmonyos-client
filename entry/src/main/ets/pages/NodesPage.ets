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
 *   - 下拉刷新：强制穿透 30 分钟缓存，全量同步后重排
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
import { NodeDataStore } from '../common/NodeDataStore';

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
  /** 多服务端管理切换后 bump，本组件收到变化即清空并重建轮询 */
  @StorageProp(AppKeys.SERVER_SEQ) @Watch('onServerChanged') serverSeq: number = 0;
  @StorageProp(AppKeys.SEARCH_KEYWORD) @Watch('onKeywordChange') keyword: string = '';

  /** 递归 setTimeout 定时器（不用 setInterval，防重叠堆积） */
  private pollTimer: number = -1;
  private polling: boolean = false;
  private unsubscribeInfo: (() => void) | undefined = undefined;

  /** 由 MainPage 传入，供 HdsNavigation.bindToScrollable 联动 */
  scroller: Scroller = new Scroller();
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
    // 立即读一次缓存（秒开）
    this.uuids = store.getAllUuids();
    this.updateGroups();
    this.updateStats();
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
      await store.fetchNodeInfo();
      // 2. 批量拉取所有节点的实时指标（通过 store 内置限流器）
      const allUuids: string[] = store.getAllUuids();
      const limiter = store.getLimiter();
      await Promise.all(
        allUuids.map((uuid: string): Promise<void> => {
          return limiter.run((): Promise<void> => store.fetchReport(uuid));
        })
      );
      // 3. 更新统计
      this.updateStats();
      this.loading = false;
      this.errorMsg = '';
      this.lastRefresh = FormatUtil.clock(new Date().toISOString());
    } catch (err) {
      const e = err as Error;
      this.errorMsg = e?.message ?? '刷新失败';
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

  /** 下拉刷新：强制穿透缓存，全量同步后重排 */
  private async forceRefresh(): Promise<void> {
    const store = NodeDataStore.getInstance();
    try {
      await store.fetchNodeInfo(true);  // true = 穿透 30 分钟缓存
      const allUuids: string[] = store.getAllUuids();
      const limiter = store.getLimiter();
      await Promise.all(
        allUuids.map((uuid: string): Promise<void> => {
          return limiter.run((): Promise<void> => store.fetchReport(uuid));
        })
      );
      this.updateStats();
      this.recomputeOrder();  // 下拉刷新后允许重排
      this.errorMsg = '';
      this.lastRefresh = FormatUtil.clock(new Date().toISOString());
      try {
        promptAction.showToast({ message: '刷新成功', duration: 1500 });
      } catch (e) {
        // 忽略
      }
    } catch (err) {
      const e = err as Error;
      this.errorMsg = e?.message ?? '刷新失败';
      try {
        promptAction.showToast({ message: '刷新失败', duration: 1500 });
      } catch (e2) {
        // 忽略
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
      const hay: string = `${n.name} ${n.region} ${n.group} ${n.tags} ${n.os} ${n.cpu_name}`.toLowerCase();
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

  build() {
    // Refresh 包裹 List，支持原生下拉刷新
    Refresh({ refreshing: $$this.refreshing, offset: 40, friction: 1 }) {
      List({ scroller: this.scroller, space: 10 }) {
        // ===== Header：统计行 =====
        ListItem() {
          Column({ space: 8 }) {
            Row({ space: 12 }) {
              Text(`共 ${this.uuids.length}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
              Text(`在线 ${this.onlineCount}`)
                .fontSize(12)
                .fontColor($r('app.color.status_ok'))
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
          if (this.loading || this.lastRefresh.length === 0) {
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
                Text(this.errorMsg.length > 0 ? '加载失败' : '暂无节点')
                  .fontSize(15)
                  .fontColor($r('app.color.text_secondary'))
                if (this.errorMsg.length > 0) {
                  Text('下拉检查服务端后自动重试')
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
        } else {
          // ===== 节点卡片：用锁定的 orderedUuids，静默轮询不重排 =====
          ForEach(this.orderedUuids, (uuid: string) => {
            ListItem() {
              NodeCard({ uuid: uuid })
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
      .backgroundColor(this.selectedGroup === value ? $r('app.color.accent') : $r('app.color.card_bg'))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .borderRadius(14)
      .onClick((): void => {
        this.selectedGroup = value;
        this.recomputeOrder();  // 分组变化时重排
      })
  }
}
