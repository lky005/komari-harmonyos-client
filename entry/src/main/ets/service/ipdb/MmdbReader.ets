/**
 * MmdbReader —— MaxMind DB (.mmdb) 精简读取器，专供 GeoLite2-ASN 的离线查询
 *
 * 为什么是"精简版"：GeoLite2-ASN 的 record 只有两个固定字段
 *   autonomous_system_number        (uint32)
 *   autonomous_system_organization  (utf-8 string)
 * 所以不必实现 City 库那套经纬度、多语言字典映射。但以下三块必须完整实现，
 * 缺一不可（官方规范 maxmind.github.io/MaxMind-DB）：
 *   - metadata 定位：文件尾部搜 marker 的**最后一次**出现，metadata ≤ 128 KiB
 *   - search tree 遍历：record_size 有 6 / 7 / 8 字节三种，7 字节时中间字节要拆 4+4
 *   - 数据段解码：pointer 4 种宽度、map / uint / string / boolean
 *
 * ⚠️ 两个实测踩到的坑（本文件已按此实现，改动前务必读）：
 *   1. uint 的字节宽度由 size 字段决定，**不是固定 2/4 字节**。
 *      GeoLite2-ASN 的 metadata 里 binary_format_major_version 编码为 `a1 02`（1 字节）。
 *      按"uint16 固定 2 字节"解析会立刻错位，之后读到的全是非法类型号。
 *   2. pointer 基址是分离的：
 *      - 搜索树叶子给出的数据指针 -> 文件偏移 = (node - node_count) + search_tree_bytes（**不加 16**）
 *      - 数据段内部的 pointer  -> 文件偏移 = pointer_value + (search_tree_bytes + 16)
 *      - metadata 内部解码时基址为 0（pointer 值本身就是绝对偏移）
 *
 * 字节序：mmdb 全程**大端**。
 * 地址族：单个 mmdb 同时支持 v4 / v6 —— IPv4 走 IPv6 树中高 96 位全 0 的那条路径。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

const MARKER: Uint8Array = new Uint8Array([
  0xab, 0xcd, 0xef, 0x4d, 0x61, 0x78, 0x4d, 0x69, 0x6e, 0x64, 0x2e, 0x63, 0x6f, 0x6d
]);
const META_MAX: number = 131072;          // metadata 段最大 128 KiB
// 整树常驻上限。GeoLite2-ASN 的树约 9.5 MB，命中后查询变成纯内存操作，
// 免去每次查询上百次 readSync；超过该值则退回 fd 分段读。
const TREE_CACHE_LIMIT: number = 16 * 1024 * 1024;
const SCRATCH_LEN: number = 8;            // 控制字节 + 类型字节 + 最多 3 长度字节

/** 查询结果；found=false 表示该 IP 在库中无记录 */
export interface AsnRecord {
  found: boolean;
  asn: number;
  org: string;
}

interface CtrlInfo {
  type: number;
  size: number;
  next: number;      // 值数据起始的绝对偏移
}

interface StrVal {
  s: string;
  next: number;
}

interface UintVal {
  v: number;
  next: number;
}

export class MmdbReader {
  private fd: number = -1;
  private fileSize: number = 0;
  /**
   * rawfile 在 HAP 中的起始偏移。
   * ⚠️ getRawFdSync 返回的 fd 指向**整个 HAP**，不是 rawfile 资源本身，
   * 所有 readSync 的 offset 都要加上它（详见 XdbSearcher 中的同名字段注释）。
   */
  private base: number = 0;

  private nodeCount: number = 0;
  private recordSize: number = 24;
  private nodeBytes: number = 6;
  private treeBytes: number = 0;
  private dataBase: number = 0;

  private aNode: ArrayBuffer = new ArrayBuffer(8);
  private uNode: Uint8Array | undefined = undefined;
  private aScratch: ArrayBuffer = new ArrayBuffer(SCRATCH_LEN);
  private uScratch: Uint8Array | undefined = undefined;
  private aPtr: ArrayBuffer = new ArrayBuffer(4);
  private uPtr: Uint8Array | undefined = undefined;
  /** search tree 整体常驻（小库用），为 undefined 时走 fd 分段读 */
  private tree: Uint8Array | undefined = undefined;
  private dec: util.TextDecoder | undefined = undefined;

  private constructor(fd: number, size: number, base: number) {
    this.fd = fd;
    this.fileSize = size;
    this.base = base;
    this.uNode = new Uint8Array(this.aNode);
    this.uScratch = new Uint8Array(this.aScratch);
    this.uPtr = new Uint8Array(this.aPtr);
    this.dec = util.TextDecoder.create('utf-8');
  }

