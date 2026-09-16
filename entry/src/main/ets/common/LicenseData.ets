/**
 * LicenseData —— 开源组件与公开数据的声明数据、许可全文分块与辅助函数
 *
 * 2026-09-16 从 AboutPage 提取，供 AboutPage 与 OpenSourceLicensePage 共用。
 * 新增组件声明时只需往 COMPONENTS 数组追加一项，两个页面自动同步。
 */

import { APACHE_LICENSE_20 } from './constants/ApacheLicense20Text';

/**
 * 官方文本每行自带前导缩进（72 列硬换行）：逐行剥去缩进后，段内用空格
 * 重新拼成自然长句，交给 Text 按屏幕宽度自然换行（排版一字不动）。
 * 仅文书抬头（首块）保留换行，维持三行形式。
 */
export function flattenBlock(block: string, sep: string): string {
  return block.split('\n')
    .map((l: string): string => l.trim())
    .filter((l: string): boolean => l.length > 0)
    .join(sep)
    .replace(/ {2,}/g, ' ');
}

/** Apache-2.0 全文分块（内置离线展示；@ohos/mpchart 与 ip2region 共用） */
export const LICENSE_BLOCKS: string[] = APACHE_LICENSE_20.split('\n\n')
  .map((b: string, i: number): string => flattenBlock(b, i === 0 ? '\n' : ' '))
  .filter((b: string): boolean => b.length > 0);

/** 开源组件与公开数据声明项 */
export interface LicenseComponent {
  name: string;
  version: string;
  origin: string;
  copyright: string;
  licenseName: string;
  licenseUrl: string;
  homeUrl: string;
  /** 离线内置的协议全文分块；空数组 = 该协议不内置全文，只给官方链接 */
  licenseBlocks: string[];
}

export const COMPONENTS: LicenseComponent[] = [
  {
    name: '@ohos/mpchart',
    version: '3.0.30',
    origin: 'OpenHarmony 图表库，移植自 MPAndroidChart 3.1.0',
    copyright: 'Copyright 2020 Philipp Jahoda',
    licenseName: 'Apache License 2.0',
    licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
    homeUrl: 'https://gitcode.com/openharmony-tpc/ohos_mpchart',
    licenseBlocks: LICENSE_BLOCKS
  },
  {
    name: 'ip2region',
    version: '数据 2026-08-28',
    origin: 'IP 地理位置离线库（xdb 格式）。IPv4 与 IPv6 两套数据随应用内置：中国精确到市，海外到国家/州/市（部分 IP 缺失）',
    copyright: 'Copyright (c) 2015 Lionsoul（项目为 Apache-2.0 / MIT 双许可）',
    licenseName: 'Apache-2.0 / MIT',
    licenseUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
    homeUrl: 'https://github.com/lionsoul2014/ip2region',
    licenseBlocks: LICENSE_BLOCKS
  },
  {
    name: 'GeoLite2-ASN',
    version: '数据 2026-09-10',
    origin: 'IP 归属 ASN 与组织名离线库（mmdb 格式），单库同时覆盖 IPv4/IPv6。数据由 MaxMind 基于 BGP 等公开路由数据构建',
    copyright: 'Database and Contents Copyright (c) 2026 MaxMind, Inc.',
    licenseName: 'CC BY-SA 4.0',
    licenseUrl: 'https://creativecommons.org/licenses/by-sa/4.0/',
    homeUrl: 'https://dev.maxmind.com/geoip/geolite2-free-geolocation-data/',
    licenseBlocks: []
  },
  {
    name: 'GeoNames',
    version: '随 GeoLite2 数据分发',
    origin: 'GeoLite2 数据库中内嵌的地理名称数据，用于地域命名',
    copyright: 'Copyright GeoNames（https://www.geonames.org）',
    licenseName: 'CC BY 4.0',
    licenseUrl: 'https://creativecommons.org/licenses/by/4.0/',
    homeUrl: 'https://www.geonames.org/',
    licenseBlocks: []
  }
];

/** 仅放行 http/https 外链（拦截其余 scheme） */
export function isSafeHttpUrl(url: string): boolean {
  return url.startsWith('http://') || url.startsWith('https://');
}

/** 条款标题形如 "2. Grant of Copyright License."，与后续正文同行出现，渲染时拆开（第 1 组=标题，第 2 组=剩余正文，可为空） */
export const NUM_HEAD_RE: RegExp = /^\s*(\d+\.\s+[^.]+\.)([\s\S]*)$/;

/** 全大写的小节分隔标题（TERMS AND CONDITIONS / END OF TERMS AND CONDITIONS / APPENDIX…） */
export function isCapsHeading(block: string): boolean {
  const t: string = block.trim();
  return t === t.toUpperCase() && /[A-Z]/.test(t);
}
