/**
 * FormatUtil —— 展示层格式化
 *
 * 只放纯函数，不放业务逻辑，方便单测。
 * 单位换算统一走 1024 进制；速率类（bytes/s）用 bit/s 展示更符合习惯。
 */

export class FormatUtil {
  private static readonly UNITS: string[] = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

  /** 字节数 → 人类可读，例如 1073741824 → '1.00 GB' */
  static bytes(value: number): string {
    if (!value || value <= 0) {
      return '0 B';
    }
    let v: number = value;
    let i: number = 0;
    while (v >= 1024 && i < FormatUtil.UNITS.length - 1) {
      v = v / 1024;
      i++;
    }
    return `${v.toFixed(2)} ${FormatUtil.UNITS[i]}`;
  }

  /** 字节/秒 → 比特/秒，例如 1250000 → '10.00 Mbps' */
  static bitsPerSecond(bytesPerSec: number): string {
    const bits: number = (bytesPerSec ?? 0) * 8;
    const units: string[] = ['bps', 'Kbps', 'Mbps', 'Gbps', 'Tbps'];
    let v: number = bits;
    let i: number = 0;
    while (v >= 1000 && i < units.length - 1) {
      v = v / 1000;
      i++;
    }
    return `${v.toFixed(2)} ${units[i]}`;
  }

  /** 百分比，total 为 0 时返回 0，避免出现 NaN / Infinity */
  static percent(used: number, total: number): number {
    if (!total || total <= 0) {
      return 0;
    }
    const p: number = (used / total) * 100;
    return Math.min(100, Math.max(0, p));
  }

  /** 秒 → '3天 4小时' 这类短串，用于 uptime */
  static uptime(seconds: number): string {
    if (!seconds || seconds <= 0) {
      return '-';
    }
    const d: number = Math.floor(seconds / 86400);
    const h: number = Math.floor((seconds % 86400) / 3600);
    const m: number = Math.floor((seconds % 3600) / 60);
    if (d > 0) {
      return `${d}天 ${h}小时`;
    }
    if (h > 0) {
      return `${h}小时 ${m}分`;
    }
    return `${m}分`;
  }

  /** 距今天数，用于到期提醒；已过期返回负数 */
  static daysUntil(iso: string): number {
    if (!iso || iso.length === 0) {
      return Number.MAX_SAFE_INTEGER;
    }
    const ts: number = Date.parse(iso);
    if (isNaN(ts)) {
      return Number.MAX_SAFE_INTEGER;
    }
    return Math.floor((ts - Date.now()) / 86400000);
  }

  /** ISO 时间 → 'HH:mm:ss'，用于快照更新时刻；解析失败返回 '-' */
  static clock(iso: string): string {
    if (!iso || iso.length === 0) {
      return '-';
    }
    const ts: number = Date.parse(iso);
    if (isNaN(ts)) {
      return '-';
    }
    const d: Date = new Date(ts);
    const pad = (n: number): string => {
      return n < 10 ? `0${n}` : `${n}`;
    };
    return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  /** ISO 时间 → 'YYYY-MM-DD'，用于到期日展示；解析失败返回 '-' */
  static shortDate(iso: string): string {
    if (!iso || iso.length === 0) {
      return '-';
    }
    const ts: number = Date.parse(iso);
    if (isNaN(ts)) {
      return '-';
    }
    const d: Date = new Date(ts);
    const pad = (n: number): string => {
      return n < 10 ? `0${n}` : `${n}`;
    };
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  /**
   * Ping 延迟（毫秒）。服务端统计字段是 *float64 + omitempty，
   * 运行时可能传入 undefined/null（声明为 number 也会发生），统一在这里兜底。
   */
  static ms(v: number | undefined): string {
    if (v === undefined || v === null || isNaN(v)) {
      return '-';
    }
    return `${v.toFixed(1)} ms`;
  }
}