  static open(fd: number, size: number, base: number): MmdbReader | undefined {
    try {
      const r: MmdbReader = new MmdbReader(fd, size, base);
      if (!r.parseMetadata()) {
        return undefined;
      }
      return r;
    } catch (e) {
      return undefined;
    }
  }

  getNodeCount(): number {
    return this.nodeCount;
  }

  getRecordSize(): number {
    return this.recordSize;
  }


  // ==================== metadata ====================

  private parseMetadata(): boolean {
    if (this.fileSize <= 0) {
      return false;
    }
    const tailLen: number = Math.min(this.fileSize, META_MAX);
    const a: ArrayBuffer = new ArrayBuffer(tailLen);
    if (this.readInto(this.fileSize - tailLen, a, tailLen) !== tailLen) {
      return false;
    }
    const tail: Uint8Array = new Uint8Array(a);
    const rel: number = this.findMarker(tail);
    if (rel < 0) {
      return false;
    }
    const metaOff: number = this.fileSize - tailLen + rel;

    const ci: CtrlInfo = this.ctrl(metaOff);
    if (ci.type !== 7) {
      return false;
    }
    // metadata 是 map；此处 pointer 基址为 0（绝对偏移）
    let p: number = ci.next;
    for (let i = 0; i < ci.size; i++) {
      const k: StrVal = this.readStr(p, 0);
      p = k.next;
      if (k.s === 'node_count') {
        const v: UintVal = this.readUint(p, 0);
        this.nodeCount = v.v;
        p = v.next;
      } else if (k.s === 'record_size') {
        const v: UintVal = this.readUint(p, 0);
        this.recordSize = v.v;
        p = v.next;
      } else {
        p = this.skipValue(p);
      }
    }
    if (this.nodeCount <= 0 || this.recordSize < 24 || this.recordSize > 32) {
      return false;
    }
    this.nodeBytes = this.recordSize * 2 / 8;
    this.treeBytes = this.nodeCount * this.nodeBytes;
    this.dataBase = this.treeBytes + 16;      // 数据段起点（树后有 16 字节 NULL 分隔）

    // 小库整树常驻，避免每次查询上百次 readSync
    if (this.treeBytes > 0 && this.treeBytes <= TREE_CACHE_LIMIT) {
      const t: ArrayBuffer = new ArrayBuffer(this.treeBytes);
      if (this.readInto(0, t, this.treeBytes) === this.treeBytes) {
        this.tree = new Uint8Array(t);
      }
    }
    return true;
  }

  /** 返回 marker 之后第一个字节在 buf 中的相对偏移；找不到返回 -1 */
  private findMarker(buf: Uint8Array): number {
    for (let i = buf.length - MARKER.length; i >= 0; i--) {
      let hit: boolean = true;
      for (let j = 0; j < MARKER.length; j++) {
        if (buf[i + j] !== MARKER[j]) {
          hit = false;
          break;
        }
      }
      if (hit) {
        return i + MARKER.length;
      }
    }
    return -1;
  }

  // ==================== search tree ====================

  /**
   * 查一个地址，返回 ASN 记录。
   * v4 传入 4 字节，v6 传入 16 字节；两种都由同一个树承载。
   */
  lookup(ipBytes: Uint8Array): AsnRecord {
    if (this.nodeCount <= 0) {
      return { found: false, asn: 0, org: '' };
    }
    let node: number = 0;
    if (ipBytes.length === 4) {
      // IPv4 在 mmdb 中挂在高 96 位全 0 的路径下 —— 必须走满 96 **步**（12 字节 × 8 位），
      // 写成 12 步会落在某个中间节点上，导致随后 32 位的遍历整体错位。
      for (let i = 0; i < 96; i++) {
        node = this.record(node, 0);
        if (node >= this.nodeCount) {
          break;
        }
      }
      if (node < this.nodeCount) {
        node = this.traverse(node, ipBytes);
      }
    } else if (ipBytes.length === 16) {
      node = this.traverse(node, ipBytes);
    } else {
      return { found: false, asn: 0, org: '' };
    }

    if (node === this.nodeCount) {
      return { found: false, asn: 0, org: '' };   // 等于 node_count 表示该段无数据
    }
    if (node < this.nodeCount) {
      return { found: false, asn: 0, org: '' };   // 走满仍未落到叶子（异常形态）
    }
    return this.readRecordData((node - this.nodeCount) + this.treeBytes);
  }

