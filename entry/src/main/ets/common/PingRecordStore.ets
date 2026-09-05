/**
 * PingRecordStore —— Ping 详情原始记录的进程内缓存（stale-while-revalidate）
 *
 * 只被 PingDetailPage 引用，与节点/列表页数据完全隔离：
 *   1. 键 = serverId|uuid|taskId|hours，且读写都以「写入时刻的活动服务端」校验，
 *      切换服务端后旧条目天然不可见（与 NodeDataStore.loadSnapshot 的 serverId 防污染同一思路）
 *   2. 仅内存、不落盘：ping 记录是 24h 滚动窗口，时效性强，跨启动没有回放价值
 *   3. 容量上限 LRU 淘汰，任务×范围组合再多内存也有界
 *   4. 新鲜度（TTL）由设置页「刷新与性能 → Ping 详情缓存」控制
 *      （NodeDataStore.PollConfig.pingCacheTtl），0 = 关闭缓存
 */

import { PingRecordItem } from '../model/KomariTypes';
import { ServiceRegistry } from './ServiceRegistry';

/** 缓存条目上限（任务×范围组合数），单条 24h 记录约几十 KB */
const MAX_ENTRIES: number = 16;

/** 缓存命中结果：records 为原始记录（未清洗），ageMs 为距写入的毫秒数 */
export interface PingCacheHit {
  records: PingRecordItem[];
  ageMs: number;
}

interface PingCacheEntry {
  serverId: string;
  records: PingRecordItem[];
  fetchedAt: number;
}

export class PingRecordStore {
  private static instance: PingRecordStore | undefined = undefined;
  private entries: Map<string, PingCacheEntry> = new Map();

  static getInstance(): PingRecordStore {
    if (!PingRecordStore.instance) {
      PingRecordStore.instance = new PingRecordStore();
    }
    return PingRecordStore.instance;
  }

  private currentServerId(): string {
    try {
      const cfg = ServiceRegistry.getActiveConfig();
      return cfg ? cfg.id : '';
    } catch (e) {
      return '';
    }
  }

  /** 命中且服务端一致返回记录与年龄；切换服务端后旧条目直接不可见 */
  lookup(uuid: string, taskId: number, hours: number): PingCacheHit | undefined {
    const serverId: string = this.currentServerId();
    const entry: PingCacheEntry | undefined =
      this.entries.get(`${serverId}|${uuid}|${taskId}|${hours}`);
    if (!entry || entry.serverId !== serverId) {
      return undefined;
    }
    const hit: PingCacheHit = {
      records: entry.records,
      ageMs: Date.now() - entry.fetchedAt
    };
    return hit;
  }

  /** 写入并按 LRU 淘汰超限条目；serverId 以写入时刻的活动服务端为准 */
  put(uuid: string, taskId: number, hours: number, records: PingRecordItem[]): void {
    const serverId: string = this.currentServerId();
    if (serverId.length === 0) {
      return;
    }
    const key: string = `${serverId}|${uuid}|${taskId}|${hours}`;
    // 先删再插，让最近使用的条目排到队尾
    this.entries.delete(key);
    const keys: string[] = Array.from(this.entries.keys());
    if (keys.length >= MAX_ENTRIES) {
      const toEvict: number = keys.length - MAX_ENTRIES + 1;
      for (let i = 0; i < toEvict; i++) {
        this.entries.delete(keys[i]);
      }
    }
    const entry: PingCacheEntry = {
      serverId: serverId,
      records: records,
      fetchedAt: Date.now()
    };
    this.entries.set(key, entry);
  }

  /** 手动清空；服务端切换场景靠 lookup 的 serverId 校验自然失效，暂无调用方 */
  clear(): void {
    this.entries.clear();
  }
}
