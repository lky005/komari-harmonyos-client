/**
 * IpInfoService —— 节点公网 IP 的归属地 / ISP / ASN 查询（**纯离线**）
 *
 * 数据源（三个二进制库，随 HAP 打包，放 resources/rawfile/ipdb/）：
 *   1. ip2region_v4.xdb     地理：中国到市、海外到国家/州/市（不稳定），含 ISP   Apache-2.0
 *   2. ip2region_v6.xdb     同上，IPv6 专用                                     Apache-2.0
 *   3. GeoLite2-ASN.mmdb    ASN 号 + 组织全称，单文件同时覆盖 v4/v6             CC BY-SA 4.0
 *
 * 与旧实现的差异：
 *   - 旧版走 api.ip.sb → ipwho.is → ipinfo.io 三级在线回退，只出 {asn, org}，无地理位置，
 *     并且为了保护隐私做了"私网不外发"判断 + 7 天缓存 + 负缓存 + inflight 合并 + 竞态淘汰。
 *   - 离线版不再有任何网络请求，上述缓存与竞态机制全部删除（本地查表微秒级，缓存是纯负担），
 *     `query()` 是**同步**的，页面进页即可拿到结果，无加载态、无时序问题。
 *
 * 隐私与安全约束（改前必读）：
 *   - IP 不再外发给任何第三方；`isPublicIp()` 的作用从"防外发"变为
 *     "避免对私网/打码地址做无意义查表"，并用于给出"局域网/保留地址"的展示文案。
 *   - 服务端打码 IP（如 1.*.*.*）不是合法 IP，格式校验天然拦截。
 *
 * 资源生命周期：三个 fd 在 init 时打开并常驻（不调 closeRawFdSync），
 * 因为查询会反复发生，且常驻仅占 fd 本身的开销（库数据按需分段读，不整包进内存）。
 *
 * 署名要求（关于页需展示）：MaxMind GeoLite2 + GeoNames（CC BY 4.0）+ ip2region（Apache-2.0）。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { XdbSearcher } from './ipdb/XdbSearcher';
import { AsnRecord, MmdbReader } from './ipdb/MmdbReader';

const DOMAIN: number = 0x0001;
const TAG: string = 'IpInfoService';

const RAW_V4: string = 'ipdb/ip2region_v4.xdb';
const RAW_V6: string = 'ipdb/ip2region_v6.xdb';
const RAW_ASN: string = 'ipdb/GeoLite2-ASN.mmdb';

/** 查询结果。字符串字段用空串表示"未知"，不做 undefined 传播。 */
export interface IpGeoResult {
  isPublic: boolean;
  country: string;      // "中国" / "United States"
  province: string;     // "江苏省"（中国），海外可能为空或 "California"
  city: string;         // "南京市"
  isp: string;          // 中国为运营商（"电信"），海外多为组织名，可能为空
  asn: number;          // 0 = 未知
  asOrg: string;        // "Cloudflare, Inc."
  regionText: string;   // 纯地理部分："江苏省 南京市" / "United States California"
  displayText: string;  // 详情页直出文案（地理 + 组织 + ASN）
}

export class IpInfoService {
  private static v4: XdbSearcher | undefined = undefined;
  private static v6: XdbSearcher | undefined = undefined;
  private static asn: MmdbReader | undefined = undefined;
  private static inited: boolean = false;

