/**
 * NodeUtil —— 节点在线判定与快照取值
 *
 * 在线判定依据（与 Komari Web 端行为对齐）：
 *   1. 没有任何快照 → 离线
 *   2. 快照 message 非空 → 离线（agent 会写明离线原因）
 *   3. updated_at 距今超过阈值 → 视为离线（agent 正常几秒上报一次，
 *      网络抖动可能延迟，阈值放宽到 90 秒避免误报）
 */

import { ClientReport, KomariClient } from '../model/KomariTypes';

export class NodeUtil {
  /** updated_at 超过该毫秒数视为陈旧 */
  static readonly STALE_MS: number = 90 * 1000;

  static isOnline(report: ClientReport | undefined): boolean {
    if (!report) {
      return false;
    }
    if (report.message && report.message.length > 0) {
      return false;
    }
    const ts: number = Date.parse(report.updated_at);
    if (isNaN(ts)) {
      return false;
    }
    return Date.now() - ts < NodeUtil.STALE_MS;
  }

  /** 快照取值：cpu.usage，无快照返回 -1 */
  static cpuUsage(report: ClientReport | undefined): number {
    if (!report || !report.cpu) {
      return -1;
    }
    return report.cpu.usage ?? 0;
  }

  /** 内存使用率 0~100，无快照返回 -1 */
  static memPercent(report: ClientReport | undefined): number {
    if (!report || !report.ram || !report.ram.total) {
      return -1;
    }
    return Math.min(100, Math.max(0, (report.ram.used / report.ram.total) * 100));
  }

  /** 磁盘使用率 0~100，无快照返回 -1 */
  static diskPercent(report: ClientReport | undefined): number {
    if (!report || !report.disk || !report.disk.total) {
      return -1;
    }
    return Math.min(100, Math.max(0, (report.disk.used / report.disk.total) * 100));
  }

  /** tags 'a;b;c' → 数组，空串返回空数组 */
  static tagList(tags: string): string[] {
    if (!tags || tags.length === 0) {
      return [];
    }
    return tags.split(';').filter((t: string): boolean => t.trim().length > 0);
  }
}
