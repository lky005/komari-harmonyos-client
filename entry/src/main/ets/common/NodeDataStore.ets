/**
 * NodeDataStore —— 全局节点数据仓库（动静分离 + 订阅通知 + 竞态防护 + 配置管理 + 冷启动快照）
 *
 * 设计目标：
 *   1. 静态信息（节点名称/型号/系统）缓存 30 分钟，不重复走网络
 *   2. 实时指标（CPU/内存/网络）高频轮询，写入后通知订阅者
 *   3. 列表→详情数据复用：详情页直接读缓存秒开，不等网络
 *   4. 竞态防护：请求序号 + 数据时间戳双重校验，防旧响应覆盖新数据
 *   5. 单卡片单订阅：每个 NodeCard 只订阅自己的 uuid，不触发全量重绘
 *   6. 切换服务端时 clear()，广播通知所有订阅者平滑过渡到占位状态
 *   7. 用户偏好配置：轮询频率/并发数/Ping 详情缓存 TTL 可配置，持久化到 ServerStore
 *   8. 冷启动快照：异步持久化到文件，杀进程后再次打开直接渲染
 *   9. 网络状态：断网时跳过请求，恢复时清空排队任务并主动对齐
 *  10. 连接状态单一数据源：ConnectivityState + lastSuccessAt，供各页面统一渲染离线提示
 *      （连接状态与数据新鲜度是正交概念，分开表达，不要再混进 errorMsg 字符串）
 *  11. 拉取结果可判定：fetchNodeInfo / fetchReport 返回 FetchOutcome，
 *      主动刷新（下拉 / 重试）据此判成败，避免"断网也提示刷新成功"
 */

import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { KomariClient, ClientReport } from '../model/KomariTypes';
import { ServiceRegistry } from './ServiceRegistry';
import { ConcurrencyLimiter } from './ConcurrencyLimiter';

const STATIC_CACHE_TTL: number = 30 * 60 * 1000; // 静态信息缓存 30 分钟
const SNAPSHOT_DEBOUNCE_MS: number = 2000;       // 快照写入防抖 2 秒
const SNAPSHOT_FILENAME: string = 'node_snapshot.json';

/** 用户可配置的轮询参数 */
export interface PollConfig {
  listInterval: number;    // 列表页轮询间隔（ms），默认 5000
  detailInterval: number;  // 详情页轮询间隔（ms），默认 2000
  maxConcurrent: number;   // 最大并发拉取数，默认 3
  pingCacheTtl: number;    // Ping 详情记录缓存 TTL（ms），0=关闭，默认 300000（5 分钟）
  dataExpireTtl: number;   // 数据硬过期阈值（ms）：超过则页面切「过期空态」，默认 24 小时
}

/**
 * 单次拉取的结果。
 *
 * 后台静默轮询可以忽略返回值；**主动刷新（下拉 / 重试）必须据此判定成败**。
 * 背景：离线与网络异常在数据层是「静默 return / catch 吞掉」，不抛异常，
 * 若刷新路径只看有没有 reject，就会在断网时提示「刷新成功」。
 */
export enum FetchOutcome {
  /** 请求成功完成（含空数据、迟到响应被丢弃） */
  Ok = 0,
  /** 未发请求：离线、无服务端配置、或命中静态缓存 */
  Skipped = 1,
  /** 发起了请求但失败（网络不可达 / 超时 / 服务端错误） */
  Failed = 2
}

/**
 * 全局连接状态（单一数据源）。
 *
 * 与「数据新鲜度」是两个正交概念，必须分开表达：
 *   - 连接状态回答「现在能不能连上」
 *   - 数据新鲜度回答「屏幕上的数字是多久以前的」
 * 把二者混进一个 errorMsg 字符串，是各页面断网提示不一致的根因。
 */
export enum ConnectivityState {
  /** 最近一次请求成功 */
  Online = 0,
  /** 设备有网，但服务端不可达（传输层失败） */
  Degraded = 1,
  /** 设备无网络连接 */
  Offline = 2
}