  /**
   * 在 EntryAbility.onCreate 里调用一次（同步，不阻塞启动）。
   * 库文件缺失或损坏时不抛异常，查询会静默降级为"未知"。
   */
  static init(ctx: common.UIAbilityContext): void {
    if (IpInfoService.inited) {
      return;
    }
    IpInfoService.inited = true;
    const rm = ctx.resourceManager;
    // 注意：getRawFdSync 拿到的是 rawfile 所在 **HAP** 的 fd 与该资源在 HAP 内的
    // offset/length，读数据时必须用 offset 作为基准（见 XdbSearcher.base 注释）。
    let o4: number = -1;
    let l4: number = -1;
    let o6: number = -1;
    let l6: number = -1;
    let oa: number = -1;
    let la: number = -1;
    try {
      const d4 = rm.getRawFdSync(RAW_V4);
      o4 = d4.offset;
      l4 = d4.length;
      IpInfoService.v4 = XdbSearcher.open(d4.fd, d4.offset);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'open v4 xdb failed: %{public}s', JSON.stringify(e));
    }
    try {
      const d6 = rm.getRawFdSync(RAW_V6);
      o6 = d6.offset;
      l6 = d6.length;
      IpInfoService.v6 = XdbSearcher.open(d6.fd, d6.offset);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'open v6 xdb failed: %{public}s', JSON.stringify(e));
    }
    try {
      const dm = rm.getRawFdSync(RAW_ASN);
      oa = dm.offset;
      la = dm.length;
      IpInfoService.asn = MmdbReader.open(dm.fd, dm.length, dm.offset);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'open asn mmdb failed: %{public}s', JSON.stringify(e));
    }
    hilog.info(DOMAIN, TAG, 'offline ip db ready: v4=%{public}s v6=%{public}s asn=%{public}s',
      `${IpInfoService.v4 !== undefined}`,
      `${IpInfoService.v6 !== undefined}`,
      `${IpInfoService.asn !== undefined}`);
    hilog.info(DOMAIN, TAG, 'rawfile offset/len: v4=%{public}d/%{public}d v6=%{public}d/%{public}d asn=%{public}d/%{public}d',
      o4, l4, o6, l6, oa, la);
  }

  /** 库是否至少部分可用（供 UI 决定是否隐藏该区域） */
  static isReady(): boolean {
    return IpInfoService.v4 !== undefined || IpInfoService.v6 !== undefined
      || IpInfoService.asn !== undefined;
  }

  /**
   * 同步查询。任何异常路径都返回结构完整的"未知"结果，不抛异常。
   * 调用方若传入打码/私网/非法地址，得到的是 isPublic=false 的结果。
   */
  static query(ipText: string): IpGeoResult {
    const s: string = ipText.trim();
    if (!IpInfoService.isPublicIp(s)) {
      return IpInfoService.blank(false, '局域网 / 保留地址');
    }

    let bytes: Uint8Array | undefined = undefined;
    let isV4: boolean = true;
    if (s.indexOf('.') >= 0) {
      bytes = XdbSearcher.parseV4(s);
      isV4 = true;
    } else {
      bytes = XdbSearcher.parseV6(s);
      isV4 = false;
    }
    if (bytes === undefined) {
      return IpInfoService.blank(false, '地址格式异常');
    }

    // ---- 地理（ip2region，按地址族选库）----
    let country: string = '';
    let province: string = '';
    let city: string = '';
    let isp: string = '';
    const searcher: XdbSearcher | undefined = isV4 ? IpInfoService.v4 : IpInfoService.v6;
    if (searcher !== undefined) {
      const region: string = searcher.search(bytes);
      if (region.length > 0) {
        // 字段格式：国家|省|市|ISP|iso-alpha2-code
        // 注意最后一段是国家代码（CN/US），"0" 是各字段缺失时的占位符
        const f: string[] = region.split('|');
        country = IpInfoService.dash(f, 0);
        province = IpInfoService.dash(f, 1);
        city = IpInfoService.dash(f, 2);
        isp = IpInfoService.dash(f, 3);
      }
    }

    // ---- ASN（GeoLite2-ASN，单文件覆盖 v4/v6）----
    let asn: number = 0;
    let asOrg: string = '';
    if (IpInfoService.asn !== undefined) {
      const r: AsnRecord = IpInfoService.asn.lookup(bytes);
      if (r.found) {
        asn = r.asn;
        asOrg = r.org;
      }
    }

    const regionText: string = IpInfoService.buildRegion(country, province, city);
    return {
      isPublic: true,
      country,
      province,
      city,
      isp,
      asn,
      asOrg,
      regionText,
      displayText: IpInfoService.buildText(regionText, isp, asn, asOrg)
    };
  }

  /**
   * 拼装展示文案。
   *   国内：`江苏省 南京市 · 电信 · AS4134`   （国家"中国"对国内用户冗余，省略）
   *   海外：`United States California · Google LLC · AS15169`
   * 地域名保留 xdb 原文（带"省/市"行政单位），不做后缀裁剪 —— 裁剪规则涉及
   * 自治区/自治州/特别行政区等特例，容易误伤，信息完整优于短。
   */
  private static buildRegion(country: string, province: string, city: string): string {
    const geo: string[] = [];
    if (country.length > 0 && country !== '中国') {
      geo.push(country);                   // 国家"中国"对国内用户冗余，省略
    }
    if (province.length > 0) {
      geo.push(province);
    }
    if (city.length > 0) {
      geo.push(city);
    }
    return geo.join(' ');
  }

  private static buildText(regionText: string, isp: string, asn: number, asOrg: string): string {
    const org: string = asOrg.length > 0 ? asOrg : isp;
    const parts: string[] = [];
    if (regionText.length > 0) {
      parts.push(regionText);
    }
    if (org.length > 0) {
      parts.push(org);
    }
    if (asn > 0) {
      parts.push(`AS${asn}`);
    }
    return parts.length > 0 ? parts.join(' · ') : '未知';
  }

  private static dash(f: string[], i: number): string {
    if (i >= f.length) {
      return '';
    }
    const v: string = f[i];
    return (v.length === 0 || v === '0') ? '' : v;
  }

  private static blank(isPublic: boolean, text: string): IpGeoResult {
    return {
      isPublic,
      country: '',
      province: '',
      city: '',
      isp: '',
      asn: 0,
      asOrg: '',
      regionText: '',
      displayText: text
    };
  }

  /**
   * 合法公网 IP 判定。私网/环回/链路本地/CGNAT/组播/保留/文档段一律 false，
   * 打码 IP（含 * 或段缺失）天然不过格式校验。
   * 离线化后此判定不再承担"防止外发"职责，只用于跳过无意义的本地查表并给出局域网文案。
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
