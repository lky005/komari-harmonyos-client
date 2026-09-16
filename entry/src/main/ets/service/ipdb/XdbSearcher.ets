/**
 * XdbSearcher —— ip2region xdb 二进制查询器（ArkTS 版，纯离线）
 *
 * 移植自官方 binding/javascript（searcher.js + util.js），只保留查询路径，
 * 剔除 fs 文件管理、IPv6 文本格式化、verify 等非必要部分。
 *
 * 数据文件：
 *   resources/rawfile/ipdb/ip2region_v4.xdb   （ipVersion=4，索引块 14 B）
 *   resources/rawfile/ipdb/ip2region_v6.xdb   （ipVersion=6，索引块 38 B）
 *   v4 / v6 是**两个独立文件**，按地址族分发，不能混用。
 *
 * ⚠️ 两个必须保留的实现细节（照顺序写会全部查不到）：
 *   1. xdb 内部一律**小端序**：头部字段、vector index、索引块里的起止 IP 与数据指针，
 *      全部按 LE 读取。
 *   2. IPv4 的索引比较必须**反向遍历**：传入的 IP 是大端字节序，而 xdb 索引块里存的是小端，
 *      所以要从 offset+3 递减比较。IPv6 相反，是正序字节比较。
 *
 * 内存策略：不做全量常驻，全部走 fd + readSync 分段读。
 *   单次查询的读次数：1 次 vector index + 约 log2(N) 次索引块（实测约 20 次）+ 1 次数据。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

const HEADER_LEN: number = 256;
const VECTOR_COLS: number = 256;
const VECTOR_SIZE: number = 8;
const MAX_INDEX_BLOCK: number = 38;      // v6 索引块最大 38 B

export class XdbSearcher {
  private fd: number = -1;
  /**
   * rawfile 在 HAP 中的起始偏移。
   * ⚠️ getRawFdSync 返回的 fd 指向**整个 HAP 包**（文档原文："rawfile 文件所在 HAP 的文件描述符"），
   * 不是 rawfile 资源本身，因此所有 readSync 的 offset 都必须加上这个基准，
   * 否则读到的是 HAP 的 ZIP 头（PK\x03\x04），魔数校验必然失败。
   */
  private base: number = 0;
  private ipVersion: number = 4;
  private ipBytes: number = 4;           // 4 或 16
  private indexSize: number = 14;        // v4 = 4+4+2+4；v6 = 16+16+2+4

  private aHdr: ArrayBuffer = new ArrayBuffer(20);
  private uHdr: Uint8Array | undefined = undefined;
  private aVec: ArrayBuffer = new ArrayBuffer(VECTOR_SIZE);
  private uVec: Uint8Array | undefined = undefined;
  private aBlk: ArrayBuffer = new ArrayBuffer(MAX_INDEX_BLOCK);
  private uBlk: Uint8Array | undefined = undefined;
  private dec: util.TextDecoder | undefined = undefined;

  private constructor(fd: number, base: number) {
    this.fd = fd;
    this.base = base;
    this.uHdr = new Uint8Array(this.aHdr);
    this.uVec = new Uint8Array(this.aVec);
    this.uBlk = new Uint8Array(this.aBlk);
    this.dec = util.TextDecoder.create('utf-8');
  }

  /**
   * 打开并校验一个 xdb。头部读取失败或魔数不符时返回 undefined，
   * 由调用方静默降级（不抛异常，避免拖垮详情页）。
   */
  static open(fd: number, base: number): XdbSearcher | undefined {
    try {
      const s: XdbSearcher = new XdbSearcher(fd, base);
      if (!s.parseHeader()) {
        return undefined;
      }
      return s;
    } catch (e) {
      return undefined;
    }
  }

  /** 头部 20 字节：version(0,u16) indexPolicy(2,u16) createdAt(4,u32) start(8,u32) end(12,u32) ipVersion(16,u16) ptrBytes(18,u16) */
  private parseHeader(): boolean {
    const n: number = fs.readSync(this.fd, this.aHdr, { offset: this.base, length: 20 });
    if (n !== 20) {
      return false;
    }
    const h: Uint8Array = this.uHdr as Uint8Array;
    const version: number = this.u16le(h, 0);
    if (version !== 2 && version !== 3) {   // 2 = 旧结构（仅 v4），3 = 当前结构
      return false;
    }
    this.ipVersion = this.u16le(h, 16);
    if (this.ipVersion === 4) {
      this.ipBytes = 4;
      this.indexSize = 14;
    } else if (this.ipVersion === 6) {
      this.ipBytes = 16;
      this.indexSize = 38;
    } else {
      return false;
    }
    return true;
  }

  getIpVersion(): number {
    return this.ipVersion;
  }

  /** 点分 IPv4 文本 → 4 字节（非法返回 undefined） */
  static parseV4(text: string): Uint8Array | undefined {
    const parts: string[] = text.split('.');
    if (parts.length !== 4) {
      return undefined;
    }
    const out: Uint8Array = new Uint8Array(4);
    for (let i = 0; i < 4; i++) {
      const v: number = Number.parseInt(parts[i], 10);
      if (Number.isNaN(v) || v < 0 || v > 255) {
        return undefined;
      }
      out[i] = v;
    }
    return out;
  }

  /**
   * IPv6 文本 → 16 字节。支持 "::" 压缩与内嵌 IPv4（如 ::ffff:1.2.3.4）。
   * 非法返回 undefined。
   */
  static parseV6(text: string): Uint8Array | undefined {
    const s: string = text.trim().toLowerCase();
    if (s.length === 0) {
      return undefined;
    }
    const dbl: number = s.indexOf('::');
    if (dbl >= 0 && s.indexOf('::', dbl + 1) >= 0) {
      return undefined;                   // 只允许一个 "::"
    }
    const head: string = dbl >= 0 ? s.substring(0, dbl) : s;
    const tail: string = dbl >= 0 ? s.substring(dbl + 2) : '';
    const headG: string[] = head.length > 0 ? head.split(':') : [];
    const tailG: string[] = tail.length > 0 ? tail.split(':') : [];

    const out: Uint8Array = new Uint8Array(16);
    let off: number = 0;
    const writeGroup = (g: string): boolean => {
      // 末组可能是内嵌 IPv4
      if (g.indexOf('.') >= 0) {
        const v4: Uint8Array | undefined = XdbSearcher.parseV4(g);
        if (v4 === undefined || off + 4 > 16) {
          return false;
        }
        out[off] = v4[0];
        out[off + 1] = v4[1];
        out[off + 2] = v4[2];
        out[off + 3] = v4[3];
        off += 4;
        return true;
      }
      if (g.length === 0 || g.length > 4 || !/^[0-9a-f]+$/.test(g)) {
        return false;
      }
      const v: number = Number.parseInt(g, 16);
      if (Number.isNaN(v) || off + 2 > 16) {
        return false;
      }
      out[off] = (v >> 8) & 0xff;
      out[off + 1] = v & 0xff;
      off += 2;
      return true;
    };

    for (let i = 0; i < headG.length; i++) {
      if (!writeGroup(headG[i])) {
        return undefined;
      }
    }
    if (dbl >= 0) {
      // 尾部各组写在末尾
      const tailBytes: number = XdbSearcher.groupsBytes(tailG);
      if (tailBytes < 0 || off + tailBytes > 16) {
        return undefined;
      }
      const tailStart: number = 16 - tailBytes;
      off = tailStart;
      for (let i = 0; i < tailG.length; i++) {
        if (!writeGroup(tailG[i])) {
          return undefined;
        }
      }
      if (off !== 16) {
        return undefined;
      }
      return out;
    }
    return off === 16 ? out : undefined;
  }

  /** 组列表占用的字节数（含内嵌 IPv4 记 4 字节）；非法返回 -1 */
  private static groupsBytes(groups: string[]): number {
    let n: number = 0;
    for (let i = 0; i < groups.length; i++) {
      const g: string = groups[i];
      if (g.indexOf('.') >= 0) {
        if (XdbSearcher.parseV4(g) === undefined) {
          return -1;
        }
        n += 4;
      } else {
        if (g.length === 0 || g.length > 4 || !/^[0-9a-f]+$/.test(g)) {
          return -1;
        }
        n += 2;
      }
    }
    return n;
  }

  /**
   * 查询。命中返回 region 字符串（形如 "中国|江苏省|南京市|0|CN"），
   * 未命中或地址族不符返回空串。
   */
  search(ipBytes: Uint8Array): string {
    if (ipBytes.length !== this.ipBytes) {
      return '';
    }
    const uVec: Uint8Array = this.uVec as Uint8Array;
    const uBlk: Uint8Array = this.uBlk as Uint8Array;

    const idx: number = ipBytes[0] * VECTOR_COLS * VECTOR_SIZE + ipBytes[1] * VECTOR_SIZE;
    if (fs.readSync(this.fd, this.aVec, { offset: this.base + HEADER_LEN + idx, length: VECTOR_SIZE }) !== VECTOR_SIZE) {
      return '';
    }
    const sPtr: number = this.u32le(uVec, 0);
    const ePtr: number = this.u32le(uVec, 4);
    if (sPtr === 0 || ePtr === 0) {
      return '';                          // 该段无数据
    }

    let lo: number = 0;
    let hi: number = Math.floor((ePtr - sPtr) / this.indexSize);
    while (lo <= hi) {
      const mid: number = (lo + hi) >> 1;
      const p: number = sPtr + mid * this.indexSize;
      if (fs.readSync(this.fd, this.aBlk, { offset: this.base + p, length: this.indexSize }) !== this.indexSize) {
        return '';
      }
      if (this.compare(ipBytes, uBlk, 0) < 0) {
        hi = mid - 1;
      } else if (this.compare(ipBytes, uBlk, this.ipBytes) > 0) {
        lo = mid + 1;
      } else {
        const dLen: number = uBlk[this.ipBytes * 2] | (uBlk[this.ipBytes * 2 + 1] << 8);
        const dPtr: number = this.u32le(uBlk, this.ipBytes * 2 + 2);
        if (dLen === 0 || dPtr === 0) {
          return '';
        }
        return this.readString(dPtr, dLen);
      }
    }
    return '';
  }

  /** 输入 IP（大端）对比索引块 offset 处的地址段；v4 反向、v6 正序 */
  private compare(ipBytes: Uint8Array, blk: Uint8Array, off: number): number {
    if (this.ipVersion === 4) {
      let j: number = off + 3;
      for (let i = 0; i < 4; i++, j--) {
        const a: number = ipBytes[i];
        const b: number = blk[j];
        if (a < b) {
          return -1;
        }
        if (a > b) {
          return 1;
        }
      }
      return 0;
    }
    for (let i = 0; i < 16; i++) {
      const a: number = ipBytes[i];
      const b: number = blk[off + i];
      if (a < b) {
        return -1;
      }
      if (a > b) {
        return 1;
      }
    }
    return 0;
  }

  private readString(off: number, len: number): string {
    if (len <= 0 || len > 4096) {
      return '';
    }
    const a: ArrayBuffer = new ArrayBuffer(len);
    if (fs.readSync(this.fd, a, { offset: this.base + off, length: len }) !== len) {
      return '';
    }
    try {
      return (this.dec as util.TextDecoder).decodeToString(new Uint8Array(a));
    } catch (e) {
      return '';
    }
  }

  private u16le(b: Uint8Array, off: number): number {
    return b[off] | (b[off + 1] << 8);
  }

  private u32le(b: Uint8Array, off: number): number {
    return (b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)) >>> 0;
  }
}