/**
 * 仅用于识别「传输层失败」，避免 NodeDataStore 反向依赖 RpcClient。
 * 对应 RpcException.transport（HTTP 连不上/超时 = true；服务端返回的业务错误 = false）。
 */
interface TransportErrorLike {
  transport?: boolean;
}

/** 冷启动快照文件格式 */
interface SnapshotData {
  savedAt: number;
  serverId: string;
  nodes: KomariClient[];
  reports: Record<string, ClientReport>;
}

const DEFAULT_CONFIG: PollConfig = {
  listInterval: 5000,
  detailInterval: 2000,
  maxConcurrent: 3,
  pingCacheTtl: 5 * 60 * 1000,
  dataExpireTtl: 24 * 60 * 60 * 1000
};

export class NodeDataStore {
  private static instance: NodeDataStore | undefined = undefined;

  // ===== 数据存储（非响应式，纯数据容器）=====
  private nodeInfo: Map<string, KomariClient> = new Map();
  private latestReport: Map<string, ClientReport> = new Map();
  private nodeInfoTimestamp: number = 0;

  // ===== 竞态防护 =====
  private requestSeq: Map<string, number> = new Map();
  private appliedSeq: Map<string, number> = new Map();

  // ===== 订阅者 =====
  private reportSubscribers: Map<string, Set<() => void>> = new Map();
  private infoSubscribers: Set<() => void> = new Set();
  private configSubscribers: Set<() => void> = new Set();

  // ===== 用户偏好配置 =====
  private config: PollConfig = {
    listInterval: DEFAULT_CONFIG.listInterval,
    detailInterval: DEFAULT_CONFIG.detailInterval,
    maxConcurrent: DEFAULT_CONFIG.maxConcurrent,
    pingCacheTtl: DEFAULT_CONFIG.pingCacheTtl,
    dataExpireTtl: DEFAULT_CONFIG.dataExpireTtl
  };
  private limiter: ConcurrencyLimiter = new ConcurrencyLimiter(DEFAULT_CONFIG.maxConcurrent);

  // ===== 前后台与网络状态 =====
  private foreground: boolean = true;
  private networkAvailable: boolean = true;

  // ===== 连接状态与数据新鲜度（单一数据源）=====
  /** 最近一次成功拉取的时刻（ms，0 = 从未成功）；数据新鲜度的唯一依据 */
  private lastSuccessAt: number = 0;
  /** 最近一次失败是否为「传输层失败」；服务端可达的业务错误（如 401）不算连接异常 */
  private lastFetchFailed: boolean = false;
  /** 连接状态订阅者：页面据此即时切换离线提示、并在恢复时立即对齐 */
  private connectivitySubscribers: Set<() => void> = new Set();

  // ===== 冷启动快照 =====
  private context: common.UIAbilityContext | undefined = undefined;
  private snapshotTimer: number = -1;

  static getInstance(): NodeDataStore {
    if (!NodeDataStore.instance) {
      NodeDataStore.instance = new NodeDataStore();
    }
    return NodeDataStore.instance;
  }

  // ============================================================
  // Context 注入（EntryAbility.onCreate 调用）
  // ============================================================

  initContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  // ============================================================
  // 用户偏好配置
  // ============================================================

  /** 启动时从 ServerStore 异步加载配置 */
  async loadConfig(): Promise<void> {
    try {
      const store = ServiceRegistry.getServerStore();
      this.config.listInterval = parseInt(await store.getSetting('pref_list_interval', `${DEFAULT_CONFIG.listInterval}`), 10) || DEFAULT_CONFIG.listInterval;
      this.config.detailInterval = parseInt(await store.getSetting('pref_detail_interval', `${DEFAULT_CONFIG.detailInterval}`), 10) || DEFAULT_CONFIG.detailInterval;
      this.config.maxConcurrent = parseInt(await store.getSetting('pref_max_concurrent', `${DEFAULT_CONFIG.maxConcurrent}`), 10) || DEFAULT_CONFIG.maxConcurrent;
      // TTL 合法值含 0（关闭），不能用「|| 默认值」兜底，否则 0 会被吞掉
      const ttl: number = parseInt(await store.getSetting('pref_ping_cache_ttl', `${DEFAULT_CONFIG.pingCacheTtl}`), 10);
      this.config.pingCacheTtl = isNaN(ttl) ? DEFAULT_CONFIG.pingCacheTtl : Math.max(0, ttl);
      // 数据硬过期阈值：0 = 不硬过期（始终展示缓存，仅靠新鲜度徽标提示）
      const expire: number = parseInt(await store.getSetting('pref_data_expire_ttl', `${DEFAULT_CONFIG.dataExpireTtl}`), 10);
      this.config.dataExpireTtl = isNaN(expire) ? DEFAULT_CONFIG.dataExpireTtl : Math.max(0, expire);
      this.limiter.setMaxConcurrent(this.config.maxConcurrent);
    } catch (e) {
      // 加载失败用默认值
    }
  }

