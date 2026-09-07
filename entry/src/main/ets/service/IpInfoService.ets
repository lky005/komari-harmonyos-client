/**
 * IpInfoService —— 节点公网 IP 的 ASN / 厂商（ISP/组织名）在线查询
 *
 * 数据源（免费、无需 key，按序回退；https-only，主机为固定白名单常量，不可配置）：
 *   1. api.ip.sb    /geoip/{ip}   → asn / asn_organization / isp / organization
 *   2. ipwho.is     /{ip}         → connection.asn / isp / org
 *   3. ipinfo.io    /{ip}/json    → org = "AS#### 组织名"（解析拆分）
 *
 * 隐私与安全约束（改前必读）：
 *   - 只接受格式合法的公网 IP；私网/环回/链路本地/保留段一律不发起任何请求，
 *     避免把内网拓扑泄露给第三方
 *   - 服务端打码 IP（如 1.*.*.*）不是合法 IP，格式校验天然拦截
 *   - 查询结果进程内缓存：正缓存 7 天 / 负缓存 1 小时，同 IP 在途请求合并，
 *     避免频繁进出详情页造成重复外发
 *
 * 已知坑：任一 provider 字段都是可选的（omitempty / 免费源偶发缺字段），取值前逐级判空。
 */

import { http } from '@kit.NetworkKit';
import { bundleManager } from '@kit.AbilityKit';

/** 查询结果：两者都可能为空串（未知），渲染层用 '—' 兜底 */
export interface IpGeoInfo {
  asn: string;
  org: string;
}

/** api.ip.sb /geoip 响应（字段按需声明，缺失即 undefined） */
interface IpSbResp {
  asn?: number;
  asn_organization?: string;
  isp?: string;
  organization?: string;
}

/** ipwho.is 响应 */
interface IpWhoConn {
  asn?: number;
  org?: string;
  isp?: string;
}

interface IpWhoResp {
  success?: boolean;
  connection?: IpWhoConn;
}

/** ipinfo.io 响应：org 形如 "AS13335 Cloudflare, Inc." */
interface IpInfoResp {
  org?: string;
}

/** org 字段里 "AS#### 名称" 的拆分（第 1 组=AS 号，第 2 组=名称） */
const IPINFO_ORG_RE: RegExp = /^(AS\d+)\s+(.+)$/;

const CACHE_TTL_MS: number = 7 * 24 * 60 * 60 * 1000;
const NEGATIVE_TTL_MS: number = 60 * 60 * 1000;
const TIMEOUT_MS: number = 5000;

interface CacheEntry {
  info: IpGeoInfo;
  at: number;
  negative: boolean;
}

export class IpInfoService {
  private static cache: Map<string, CacheEntry> = new Map();
  /** 同 IP 在途请求合并，避免并发重复外发 */
  private static inflight: Map<string, Promise<IpGeoInfo>> = new Map();

  private static readonly UNKNOWN: IpGeoInfo = { asn: '', org: '' };

  /**
   * 查询 IP 的 ASN 与厂商名。任何失败（不合法 IP / 私网 / 全部 provider 失败）
   * 都返回 { asn:'', org:'' }，不抛异常。
   */
  static async lookup(ip: string): Promise<IpGeoInfo> {
    if (!IpInfoService.isPublicIp(ip)) {
      return IpInfoService.UNKNOWN;
    }
    const cached: CacheEntry | undefined = IpInfoService.cache.get(ip);
    if (cached) {
      const ttl: number = cached.negative ? NEGATIVE_TTL_MS : CACHE_TTL_MS;
      if (Date.now() - cached.at <= ttl) {
        return cached.info;
      }
      IpInfoService.cache.delete(ip);
    }
    const pending: Promise<IpGeoInfo> | undefined = IpInfoService.inflight.get(ip);
    if (pending) {
      return await pending;
    }
    const task: Promise<IpGeoInfo> = IpInfoService.queryAll(ip)
      .then((info: IpGeoInfo): IpGeoInfo => {
        const hasResult: boolean = info.asn.length > 0 || info.org.length > 0;
        IpInfoService.cache.set(ip, { info: info, at: Date.now(), negative: !hasResult });
        IpInfoService.inflight.delete(ip);
        return info;
      })
      .catch((_e: Object): IpGeoInfo => {
        // 全部源失败也记负缓存，短时间内不再打扰
        IpInfoService.cache.set(ip, { info: IpInfoService.UNKNOWN, at: Date.now(), negative: true });
        IpInfoService.inflight.delete(ip);
        return IpInfoService.UNKNOWN;
      });
    IpInfoService.inflight.set(ip, task);
    return await task;
  }

  /** 依次尝试全部 provider，取第一个拿到 asn 或 org 的结果 */
  private static async queryAll(ip: string): Promise<IpGeoInfo> {
    const providers: Array<(ip: string) => Promise<IpGeoInfo>> = [
      IpInfoService.queryIpSb,
      IpInfoService.queryIpWho,
      IpInfoService.queryIpInfo
    ];
    for (const p of providers) {
      try {
        const info: IpGeoInfo = await p(ip);
        if (info.asn.length > 0 || info.org.length > 0) {
          return info;
        }
      } catch (e) {
        // 单个源失败继续下一个
      }
    }
    return IpInfoService.UNKNOWN;
  }

