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
  pingCacheTtl: 5 * 60 * 1000
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
    pingCacheTtl: DEFAULT_CONFIG.pingCacheTtl
  };
  private limiter: ConcurrencyLimiter = new ConcurrencyLimiter(DEFAULT_CONFIG.maxConcurrent);

  // ===== 前后台与网络状态 =====
  private foreground: boolean = true;
  private networkAvailable: boolean = true;

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
    } catch (e) {
      // 写入失败不影响内存中的配置
    }
    this.configSubscribers.forEach((cb: () => void): void => {
      try { cb(); } catch (e) { /* 忽略 */ }
    });
  }

  getConfig(): PollConfig {
    return {
      listInterval: this.config.listInterval,
      detailInterval: this.config.detailInterval,
      maxConcurrent: this.config.maxConcurrent,
      pingCacheTtl: this.config.pingCacheTtl
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

  /** 网络恢复时调用：清空排队任务 + 通知配置订阅者（页面可主动对齐） */
  onNetworkRestore(): void {
    this.networkAvailable = true;
    this.limiter.clearQueue();
    // 通知配置订阅者，让页面触发一次立即对齐
    this.configSubscribers.forEach((cb: () => void): void => {
      try { cb(); } catch (e) { /* 忽略 */ }
    });
  }

  onNetworkLost(): void {
    this.networkAvailable = false;
  }

  // ============================================================
  // 数据拉取
  // ============================================================

  async fetchNodeInfo(force: boolean = false): Promise<void> {
    const now: number = Date.now();
    if (!force && this.nodeInfo.size > 0 && now - this.nodeInfoTimestamp < STATIC_CACHE_TTL) {
      return;
    }
    if (!ServiceRegistry.getActiveConfig() || !this.networkAvailable) {
      return;
    }
    try {
      const nodes: KomariClient[] = await ServiceRegistry.getApi().getNodes();
      this.nodeInfo.clear();
      nodes.forEach((n: KomariClient): void => {
        this.nodeInfo.set(n.uuid, n);
      });
      this.nodeInfoTimestamp = now;
      this.notifyInfo();
      this.scheduleSnapshotSave();
    } catch (e) {
      // 拉取失败保留旧缓存，不抛出
    }
  }

  async fetchReport(uuid: string): Promise<void> {
    if (!ServiceRegistry.getActiveConfig() || !this.networkAvailable) {
      return;
    }
    const seq: number = (this.requestSeq.get(uuid) ?? 0) + 1;
    this.requestSeq.set(uuid, seq);

    try {
      const list: ClientReport[] = await ServiceRegistry.getApi().getClientRecentRecords(uuid);

      // 校验1：旧请求直接丢弃（迟到的响应）
      const applied: number = this.appliedSeq.get(uuid) ?? 0;
      if (seq < applied) {
        return;
      }

      if (!list || list.length === 0) {
        return;
      }
      const report: ClientReport = list[list.length - 1];

      // 校验2：数据时间戳倒退也丢弃（服务端采集时序异常）
      const existing: ClientReport | undefined = this.latestReport.get(uuid);
      if (existing && existing.updated_at && report.updated_at) {
        try {
          if (Date.parse(report.updated_at) < Date.parse(existing.updated_at)) {
            return;
          }
        } catch (e) {
          // 时间戳解析失败时跳过该校验
        }
      }

      this.latestReport.set(uuid, report);
      this.appliedSeq.set(uuid, seq);
      this.notifyReport(uuid);
      this.scheduleSnapshotSave();
    } catch (e) {
      // 请求失败不更新 seq，下次重试
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

  /** 冷启动时加载快照：serverId 不匹配则不加载，防止多服务端数据污染 */
  async loadSnapshot(serverId: string): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      const path: string = this.context.filesDir + '/' + SNAPSHOT_FILENAME;
      const json: string = fs.readTextSync(path);
      const data = JSON.parse(json) as SnapshotData;
      if (data.serverId !== serverId) {
        return;
      }
      // 恢复到内存
      this.nodeInfo.clear();
      data.nodes.forEach((n: KomariClient): void => {
        this.nodeInfo.set(n.uuid, n);
      });
      const reportKeys: string[] = Object.keys(data.reports);
      for (let i = 0; i < reportKeys.length; i++) {
        const uuid: string = reportKeys[i];
        this.latestReport.set(uuid, data.reports[uuid]);
      }
      this.nodeInfoTimestamp = data.savedAt;
    } catch (e) {
      // 文件不存在或解析失败，静默忽略，走正常网络拉取
    }
  }

  // ============================================================
  // 切换服务端时清空
  // ============================================================

  clear(): void {
    this.nodeInfo.clear();
    this.latestReport.clear();
    this.requestSeq.clear();
    this.appliedSeq.clear();
    this.nodeInfoTimestamp = 0;
    if (this.snapshotTimer >= 0) {
      clearTimeout(this.snapshotTimer);
      this.snapshotTimer = -1;
    }
    // 广播通知，让所有订阅者同步清空
    this.notifyInfo();
    this.reportSubscribers.forEach((_set: Set<() => void>, uuid: string): void => {
      this.notifyReport(uuid);
    });
  }

  /**
   * 撤回授权时使用：清空内存态 **并删除落盘快照文件**。
   * 与 clear() 的区别 —— clear() 仅清内存（切换服务端用，快照会被重写）；
   * purge() 连文件一起删，保证本机不留任何节点数据。
   * 幂等：文件不存在时静默成功。
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
}