  /** 设置页修改后调用：写入存储 + 更新限流器 + 通知订阅者 */
  async updateConfig(partial: Partial<PollConfig>): Promise<void> {
    if (partial.listInterval !== undefined) {
      this.config.listInterval = partial.listInterval;
    }
    if (partial.detailInterval !== undefined) {
      this.config.detailInterval = partial.detailInterval;
    }
    if (partial.maxConcurrent !== undefined) {
      this.config.maxConcurrent = partial.maxConcurrent;
    }
    if (partial.pingCacheTtl !== undefined) {
      this.config.pingCacheTtl = Math.max(0, partial.pingCacheTtl);
    }
    if (partial.dataExpireTtl !== undefined) {
      this.config.dataExpireTtl = Math.max(0, partial.dataExpireTtl);
    }
    try {
      const store = ServiceRegistry.getServerStore();
      if (partial.listInterval !== undefined) {
        await store.putSetting('pref_list_interval', `${partial.listInterval}`);
      }
      if (partial.detailInterval !== undefined) {
        await store.putSetting('pref_detail_interval', `${partial.detailInterval}`);
      }
      if (partial.maxConcurrent !== undefined) {
        await store.putSetting('pref_max_concurrent', `${partial.maxConcurrent}`);
        this.limiter.setMaxConcurrent(partial.maxConcurrent);
      }
      if (partial.pingCacheTtl !== undefined) {
        await store.putSetting('pref_ping_cache_ttl', `${Math.max(0, partial.pingCacheTtl)}`);
      }
      if (partial.dataExpireTtl !== undefined) {
        await store.putSetting('pref_data_expire_ttl', `${Math.max(0, partial.dataExpireTtl)}`);
      }
    } catch (e) {
      // 写入失败不影响内存中的配置
    }
    this.configSubscribers.forEach((cb: () => void): void => {
      try { cb(); } catch (e) { /* 忽略 */ }
    });
    // 一并广播连接状态：dataExpireTtl 这类「新鲜度相关」配置由页面的 syncConnectivity() 读取，
    // 借此让设置页的改动立即生效，不必等下一次轮询或重新进页面。
    // 顺带效果：页面收到通知后会重启轮询，listInterval 的改动同样是立即生效的。
    this.notifyConnectivity();
  }

  getConfig(): PollConfig {
    return {
      listInterval: this.config.listInterval,
      detailInterval: this.config.detailInterval,
      maxConcurrent: this.config.maxConcurrent,
      pingCacheTtl: this.config.pingCacheTtl,
      dataExpireTtl: this.config.dataExpireTtl
    };
  }

  getLimiter(): ConcurrencyLimiter {
    return this.limiter;
  }

  subscribeConfig(cb: () => void): () => void {
    this.configSubscribers.add(cb);
    return (): void => { this.configSubscribers.delete(cb); };
  }

  // ============================================================
  // 订阅管理
  // ============================================================

  subscribeReport(uuid: string, callback: () => void): () => void {
    let set = this.reportSubscribers.get(uuid);
    if (!set) {
      set = new Set<() => void>();
      this.reportSubscribers.set(uuid, set);
    }
    set.add(callback);
    return (): void => { set!.delete(callback); };
  }

  subscribeInfo(callback: () => void): () => void {
    this.infoSubscribers.add(callback);
    return (): void => { this.infoSubscribers.delete(callback); };
  }