  private traverse(node: number, bytes: Uint8Array): number {
    let n: number = node;
    for (let i = 0; i < bytes.length; i++) {
      const byte: number = bytes[i];
      for (let s = 7; s >= 0; s--) {
        n = this.record(n, (byte >> s) & 1);
        if (n >= this.nodeCount) {
          return n;
        }
      }
    }
    return n;
  }

  /** 读第 node 个节点的左/右记录；record 值可能指向下一节点，也可能指向数据段 */
  private record(node: number, right: number): number {
    const off: number = node * this.nodeBytes;
    let b: Uint8Array;
    if (this.tree !== undefined) {
      b = this.tree as Uint8Array;
    } else {
      if (this.readInto(off, this.aNode, this.nodeBytes) !== this.nodeBytes) {
        return this.nodeCount;                // 读失败当作"无数据"，不抛
      }
      b = this.uNode as Uint8Array;
    }
    const base: number = this.tree !== undefined ? off : 0;

    if (this.recordSize === 24) {
      if (right === 0) {
        return (b[base] << 16) | (b[base + 1] << 8) | b[base + 2];
      }
      return (b[base + 3] << 16) | (b[base + 4] << 8) | b[base + 5];
    }
    if (this.recordSize === 28) {
      // 7 字节节点：第 4 个字节高 4 位归左记录，低 4 位归右记录
      if (right === 0) {
        return (((b[base + 3] & 0xf0) << 20) | (b[base] << 16) | (b[base + 1] << 8) | b[base + 2]) >>> 0;
      }
      return (((b[base + 3] & 0x0f) << 24) | (b[base + 4] << 16) | (b[base + 5] << 8) | b[base + 6]) >>> 0;
    }
    if (right === 0) {
      return ((b[base] << 24) | (b[base + 1] << 16) | (b[base + 2] << 8) | b[base + 3]) >>> 0;
    }
    return ((b[base + 4] << 24) | (b[base + 5] << 16) | (b[base + 6] << 8) | b[base + 7]) >>> 0;
  }

  // ==================== 数据段 ====================

  /** 解析叶子数据（期望是 2 键的 map）；此处 pointer 基址 = dataBase */
  private readRecordData(off: number): AsnRecord {
    const ci: CtrlInfo = this.ctrl(off);
    if (ci.type !== 7) {
      return { found: false, asn: 0, org: '' };
    }
    let asn: number = 0;
    let org: string = '';
    let p: number = ci.next;
    for (let i = 0; i < ci.size; i++) {
      const k: StrVal = this.readStr(p, this.dataBase);
      p = k.next;
      if (k.s === 'autonomous_system_number') {
        const v: UintVal = this.readUint(p, this.dataBase);
        asn = v.v;
        p = v.next;
      } else if (k.s === 'autonomous_system_organization') {
        const v: StrVal = this.readStr(p, this.dataBase);
        org = v.s;
        p = v.next;
      } else {
        p = this.skipValue(p);
      }
    }
    return { found: asn > 0 || org.length > 0, asn, org };
  }

  /** 读控制字节：type / size，并给出值数据的起始绝对偏移 */
  private ctrl(off: number): CtrlInfo {
    const n: number = this.readInto(off, this.aScratch, SCRATCH_LEN);
    const b: Uint8Array = this.uScratch as Uint8Array;
    if (n > 0 && n < SCRATCH_LEN) {
      for (let i = n; i < SCRATCH_LEN; i++) {
        b[i] = 0;                              // 清掉上一次的残留
      }
    }
    const c: number = b[0];
    let t: number = c >> 5;
    let p: number = 1;
    if (t === 0) {                             // 扩展类型：真实类型在下一字节 - 7
      t = b[1] + 7;
      p = 2;
    }
    let size: number = c & 0x1f;
    if (t !== 1) {                             // pointer 的长度语义不同，不套用扩展
      if (size === 29) {
        size = 29 + b[p];
        p += 1;
      } else if (size === 30) {
        size = 285 + ((b[p] << 8) | b[p + 1]);
        p += 2;
      } else if (size === 31) {
        size = 65821 + ((b[p] << 16) | (b[p + 1] << 8) | b[p + 2]);
        p += 3;
      }
    }
    return { type: t, size, next: off + p };
  }