  private static async queryIpSb(ip: string): Promise<IpGeoInfo> {
    const raw: string = await IpInfoService.getText(`https://api.ip.sb/geoip/${ip}`);
    const r = JSON.parse(raw) as IpSbResp;
    const asn: string = r.asn !== undefined && r.asn !== null ? `AS${r.asn}` : '';
    const org: string = r.asn_organization ?? r.isp ?? r.organization ?? '';
    return { asn: asn, org: org };
  }

  private static async queryIpWho(ip: string): Promise<IpGeoInfo> {
    const raw: string = await IpInfoService.getText(`https://ipwho.is/${ip}`);
    const r = JSON.parse(raw) as IpWhoResp;
    if (!r.connection) {
      return IpInfoService.UNKNOWN;
    }
    const asn: string = r.connection.asn !== undefined && r.connection.asn !== null ? `AS${r.connection.asn}` : '';
    const org: string = r.connection.isp ?? r.connection.org ?? '';
    return { asn: asn, org: org };
  }

  private static async queryIpInfo(ip: string): Promise<IpGeoInfo> {
    const raw: string = await IpInfoService.getText(`https://ipinfo.io/${ip}/json`);
    const r = JSON.parse(raw) as IpInfoResp;
    const org: string = r.org ?? '';
    if (org.length === 0) {
      return IpInfoService.UNKNOWN;
    }
    const m: RegExpExecArray | null = IPINFO_ORG_RE.exec(org);
    if (m !== null) {
      return { asn: m[1], org: m[2] };
    }
    return { asn: '', org: org };
  }

  /** GET JSON 文本；仅 https；固定白名单主机在调用点拼死，不接受外部传入 URL */
  private static async getText(url: string): Promise<string> {
    if (!url.startsWith('https://')) {
      throw new Error('non-https url rejected');
    }
    const req = http.createHttp();
    try {
      const res = await req.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'accept': 'application/json',
          'User-Agent': IpInfoService.userAgent()
        },
        connectTimeout: TIMEOUT_MS,
        readTimeout: TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      if (res.responseCode < 200 || res.responseCode >= 300) {
        throw new Error(`HTTP ${res.responseCode}`);
      }
      return typeof res.result === 'string' ? res.result : '';
    } finally {
      req.destroy();
    }
  }

  /** User-Agent 随包版本号走（LKMonitor/{versionName}），读不到包信息时退化为裸产品名 */
  private static userAgent(): string {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return `LKMonitor/${info.versionName}`;
    } catch (e) {
      return 'LKMonitor';
    }
  }

  /**
   * 合法公网 IP 判定。私网/环回/链路本地/CGNAT/组播/保留/文档段一律 false，
   * 打码 IP（含 * 或段缺失）天然不过格式校验。
   */
  static isPublicIp(ip: string): boolean {
    const s: string = ip.trim();
    if (s.length === 0) {
      return false;
    }
    if (s.indexOf('.') >= 0) {
      return IpInfoService.isPublicV4(s);
    }
    if (s.indexOf(':') >= 0) {
      return IpInfoService.isPublicV6(s);
    }
    return false;
  }

  private static isPublicV4(s: string): boolean {
    const m: RegExpExecArray | null = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s);
    if (m === null) {
      return false;
    }
    const o: number[] = [parseInt(m[1]), parseInt(m[2]), parseInt(m[3]), parseInt(m[4])];
    for (const n of o) {
      if (isNaN(n) || n > 255) {
        return false;
      }
    }
    const a: number = o[0];
    const b: number = o[1];
    if (a === 0 || a === 10 || a === 127) {
      return false;                        // 本网络 / 私网 / 环回
    }
    if (a === 172 && b >= 16 && b <= 31) {
      return false;                        // 私网
    }
    if (a === 192 && b === 168) {
      return false;                        // 私网
    }
    if (a === 169 && b === 254) {
      return false;                        // 链路本地
    }
    if (a === 100 && b >= 64 && b <= 127) {
      return false;                        // CGNAT
    }
    if (a === 198 && (b === 18 || b === 19)) {
      return false;                        // 基准测试保留
    }
    if (a >= 224) {
      return false;                        // 组播 + 保留
    }
    return true;
  }

  private static isPublicV6(s: string): boolean {
    const v: string = s.toLowerCase();
    if (!/^[0-9a-f:]+$/.test(v)) {
      return false;                        // 只允许十六进制与冒号（拦截打码星号等）
    }
    if (v === '::' || v === '::1') {
      return false;                        // 未指定 / 环回
    }
    if (v.startsWith('fc') || v.startsWith('fd')) {
      return false;                        // ULA 私网 fc00::/7
    }
    if (/^fe[89ab]/.test(v)) {
      return false;                        // 链路本地 fe80::/10
    }
    if (v.startsWith('ff')) {
      return false;                        // 组播 ff00::/8
    }
    if (v.startsWith('2001:db8')) {
      return false;                        // 文档保留段
    }
    // 形态粗校验：至少要有一个双冒号或足够多的段，避免 "1:2" 之类的残串外发
    const groups: number = v.split(':').filter((g: string): boolean => g.length > 0).length;
    const hasDoubleColon: boolean = v.indexOf('::') >= 0;
    if (!hasDoubleColon && groups !== 8) {
      return false;
    }
    if (hasDoubleColon && groups > 7) {
      return false;
    }
    return true;
  }
}