  private notifyReport(uuid: string): void {
    const set = this.reportSubscribers.get(uuid);
    if (set) {
      set.forEach((cb: () => void): void => {
        try { cb(); } catch (e) { /* 忽略 */ }
      });
    }
  }

  private notifyInfo(): void {
    this.infoSubscribers.forEach((cb: () => void): void => {
      try { cb(); } catch (e) { /* 忽略 */ }
    });
  }

  // ============================================================
  // 数据读取（同步，立即返回缓存）
  // ============================================================

  getNodeInfo(uuid: string): KomariClient | undefined {
    return this.nodeInfo.get(uuid);
  }

  getLatestReport(uuid: string): ClientReport | undefined {
    return this.latestReport.get(uuid);
  }

  getAllNodeInfo(): KomariClient[] {
    return Array.from(this.nodeInfo.values());
  }

  getAllUuids(): string[] {
    return Array.from(this.nodeInfo.keys());
  }

  hasNodeInfo(): boolean {
    return this.nodeInfo.size > 0;
  }

  // ============================================================
  // 前后台与网络状态
  // ============================================================

  setForeground(foreground: boolean): void {
    this.foreground = foreground;
  }

  isForeground(): boolean {
    return this.foreground;
  }

  setNetworkAvailable(available: boolean): void {
    this.networkAvailable = available;
  }

  isNetworkAvailable(): boolean {
    return this.networkAvailable;
  }

  // ============================================================
  // 连接状态与数据新鲜度（单一数据源）
  // ============================================================

  /**
   * 当前连接状态。判定优先级：设备无网 > 传输层失败 > 正常。
   * 注意：服务端正常返回的业务错误（如 401 需登录）不算连接异常 —— 链路是通的。
   */
  getConnectivityState(): ConnectivityState {
    if (!this.networkAvailable) {
      return ConnectivityState.Offline;
    }
    if (this.lastFetchFailed) {
      return ConnectivityState.Degraded;
    }
    return ConnectivityState.Online;
  }

  /** 最近一次成功拉取的时刻（ms，0 = 从未成功）；数据新鲜度的唯一依据 */
  getLastSuccessAt(): number {
    return this.lastSuccessAt;
  }

  /**
   * 数据是否已「硬过期」：超过 dataExpireTtl 没有任何成功拉取。
   * 从未成功过（lastSuccessAt === 0）返回 false —— 那种情况走原有的加载/空态逻辑，
   * 不归过期态管。dataExpireTtl === 0 表示不硬过期（始终展示缓存，仅靠新鲜度徽标提示）。
   */
  isDataExpired(): boolean {
    if (this.lastSuccessAt <= 0 || this.config.dataExpireTtl <= 0) {
      return false;
    }
    return Date.now() - this.lastSuccessAt > this.config.dataExpireTtl;
  }

  /**
   * 订阅连接状态变化。页面据此即时切换离线提示，
   * 并在网络恢复时立即发起一次对齐刷新（否则要等下一个轮询周期）。
   */
  subscribeConnectivity(cb: () => void): () => void {
    this.connectivitySubscribers.add(cb);
    return (): void => { this.connectivitySubscribers.delete(cb); };
  }

  private notifyConnectivity(): void {
    this.connectivitySubscribers.forEach((cb: () => void): void => {
      try { cb(); } catch (e) { /* 忽略 */ }
    });
  }

  /** 记录一次成功拉取：刷新新鲜度、清除连接异常标记 */
  private noteFetchSuccess(): void {
    this.lastSuccessAt = Date.now();
    const wasFailed: boolean = this.lastFetchFailed;
    this.lastFetchFailed = false;
    if (wasFailed) {
      this.notifyConnectivity();
    }
  }