  /** pointer 解引用；返回文件绝对偏移 */
  private deref(ci: CtrlInfo, base: number): number {
    const off: number = ci.next;
    this.readInto(off, this.aPtr, 4);
    const b: Uint8Array = this.uPtr as Uint8Array;
    const ss: number = (ci.size >> 3) & 0x3;
    const vvv: number = ci.size & 0x7;
    if (ss === 0) {
      return (((vvv << 8) | b[0]) >>> 0) + base;
    }
    if (ss === 1) {
      return ((((vvv << 16) | (b[0] << 8) | b[1]) >>> 0) + 2048) + base;
    }
    if (ss === 2) {
      return ((((vvv << 24) | (b[0] << 16) | (b[1] << 8) | b[2]) >>> 0) + 526336) + base;
    }
    return (((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) >>> 0) + base;
  }

  /** pointer 本身占用的字节数（不含被指向的数据），取决于其 SS 位 */
  private ptrWidth(ci: CtrlInfo): number {
    const ss: number = (ci.size >> 3) & 0x3;
    return ss === 0 ? 1 : (ss === 1 ? 2 : (ss === 2 ? 3 : 4));
  }

  private readStr(off: number, base: number): StrVal {
    const ci: CtrlInfo = this.ctrl(off);
    if (ci.type === 1) {
      const inner: StrVal = this.readStr(this.deref(ci, base), base);
      // ⚠️ 游标必须停在 **pointer 本身之后**，而不是被指向字符串之后。
      // 直接返回 inner.next 会让后续字段整体错位（遍历仍正确，但解码读到别的记录）。
      return { s: inner.s, next: ci.next + this.ptrWidth(ci) };
    }
    if (ci.type !== 2 || ci.size <= 0 || ci.size > 8192) {
      return { s: '', next: ci.next };
    }
    const a: ArrayBuffer = new ArrayBuffer(ci.size);
    if (this.readInto(ci.next, a, ci.size) !== ci.size) {
      return { s: '', next: ci.next };
    }
    try {
      return { s: (this.dec as util.TextDecoder).decodeToString(new Uint8Array(a)), next: ci.next + ci.size };
    } catch (e) {
      return { s: '', next: ci.next };
    }
  }

  private readUint(off: number, base: number): UintVal {
    const ci: CtrlInfo = this.ctrl(off);
    if (ci.type === 1) {
      const inner: UintVal = this.readUint(this.deref(ci, base), base);
      // 同 readStr：游标停在 pointer 之后（见那里的说明）
      return { v: inner.v, next: ci.next + this.ptrWidth(ci) };
    }
    // 坑 1：uint 的宽度就是 size，可能只有 1 字节
    if ((ci.type !== 5 && ci.type !== 6 && ci.type !== 8 && ci.type !== 9) ||
      ci.size <= 0 || ci.size > 8) {
      return { v: 0, next: ci.next };
    }
    const a: ArrayBuffer = new ArrayBuffer(ci.size);
    if (this.readInto(ci.next, a, ci.size) !== ci.size) {
      return { v: 0, next: ci.next };
    }
    const u: Uint8Array = new Uint8Array(a);
    let v: number = 0;
    for (let i = 0; i < u.length; i++) {
      v = v * 256 + u[i];                      // 大端累积，避免移位溢出
    }
    return { v, next: ci.next + ci.size };
  }

  /** 跳过一个值（GeoLite2-ASN 用不到分支时保持游标正确） */
  private skipValue(off: number): number {
    const ci: CtrlInfo = this.ctrl(off);
    if (ci.type === 1) {
      const ss: number = (ci.size >> 3) & 0x3;
      return ci.next + (ss === 0 ? 1 : (ss === 1 ? 2 : (ss === 2 ? 3 : 4)));
    }
    if (ci.type === 7) {
      let p: number = ci.next;
      for (let i = 0; i < ci.size * 2; i++) {
        p = this.skipValue(p);
      }
      return p;
    }
    if (ci.type === 11) {
      let p: number = ci.next;
      for (let i = 0; i < ci.size; i++) {
        p = this.skipValue(p);
      }
      return p;
    }
    if (ci.type === 3) {
      return ci.next + 8;
    }
    if (ci.type === 15) {
      return ci.next + 4;
    }
    if (ci.type === 14) {
      return ci.next;                          // boolean 无载荷
    }
    return ci.next + ci.size;                  // string / bytes / 各宽度整数
  }

  // ==================== IO ====================

  /** 从 fd 的绝对偏移读取 len 字节到 dst，返回实际读取数 */
  private readInto(off: number, dst: ArrayBuffer, len: number): number {
    if (off < 0 || len <= 0) {
      return 0;
    }
    return fs.readSync(this.fd, dst, { offset: this.base + off, length: len });
  }
}