  /**
   * 记录一次失败。只有「传输层失败」才标记为连接异常 ——
   * 服务端正常返回的业务错误（401 / -32041）说明链路通畅，不应显示离线提示。
   *
   * 注意：**只有本方法（由 fetchNodeInfo 调用）能置位失败标记**。
   * fetchNodeInfo 是「一次请求代表整个服务端可达性」的探针，它的传输失败才是
   * 强信号；而多节点并发拉取时个别节点失败属服务端数据问题，不该让全局横幅
   * 反复闪烁。fetchReport 只允许清除标记（成功即证明链路通畅），不允许置位。
   */
  private noteFetchFailure(err: Object): void {
    const e = err as TransportErrorLike;
    const transport: boolean = !!e && e.transport === true;
    if (transport && !this.lastFetchFailed) {
      this.lastFetchFailed = true;
      this.notifyConnectivity();
    }
  }

  /**
   * 供页面级「单请求探针」上报传输失败（如 PingPage 的 getPublicPingTasks）。
   * 只接受传输层失败；业务错误（401 等）不算连接异常。
   * ⚠️ 不要在多节点并发循环里调用 —— 个别节点失败会让全局横幅反复闪烁。
   */
  reportFetchFailure(err: Object): void {
    this.noteFetchFailure(err);
  }

  /** 供页面级「单请求探针」上报成功（证明链路通畅，可清除连接异常标记） */
  reportFetchSuccess(): void {
    this.noteFetchSuccess();
  }

  /**
   * 网络恢复时调用：清空排队任务 + 广播连接状态变化。
   * 页面订阅 subscribeConnectivity 后会立即发起一次对齐刷新，
   * 不必等下一个轮询周期（列表最长 30s）。
   */
  onNetworkRestore(): void {
    this.networkAvailable = true;
    this.limiter.clearQueue();
    this.notifyConnectivity();
    // 兼容既有语义：配置订阅者也收一次通知
    this.configSubscribers.forEach((cb: () => void): void => {
      try { cb(); } catch (e) { /* 忽略 */ }
    });
  }

  onNetworkLost(): void {
    this.networkAvailable = false;
    this.notifyConnectivity();
  }

  // ============================================================
  // 数据拉取
  // ============================================================

  /**
   * 拉取节点静态信息（30 分钟缓存）。
   *
   * 返回 FetchOutcome 而非 void：后台轮询可忽略返回值，但下拉刷新 / 重试必须
   * 据此判定成败 —— 这里的失败是「静默保留旧缓存」，不抛异常，调用方无从感知。
   * 同时它也是全局连接状态的探针（见 noteFetchFailure 的说明）。
   */
  async fetchNodeInfo(force: boolean = false): Promise<FetchOutcome> {
    const now: number = Date.now();
    if (!force && this.nodeInfo.size > 0 && now - this.nodeInfoTimestamp < STATIC_CACHE_TTL) {
      return FetchOutcome.Skipped;
    }
    if (!ServiceRegistry.getActiveConfig() || !this.networkAvailable) {
      return FetchOutcome.Skipped;
    }
    try {
      const nodes: KomariClient[] = await ServiceRegistry.getApi().getNodes();
      this.nodeInfo.clear();
      nodes.forEach((n: KomariClient): void => {
        this.nodeInfo.set(n.uuid, n);
      });
      this.nodeInfoTimestamp = now;
      this.noteFetchSuccess();
      this.notifyInfo();
      this.scheduleSnapshotSave();
      return FetchOutcome.Ok;
    } catch (e) {
      // 拉取失败保留旧缓存，不抛出；但要把连接异常记下来
      this.noteFetchFailure(e);
      return FetchOutcome.Failed;
    }
  }

  /**
   * 拉取单节点最新快照。
   *
   * 返回 FetchOutcome 供主动刷新判定；迟到响应与时间戳倒退都算「请求成功但数据丢弃」
   * （Ok），不算失败 —— 否则会把正常的竞态保护误报成刷新失败。
   */
  async fetchReport(uuid: string): Promise<FetchOutcome> {
    if (!ServiceRegistry.getActiveConfig() || !this.networkAvailable) {
      return FetchOutcome.Skipped;
    }
    const seq: number = (this.requestSeq.get(uuid) ?? 0) + 1;
    this.requestSeq.set(uuid, seq);

    try {
      const list: ClientReport[] = await ServiceRegistry.getApi().getClientRecentRecords(uuid);

      // 校验1：旧请求直接丢弃（迟到的响应）
      const applied: number = this.appliedSeq.get(uuid) ?? 0;
      if (seq < applied) {
        this.noteFetchSuccess();
        return FetchOutcome.Ok;
      }

      if (!list || list.length === 0) {
        // 请求本身成功（服务端返回空列表），不算失败
        this.noteFetchSuccess();
        return FetchOutcome.Ok;
      }
      const report: ClientReport = list[list.length - 1];

      // 校验2：数据时间戳倒退也丢弃（服务端采集时序异常）
      const existing: ClientReport | undefined = this.latestReport.get(uuid);
      if (existing && existing.updated_at && report.updated_at) {
        try {
          if (Date.parse(report.updated_at) < Date.parse(existing.updated_at)) {
            this.noteFetchSuccess();
            return FetchOutcome.Ok;
          }
        } catch (e) {
          // 时间戳解析失败时跳过该校验
        }
      }

      this.latestReport.set(uuid, report);
      this.appliedSeq.set(uuid, seq);
      this.noteFetchSuccess();
      this.notifyReport(uuid);
      this.scheduleSnapshotSave();
      return FetchOutcome.Ok;
    } catch (e) {
      // 请求失败不更新 seq，下次重试。
      // 不在此处置位连接异常标记：多节点并发时个别失败不该让全局横幅闪烁，
      // 服务端可达性由 fetchNodeInfo 探针负责（见 noteFetchFailure 说明）。
      return FetchOutcome.Failed;
    }
  }

  // ============================================================
  // 冷启动快照（异步文件 I/O，不阻塞主线程）
  // ============================================================

  /** 防抖写入快照：高频轮询不会频繁写盘 */
  private scheduleSnapshotSave(): void {
    if (this.snapshotTimer >= 0) {
      clearTimeout(this.snapshotTimer);
    }
    this.snapshotTimer = setTimeout((): void => {
      this.saveSnapshot();
    }, SNAPSHOT_DEBOUNCE_MS);
  }

  private async saveSnapshot(): Promise<void> {
    if (!this.context || !ServiceRegistry.getActiveConfig()) {
      return;
    }
    try {
      const data: SnapshotData = {
        savedAt: Date.now(),
        serverId: ServiceRegistry.getActiveConfig()!.id,
        nodes: this.getAllNodeInfo(),
        reports: {}
      };
      this.latestReport.forEach((report: ClientReport, uuid: string): void => {
        data.reports[uuid] = report;
      });
      const path: string = this.context.filesDir + '/' + SNAPSHOT_FILENAME;
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(data));
      fs.closeSync(file);
    } catch (e) {
      // 写失败不影响运行，下次重试
    }
  }

  /**
   * 冷启动时加载快照。双重校验：
   *   1. serverId 必须匹配 —— 防多服务端数据污染
   *   2. savedAt 未超过 dataExpireTtl —— 防杀进程重开后把数天前的数据当实时渲染
   * 第 2 条是必须的：没有它，任何陈旧快照都会无限期冒充实时数据。
   */
  async loadSnapshot(serverId: string): Promise<void> {
    if (!this.context) {
      return;
    }
    const path: string = this.context.filesDir + '/' + SNAPSHOT_FILENAME;
    try {
      const json: string = fs.readTextSync(path);
      const data = JSON.parse(json) as SnapshotData;
      if (data.serverId !== serverId) {
        return;
      }
      // 年龄校验：savedAt 非法（0 / undefined / NaN）或来自未来 → 直接丢弃
      const savedAt: number = data.savedAt;
      if (!savedAt || isNaN(savedAt) || savedAt <= 0) {
        return;
      }
      const age: number = Date.now() - savedAt;
      if (age < 0 || (this.config.dataExpireTtl > 0 && age > this.config.dataExpireTtl)) {
        // 顺手删掉过期快照，避免每次冷启动都白读一次
        try {
          await fs.unlink(path);
        } catch (e) {
          // 删除失败不影响流程，文件会在下次成功拉取时被覆盖
        }
        return;
      }
      // 恢复到内存
      this.nodeInfo.clear();
      const nodes: KomariClient[] = data.nodes ?? [];
      nodes.forEach((n: KomariClient): void => {
        this.nodeInfo.set(n.uuid, n);
      });
      const reports = data.reports ?? {};
      const reportKeys: string[] = Object.keys(reports);
      for (let i = 0; i < reportKeys.length; i++) {
        const uuid: string = reportKeys[i];
        this.latestReport.set(uuid, reports[uuid]);
      }
      this.nodeInfoTimestamp = savedAt;
      // 快照的数据年龄必须以写入时刻为准 —— 否则冷启动后 banner 会误报"刚刚更新"
      this.lastSuccessAt = savedAt;
    } catch (e) {
      // 文件不存在或解析失败，静默忽略，走正常网络拉取
    }
  }

  // ============================================================
  // 切换服务端时清空
  // ============================================================

  /**
   * 清空本实例的全部内存状态。
   *
   * ⚠️ 维护纪律（新增任何状态字段时必须遵守）：
   *   1. 本类新增的**任何内存字段都必须在此处一并重置** —— 否则「撤回隐私授权」
   *      （purge → clear）之后，内存里仍会残留上次成功时间、连接状态之类的痕迹。
   *   2. 新增**落盘项必须走 ServerStore.getSetting/putSetting**，由 ServerStore.clearAll()
   *      在撤回流程中统一清除。**禁止在本类自建文件或自建 preferences 实例** ——
   *      那会绕开 clearAll()，形成销毁链路的盲区（见 PrivacyRevoke.execute）。
   *   3. 新增的 AppStorage key 也要在此处归零，并登记到 AppKeys。
   */
  clear(): void {
    this.nodeInfo.clear();
    this.latestReport.clear();
    this.requestSeq.clear();
    this.appliedSeq.clear();
    this.nodeInfoTimestamp = 0;
    // 连接状态与新鲜度：属内存态，撤回授权后不得残留
    this.lastSuccessAt = 0;
    this.lastFetchFailed = false;
    if (this.snapshotTimer >= 0) {
      clearTimeout(this.snapshotTimer);
      this.snapshotTimer = -1;
    }
    // 广播通知，让所有订阅者同步清空
    this.notifyInfo();
    this.reportSubscribers.forEach((_set: Set<() => void>, uuid: string): void => {
      this.notifyReport(uuid);
    });
    this.notifyConnectivity();
  }

  /**
   * 撤回授权时使用：清空内存态 **并删除落盘快照文件**。
   * 与 clear() 的区别 —— clear() 仅清内存（切换服务端用，快照会被重写）；
   * purge() 连文件一起删，保证本机不留任何节点数据。
   * 幂等：文件不存在时静默成功。
   *
   * ⚠️ 时序安全性依赖：saveSnapshot() 的函数体必须是**全同步**的
   * （openSync / writeSync / closeSync，中间不得出现 await），
   * 这样「先 clear() 取消定时器、再 unlink」之间不存在异步插入点。
   * 若将来改为异步 fs API 或在写入前插入 await，必须先置一个 purged 标志位，
   * 让 saveSnapshot() 提前返回，否则会出现「文件删掉后又被重写」的残留。
   */
  async purge(): Promise<void> {
    this.clear();
    if (!this.context) {
      return;
    }
    try {
      await fs.unlink(this.context.filesDir + '/' + SNAPSHOT_FILENAME);
    } catch (e) {
      // 文件不存在或已删除：视为成功
    }
  }

  /**
   * 撤回授权后的销毁自检：列出 filesDir 下仍存在的文件名。
   * 只做只读列举，供 PrivacyRevoke 记日志用，不参与清理。
   * context 未注入时返回空数组（不制造假阳性）。
   */
  listResidualFiles(): string[] {
    if (!this.context) {
      return [];
    }
    try {
      return fs.listFileSync(this.context.filesDir);
    } catch (e) {
      return [];
    }
  }

  /** 落盘快照的文件名，供销毁自检比对 */
  static snapshotFileName(): string {
    return SNAPSHOT_FILENAME;
  }
}
