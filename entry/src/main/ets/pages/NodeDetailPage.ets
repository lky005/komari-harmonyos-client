/**
 * NodeDetailPage —— 节点详情（实时区 + 历史曲线）
 *
 * 参数：router 传入 { uuid }
 * 数据：
 *   - 静态信息：进页拉一次 getNodes() 按 uuid 匹配（价格 / 到期 / 配置）
 *   - 实时快照：每 2s 轮询 getClientRecentRecords，取数组最后一个
 *   - 历史曲线：切指标/时间范围时调 queryMetrics；MetricPoint.value 为 null 的点剔除
 *   - 网络身份：进页调一次 common:getNodes 拿 IP（管理员/API Key=完整，游客按
 *     服务端 send_ip_addr_to_guest 打码或空），首个公网 IP 再经 IpInfoService 查
 *     ASN/厂商（第三方 https 源，私网与打码 IP 不外发），失败静默显示 —；
 *     卡片外层只露一行预览，整行可点开居中弹层（NetIdentityDialog）看全量
 *
 * 已知坑（改前必读）：
 *   - network.totalUp / totalDown 是驼峰
 *   - MetricPoint.value 可能为 null（历史曲线已用 typeof 过滤）
 *   - expired_at 可能是 ''（无到期日）
 *   - 空字符串必须用 || '-' 兜底，?? '-' 只兜底 null/undefined
 *   - 历史曲线 metric key 用 resolveMetricKey() 从服务端 definitions 动态匹配，不硬编码
 */

import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { ClientReport, KomariClient, MetricDefinition, MetricPoint, MetricSeries } from '../model/KomariTypes';
import { QueryMetricsParams } from '../service/KomariApi';
import { IpInfoService } from '../service/IpInfoService';
import { FormatUtil } from '../common/FormatUtil';
import { NodeUtil } from '../common/NodeUtil';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';
import { MetricBar } from '../view/MetricBar';
import { MpLineChart } from '../view/MpLineChart';

interface DetailParam {
  uuid: string;
}

/** 带图标的信息行：图标 + 标签 + 值 */
@Component
struct IconInfoRow {
  icon: Resource = $r('sys.symbol.gearshape');
  label: string = '';
  @Prop value: string = '';
  /** 值允许两行（厂商名等长文本）；默认单行省略 */
  @Prop multiLine: boolean = false;

  build() {
    Row() {
      SymbolGlyph(this.icon)
        .fontSize(14)
        .fontColor([Color.Gray])
        .width(18)
      Text(this.label)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .margin({ left: 6 })
      Blank()
      Text(this.value)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .maxLines(this.multiLine ? 2 : 1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '60%' })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Top)
  }
}

/** 卡片标题：图标 + 文字 */
@Component
struct SectionTitle {
  icon: Resource = $r('sys.symbol.gearshape');
  title: string = '';

  build() {
    Row() {
      SymbolGlyph(this.icon)
        .fontSize(16)
        .fontColor([$r('sys.color.ohos_id_color_emphasize')])
      Text(this.title)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ left: 6 })
    }
    .width('100%')
    .padding({ bottom: 4 })
  }
}

/** 历史曲线指标卡片定义（支持双线：主线 + 可选副线） */
interface MetricCardDef {
  label: string;          // 卡片按钮显示名
  mainLabel: string;      // 主线 Tooltip 标签（如"内存"/"下行"/"TCP"）
  mainKey: string;
  mainFmt: string;       // percent / bytes / rate / count / load
  displayUnit: string;   // 显示单位（'%' / 'MB' / 'GB' / 'MB/s' / ''）
  divisor: number;       // 原始值除以多少得到显示值（字节类用 1024² 或 1024³）
  subKey?: string;        // 副线 metric key（可选，存在则为双线卡片）
  subFmt?: string;
  subLabel?: string;      // 副线 Tooltip 标签
}

@Entry
@Component
struct NodeDetailPage {
  @State node: KomariClient | undefined = undefined;
  @State report: ClientReport | undefined = undefined;
  @State errorMsg: string = '';
  @State updatedAtText: string = '';
  // ===== 网络身份（common:getNodes + IpInfoService，进页拉一次，失败静默显示 —）=====
  @State ip4: string = '';
  @State ip6: string = '';
  @State asnText: string = '';
  @State orgText: string = '';
  // ===== 历史曲线状态 =====
  @State rangeIdx: number = 1;
  @State metricIdx: number = 0;
  @State historyValues: number[] = [];
  @State historyValues2: number[] = [];  // 副线数据（双线卡片）
  @State historyTimestamps: number[] = [];
  @State historyUnit: string = '';
  @State historyLoading: boolean = false;
  @State historyError: string = '';
  // ===== 历史曲线预计算统计量（数据拉取后一次性计算，避免 build() 重复遍历）=====
  @State histMin: number | undefined = undefined;
  @State histMax: number | undefined = undefined;
  @State histAvg: number | undefined = undefined;
  @State histCurrent: number | undefined = undefined;
  @State histTicks: number[] = [];
  private reqSeq: number = 0;  // 请求序列号：竞态淘汰 + 页面销毁保护
  private scroller: Scroller = new Scroller();
  private definitions: MetricDefinition[] = [];
  private rangeLabels: string[] = ['1小时', '6小时', '24小时', '7天'];
  private rangeHours: number[] = [1, 6, 24, 168];
  // 6 个指标卡片：3 个双线（内存/网络/连接）+ 3 个单线（CPU/磁盘/GPU）
  private metricCards: MetricCardDef[] = [
    { label: 'CPU', mainLabel: 'CPU', mainKey: 'cpu.usage', mainFmt: 'percent', displayUnit: '%', divisor: 1 },
    { label: '内存', mainLabel: '内存', mainKey: 'memory.used', mainFmt: 'bytes', displayUnit: 'MB', divisor: 1024 * 1024, subKey: 'swap.used', subFmt: 'bytes', subLabel: 'Swap' },
    { label: '磁盘', mainLabel: '磁盘', mainKey: 'disk.used', mainFmt: 'bytes', displayUnit: 'GB', divisor: 1024 * 1024 * 1024 },
    { label: '网络', mainLabel: '下行', mainKey: 'net.in.rate', mainFmt: 'rate', displayUnit: 'MB/s', divisor: 1024 * 1024, subKey: 'net.out.rate', subFmt: 'rate', subLabel: '上行' },
    { label: '连接', mainLabel: 'TCP', mainKey: 'connections.tcp', mainFmt: 'count', displayUnit: '', divisor: 1, subKey: 'connections.udp', subFmt: 'count', subLabel: 'UDP' },
    { label: 'GPU', mainLabel: 'GPU', mainKey: 'gpu.usage', mainFmt: 'percent', displayUnit: '%', divisor: 1 },
  ];
  private uuid: string = '';
  private pollTimer: number = -1;
  private polling: boolean = false;
  private refreshing: boolean = false;
  private reportLogged: boolean = false;
  private unsubscribeReport: (() => void) | undefined = undefined;
  /** 网络身份请求序列号：页面销毁后使在途查询失效 */
  private netInfoSeq: number = 0;
  /** 网络身份弹层控制器：每次点开时在 openNetDialog() 里现建（保证取到最新值） */
  private netDialog: CustomDialogController | undefined = undefined;

  aboutToAppear(): void {
    const p = router.getParams() as DetailParam | undefined;
    if (!p || !p.uuid || p.uuid.length === 0) {
      this.errorMsg = '参数缺失';
      return;
    }
    this.uuid = p.uuid;
    const store = NodeDataStore.getInstance();
    // 秒开：先从全局缓存读已有数据（列表页已拉过）
    this.node = store.getNodeInfo(this.uuid);
    this.report = store.getLatestReport(this.uuid);
    if (this.report) {
      this.updatedAtText = FormatUtil.clock(this.report.updated_at);
    }
    // 订阅实时指标变化
    this.unsubscribeReport = store.subscribeReport(this.uuid, (): void => {
      this.report = store.getLatestReport(this.uuid);
      if (this.report) {
        this.updatedAtText = FormatUtil.clock(this.report.updated_at);
      }
    });
    this.loadNodeInfo();
    this.loadNetIdentity();
    this.startPolling();
  }

  aboutToDisappear(): void {
    this.reqSeq++;  // 使所有在途异步请求的 mySeq 失效，防止销毁后赋值
    this.netInfoSeq++;  // 使在途 IP/ASN 查询失效
    this.stopPolling();
    this.unsubscribeReport?.();
    this.unsubscribeReport = undefined;
  }

  /**
   * 网络身份：common:getNodes 拿节点 IP（管理员/API Key=完整，游客按服务端设置打码或空），
   * 再用首个合法公网 IP 查 ASN/厂商。任何失败静默保留 '—'（私有站点游客拒权 / 打码 IP / 旧版服务端）。
   */
  private async loadNetIdentity(): Promise<void> {
    const mySeq: number = ++this.netInfoSeq;
    try {
      const client = await ServiceRegistry.getApi().getCommonNode(this.uuid);
      if (mySeq !== this.netInfoSeq) {
        return;
      }
      this.ip4 = client.ipv4 ?? '';
      this.ip6 = client.ipv6 ?? '';
      const target: string = IpInfoService.isPublicIp(this.ip4) ? this.ip4
        : (IpInfoService.isPublicIp(this.ip6) ? this.ip6 : '');
      if (target.length === 0) {
        return;  // 打码 / 内网 / 空：不外发查询，只展示服务端给的文本
      }
      const info = await IpInfoService.lookup(target);
      if (mySeq !== this.netInfoSeq) {
        return;
      }
      if (info.asn.length > 0) {
        this.asnText = info.asn;
      }
      if (info.org.length > 0) {
        this.orgText = info.org;
      }
    } catch (e) {
      // 拒权 / 旧版服务端无 common 组 / 网络失败：行值停留在 '—'
    }
  }

  private ip4Text(): string {
    return this.ip4.length > 0 ? this.ip4 : '—';
  }

  private ip6Text(): string {
    return this.ip6.length > 0 ? this.ip6 : '—';
  }

  /** 卡片上的身份预览值：IPv4 优先，没有则 IPv6（含打码形态照原样显示），全无则 — */
  private identityPreview(): string {
    if (this.ip4.length > 0) {
      return this.ip4;
    }
    if (this.ip6.length > 0) {
      return this.ip6;
    }
    return '—';
  }

  /**
   * 打开网络身份弹层。控制器每次点开时现建——builder 参数在构造时就取值快照，
   * 而 IP/ASN 是进页后异步到达的，复用单个控制器会弹出构建时的空值。
   */
  private openNetDialog(): void {
    this.netDialog = new CustomDialogController({
      builder: NetIdentityDialog({
        ip4: this.ip4Text(),
        ip6: this.ip6Text(),
        asn: this.asnText.length > 0 ? this.asnText : '—',
        org: this.orgText.length > 0 ? this.orgText : '—'
      }),
      autoCancel: true,
      customStyle: true
    });
    this.netDialog.open();
  }

  /** 网络身份预览行：图标 + 标签 + 右对齐预览值 + › 整行可点（与设置页入口卡同款语言） */
  @Builder
  netIdentityRow() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.cloud'))
        .fontSize(14)
        .fontColor([Color.Gray])
        .width(18)
      Text('公网 IP')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .margin({ left: 6 })
      Blank()
      Text(this.identityPreview())
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '55%' })
      Text('›')
        .fontSize(16)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .onClick((): void => {
      this.openNetDialog();
    })
  }

  private async loadNodeInfo(): Promise<void> {
    const store = NodeDataStore.getInstance();
    try {
      // 静态信息优先从缓存读（列表页已拉过），没有则触发拉取
      if (!store.getNodeInfo(this.uuid)) {
        await store.fetchNodeInfo(true);
      }
      const found: KomariClient | undefined = store.getNodeInfo(this.uuid);
      if (found) {
        this.node = found;
        const n = found;
        hilog.info(0x0001, 'Komari', `node fields: os=[${n.os}] arch=[${n.arch}] region=[${n.region}] group=[${n.group}] virt=[${n.virtualization}] kernel=[${n.kernel_version}] gpu=[${n.gpu_name}] cpu_name=[${n.cpu_name}]`);
      } else {
        hilog.warn(0x0001, 'Komari', `node not found for uuid=${this.uuid}`);
      }
    } catch (err) {
      const e = err as Error;
      this.errorMsg = e?.message ?? '';
      hilog.error(0x0001, 'Komari', `getNodes failed: ${e?.message ?? ''}`);
    }
    try {
      this.definitions = await ServiceRegistry.getApi().listMetricDefinitions();
      const keys: string = this.definitions.map((d: MetricDefinition): string => d.name).join(',');
      hilog.info(0x0001, 'Komari', `metric definitions count=${this.definitions.length}, keys=[${keys}]`);
    } catch (e) {
      this.definitions = [];
      hilog.error(0x0001, 'Komari', `listMetricDefinitions failed`);
    }
    this.loadHistory();
  }

  // ===== 历史曲线 =====

  /** 探针采不到 GPU 时常见的型号占位值（比较用小写，空串也在内） */
  private readonly gpuPlaceholders: string[] = ['none', 'unknown', 'n/a', 'null', ''];

  private gpuRaw(): string {
    return (this.node?.gpu_name ?? '').trim();
  }

  private hasGpu(): boolean {
    return !this.gpuPlaceholders.includes(this.gpuRaw().toLowerCase());
  }

  /** 型号展示值：占位值显示「无GPU」，有效型号原样返回 */
  private gpuNameText(): string {
    const raw: string = this.gpuRaw();
    return this.gpuPlaceholders.includes(raw.toLowerCase()) ? '无GPU' : raw;
  }

  /** 实际可选的指标数量（无 GPU 的节点隐藏 GPU 项） */
  private metricCount(): number {
    return this.hasGpu() ? this.metricCards.length : this.metricCards.length - 1;
  }

  /**
   * 指标显示单位（直接取卡片配置，忽略服务端返回的原始 unit）
   */
  private displayUnit(idx: number): string {
    return this.metricCards[idx].displayUnit;
  }

  /**
   * 用服务端 definitions 动态匹配 metric key。
   * 优先精确匹配，其次模糊匹配（去掉 . _ - 后比较），最后包含匹配。
   * 都找不到时返回原 key（让服务端返回空，前端显示暂无数据）。
   */
  private resolveMetricKey(wanted: string): string {
    if (this.definitions.length === 0) {
      return wanted;
    }
    const exact = this.definitions.find((d: MetricDefinition): boolean => d.name === wanted);
    if (exact) {
      return wanted;
    }
    const norm = (s: string): string => s.toLowerCase().replace(/[._\-]/g, '');
    const wantedNorm: string = norm(wanted);
    const fuzzy = this.definitions.find((d: MetricDefinition): boolean => norm(d.name) === wantedNorm);
    if (fuzzy) {
      return fuzzy.name;
    }
    const partial = this.definitions.find((d: MetricDefinition): boolean =>
      norm(d.name).includes(wantedNorm) || wantedNorm.includes(norm(d.name)));
    if (partial) {
      return partial.name;
    }
    return wanted;
  }

  private fmtHistValue(v: number): string {
    const card: MetricCardDef = this.metricCards[this.metricIdx];
    const fmt: string = card.mainFmt;
    if (fmt === 'percent') {
      return `${v.toFixed(1)}%`;
    }
    if (fmt === 'bytes' || fmt === 'rate') {
      // 值已在 loadHistory 中按 divisor 转换，直接拼接单位
      return card.displayUnit.length > 0 ? `${v.toFixed(1)} ${card.displayUnit}` : v.toFixed(1);
    }
    if (fmt === 'load') {
      return v.toFixed(2);
    }
    return `${Math.round(v)}`;
  }

  private histColor(): Resource {
    return $r('sys.color.ohos_id_color_emphasize');
  }

  /** MetricPoint.value 服务端是 *float64：null/NaN 点全部剔除。
   *  注意：必须用 Array.isArray 断言——服务端可能返回 {}（空对象，truthy），
   *  仅 !series.points 无法拦截，会导致 forEach is not callable 运行时异常。
   */
  private cleanValues(series: MetricSeries | undefined): number[] {
    if (!series || !series.points || !Array.isArray(series.points)) {
      return [];
    }
    const out: number[] = [];
    series.points.forEach((p: MetricPoint): void => {
      if (typeof p.value === 'number' && !isNaN(p.value) && isFinite(p.value)) {
        out.push(p.value);
      }
    });
    return out;
  }

  /** 提取时间戳（毫秒），与 cleanValues 对齐——跳过 value 无效的点 */
  private cleanTimestamps(series: MetricSeries | undefined): number[] {
    if (!series || !series.points || !Array.isArray(series.points)) {
      return [];
    }
    const out: number[] = [];
    series.points.forEach((p: MetricPoint): void => {
      if (typeof p.value === 'number' && !isNaN(p.value) && isFinite(p.value)) {
        const t: number = Date.parse(p.time);
        out.push(isNaN(t) ? 0 : t);
      }
    });
    return out;
  }

  private histSummary(label: string, value: number | undefined): string {
    const v: string = value === undefined ? '-' : this.fmtHistValue(value);
    return `${label} ${v}`;
  }

  // 注：histMin/histMax/histAvg/histCurrent 已改为 @State 预计算变量，
  // 由 recomputeStats() 在数据拉取后一次性赋值，避免 build() 中重复遍历。

  /**
   * 预计算统计量 + Y 轴 nice-number 刻度（数据拉取后调用一次）
   * - 单次遍历 values 计算 min/max/avg/current
   * - Y 轴刻度：向上取整（非四舍五入）+ 15% 安全内衬，杜绝波峰穿透天花板
   * - 平线/全零：以 0 为底，上限为 max(dataMax, 1)
   */
  private recomputeStats(): void {
    const n: number = this.historyValues.length;
    if (n === 0) {
      this.histMin = undefined;
      this.histMax = undefined;
      this.histAvg = undefined;
      this.histCurrent = undefined;
      this.histTicks = [];
      return;
    }
    let dataMin: number = Infinity;
    let dataMax: number = -Infinity;
    let sum: number = 0;
    for (const v of this.historyValues) {
      if (v < dataMin) dataMin = v;
      if (v > dataMax) dataMax = v;
      sum += v;
    }
    this.histMin = dataMin;
    this.histMax = dataMax;
    this.histAvg = sum / n;
    this.histCurrent = this.historyValues[n - 1];

    // Nice Number Y 轴刻度（15% padding + 扩充范围算步长 + while 兜底防穿透）
    const range: number = dataMax - dataMin;
    let niceMin: number;
    let tickStep: number;
    if (range < 1e-6) {
      // 平线/全零：以 0 为底，上限为 max(dataMax, 1)
      const top: number = Math.max(dataMax, 1);
      const roughStep: number = top / 3;
      const exp: number = Math.floor(Math.log10(roughStep));
      const frac: number = roughStep / Math.pow(10, exp);
      const niceFrac: number = frac <= 1 ? 1 : frac <= 2 ? 2 : frac <= 5 ? 5 : 10;
      tickStep = niceFrac * Math.pow(10, exp);
      niceMin = 0;
    } else {
      // 第一步：给极值加 15% 安全缓冲
      const pad: number = range * 0.15;
      const targetMin: number = Math.max(0, dataMin - pad);
      const targetMax: number = dataMax + pad;
      // 第二步：基于扩充后的总跨度计算步长（向上取整 niceFrac ∈ [1,2,5,10]）
      const roughStep: number = (targetMax - targetMin) / 3;
      const exp: number = Math.floor(Math.log10(roughStep));
      const frac: number = roughStep / Math.pow(10, exp);
      const niceFrac: number = frac <= 1 ? 1 : frac <= 2 ? 2 : frac <= 5 ? 5 : 10;
      tickStep = niceFrac * Math.pow(10, exp);
      // 第三步：规整起点（floor 对齐 tickStep，严防负数）
      niceMin = Math.max(0, Math.floor(targetMin / tickStep) * tickStep);
      // 第四步：绝对防御兜底——若仍穿透则放大步长
      while (niceMin + tickStep * 3 < dataMax) {
        tickStep *= 1.2;
      }
    }
    this.histTicks = [niceMin, niceMin + tickStep, niceMin + tickStep * 2, niceMin + tickStep * 3];
  }

  private async loadHistory(): Promise<void> {
    const mySeq: number = ++this.reqSeq;  // Request ID：快速切换时只有最后一次生效
    this.historyLoading = true;
    this.historyError = '';
    this.historyValues2 = [];  // 重置副线
    try {
      const card: MetricCardDef = this.metricCards[this.metricIdx];
      const resolvedMainKey: string = this.resolveMetricKey(card.mainKey);
      const isDual: boolean = card.subKey !== undefined && card.subKey.length > 0;
      const resolvedSubKey: string = isDual ? this.resolveMetricKey(card.subKey as string) : '';

      hilog.info(0x0001, 'Komari', `loadHistory: card=${card.label} main=${resolvedMainKey} sub=${resolvedSubKey} dual=${isDual} hours=${this.rangeHours[this.rangeIdx]} entity=${this.uuid}`);

      const params: QueryMetricsParams = {
        entity_id: this.uuid,
        hours: this.rangeHours[this.rangeIdx],
        max_points: 300
      };
      if (isDual) {
        params.metric_keys = [resolvedMainKey, resolvedSubKey];
      } else {
        params.metric_key = resolvedMainKey;
      }

      const rawResult = await ServiceRegistry.getApi().queryMetrics(params);
      if (mySeq !== this.reqSeq) {
        return;  // 过期响应（用户切换了范围或页面已销毁），静默丢弃
      }
      hilog.info(0x0001, 'Komari', `loadHistory: rawResult type=${typeof rawResult}, isArray=${Array.isArray(rawResult)}`);
      let series: MetricSeries[] = [];
      if (Array.isArray(rawResult)) {
        series = rawResult as MetricSeries[];
      } else if (rawResult && typeof rawResult === 'object') {
        const obj = rawResult as Record<string, Object>;
        if (Array.isArray(obj['series'])) {
          series = obj['series'] as MetricSeries[];
        } else if (Array.isArray(obj['data'])) {
          series = obj['data'] as MetricSeries[];
        } else if (Array.isArray(obj['metrics'])) {
          series = obj['metrics'] as MetricSeries[];
        }
      }
      hilog.info(0x0001, 'Komari', `loadHistory: normalized series count=${series.length}`);

      // 按 metric_key 匹配主线和副线（优先匹配 entity_id）
      let mainSeries: MetricSeries | undefined = undefined;
      let subSeries: MetricSeries | undefined = undefined;
      series.forEach((s: MetricSeries): void => {
        if (s.entity_id !== this.uuid) {
          return;
        }
        if (!mainSeries && s.metric_key === resolvedMainKey) {
          mainSeries = s;
        }
        if (isDual && !subSeries && s.metric_key === resolvedSubKey) {
          subSeries = s;
        }
      });
      // fallback：entity_id 不匹配时取前两个
      if (!mainSeries && series.length > 0) {
        mainSeries = series[0];
      }
      if (isDual && !subSeries && series.length > 1) {
        subSeries = series[1];
      }

      // 解析主线数据 + 单位转换（按卡片 divisor 统一转换，磁盘用 GB、内存/网络用 MB）
      const rawValues: number[] = this.cleanValues(mainSeries);
      if (card.divisor > 1) {
        this.historyValues = rawValues.map((v: number): number => v / card.divisor);
      } else {
        this.historyValues = rawValues;
      }
      this.historyTimestamps = this.cleanTimestamps(mainSeries);
      this.historyUnit = this.displayUnit(this.metricIdx);

      // 解析副线数据（双线卡片，副线与主线同单位，用同一个 divisor）
      if (isDual && subSeries !== undefined) {
        const rawValues2: number[] = this.cleanValues(subSeries);
        if (card.divisor > 1) {
          this.historyValues2 = rawValues2.map((v: number): number => v / card.divisor);
        } else {
          this.historyValues2 = rawValues2;
        }
      }

      this.recomputeStats();  // 预计算 min/max/avg/current/ticks
      hilog.info(0x0001, 'Komari', `loadHistory: main points=${mainSeries?.points?.length ?? 0} values=${this.historyValues.length} subValues=${this.historyValues2.length} unit=${this.historyUnit}`);
      if (this.historyValues.length === 0) {
        this.historyError = '该时间范围内暂无数据';
      }
    } catch (err) {
      if (mySeq !== this.reqSeq) {
        return;
      }
      const e = err as Error;
      this.historyValues = [];
      this.historyValues2 = [];
      this.recomputeStats();
      this.historyError = e?.message ?? '查询失败';
      hilog.error(0x0001, 'Komari', `loadHistory failed: ${e?.message ?? ''}`);
    } finally {
      if (mySeq === this.reqSeq) {
        this.historyLoading = false;
      }
    }
  }

  /**
   * 启动轮询：立即执行一次，之后用递归 setTimeout 调度（2秒间隔）。
   * 不用 setInterval：防止弱网下前一次未完成时新任务堆积。
   */
  private startPolling(): void {
    this.stopPolling();
    this.refreshSnapshot();
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private async refreshSnapshot(): Promise<void> {
    if (this.polling || !ServiceRegistry.getActiveConfig()) {
      return;
    }
    const store = NodeDataStore.getInstance();
    const interval: number = store.getConfig().detailInterval;
    // 后台或断网时跳过请求（定时器保留，恢复后自动对齐）
    if (!store.isForeground() || !store.isNetworkAvailable()) {
      this.pollTimer = setTimeout((): void => {
        this.refreshSnapshot();
      }, interval);
      return;
    }
    this.polling = true;
    try {
      // 通过 NodeDataStore 拉取（内部有竞态防护：请求序号 + 时间戳双重校验）
      // 拉取成功后通过 subscribeReport 回调更新 this.report
      await store.fetchReport(this.uuid);
      const r: ClientReport | undefined = store.getLatestReport(this.uuid);
      if (r) {
        this.errorMsg = '';
        if (!this.reportLogged) {
          hilog.info(0x0001, 'Komari', `report: uptime=${r.uptime} process=${r.process} load1=${r.load?.load1} load5=${r.load?.load5} load15=${r.load?.load15} cpu_usage=${r.cpu?.usage} mem_used=${r.ram?.used} mem_total=${r.ram?.total} disk_used=${r.disk?.used} disk_total=${r.disk?.total} net_up=${r.network?.up} net_down=${r.network?.down} tcp=${r.connections?.tcp} udp=${r.connections?.udp}`);
          this.reportLogged = true;
        }
      } else {
        this.errorMsg = '暂无上报数据';
      }
    } catch (err) {
      const e = err as Error;
      this.errorMsg = e?.message ?? '数据获取失败';
      hilog.error(0x0001, 'Komari', `refreshSnapshot failed: ${e?.message ?? ''}`);
    } finally {
      this.polling = false;
      // 执行完毕后再延迟调度下一次（间隔从配置读取，递归 setTimeout 防重叠）
      this.pollTimer = setTimeout((): void => {
        this.refreshSnapshot();
      }, interval);
    }
  }

  private priceLine(): string {
    const n = this.node;
    if (!n || !n.price || n.price <= 0) {
      return '';
    }
    const cur: string = n.currency && n.currency.length > 0 ? n.currency : '';
    return `${cur}${n.price}`;
  }

  private expireLine(): string {
    const n = this.node;
    if (!n || !n.expired_at || n.expired_at.length === 0) {
      return '';
    }
    const days: number = FormatUtil.daysUntil(n.expired_at);
    const date: string = FormatUtil.shortDate(n.expired_at);
    if (days < 0) {
      return `${date}（已过期 ${-days} 天）`;
    }
    return `${date}（剩 ${days} 天）`;
  }

  private online(): boolean {
    return NodeUtil.isOnline(this.report);
  }

  /** 空值兜底：null/undefined/空字符串 统一显示 '-'（注意：UI 中请用直接表达式 xxx || '-'，不要通过实例方法调用，否则 ArkUI 增量更新可能识别不到依赖） */
  private dash(v: string | undefined | null): string {
    return v && v.length > 0 ? v : '-';
  }

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          if (this.errorMsg.length > 0) {
            Text(`⚠ ${this.errorMsg}`)
              .fontSize(12)
              .fontColor($r('app.color.status_warn'))
              .width('100%')
          }

          // ===== 硬件概览卡 =====
          Column({ space: 10 }) {
            SectionTitle({ icon: $r('sys.symbol.square_grid_2x2'), title: '硬件概览' })

            MetricBar({
              label: 'CPU',
              percent: this.online() ? NodeUtil.cpuUsage(this.report) : -1,
              detail: this.node && this.node.cpu_name.length > 0 ? `${this.node.cpu_cores} 核 · ${this.node.cpu_name}` : ''
            })
            MetricBar({
              label: '内存',
              percent: this.online() ? NodeUtil.memPercent(this.report) : -1,
              detail: this.report ? `${FormatUtil.bytes(this.report.ram?.used ?? 0)} / ${FormatUtil.bytes(this.node?.mem_total ?? this.report.ram?.total ?? 0)}` : ''
            })
            // GPU 条常驻：在线时取不到数据按 0 显示；型号占位值统一显示「无GPU」
            MetricBar({
              label: 'GPU',
              percent: this.online() ? (this.report?.gpu ? (this.report.gpu.average_usage ?? 0) : 0) : -1,
              detail: this.gpuNameText(),
              help: 'GPU 使用率：这张显卡的平均负载，型号见下方小字。\nhyperv_drm、virtio-gpu、vmwgfx 这类是虚拟显示设备：只负责画面输出，没有计算能力，使用率恒为 0。\n无独立显卡的节点，型号处显示「无GPU」。'
            })
          }
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 系统信息卡 =====
          Column({ space: 2 }) {
            SectionTitle({ icon: $r('sys.symbol.gearshape'), title: '系统信息' })

            IconInfoRow({
              icon: $r('sys.symbol.gearshape'),
              label: '在线时长',
              value: this.online() ? FormatUtil.uptime(this.report?.uptime ?? 0) : '-'
            })
            IconInfoRow({
              icon: $r('sys.symbol.gearshape'),
              label: '负载 1/5/15min',
              value: this.report && this.report.load
                ? `${(this.report.load.load1 ?? 0).toFixed(2)} / ${(this.report.load.load5 ?? 0).toFixed(2)} / ${(this.report.load.load15 ?? 0).toFixed(2)}`
                : '-'
            })
            IconInfoRow({
              icon: $r('sys.symbol.gearshape'),
              label: '进程数',
              value: this.report ? `${this.report.process ?? 0}` : '-'
            })
            IconInfoRow({
              icon: $r('sys.symbol.gearshape'),
              label: '虚拟化',
              value: (this.node?.virtualization || '-')
            })
            IconInfoRow({
              icon: $r('sys.symbol.gearshape'),
              label: '内核',
              value: (this.node?.kernel_version || '-')
            })
            IconInfoRow({
              icon: $r('sys.symbol.gearshape'),
              label: '操作系统',
              value: (this.node?.os || '-')
            })
            IconInfoRow({
              icon: $r('sys.symbol.gearshape'),
              label: '架构',
              value: (this.node?.arch || '-')
            })
          }
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 存储信息卡 =====
          Column({ space: 10 }) {
            SectionTitle({ icon: $r('sys.symbol.square_grid_2x2'), title: '存储信息' })

            MetricBar({
              label: '磁盘',
              percent: this.online() ? NodeUtil.diskPercent(this.report) : -1,
              detail: this.report ? `${FormatUtil.bytes(this.report.disk?.used ?? 0)} / ${FormatUtil.bytes(this.node?.disk_total ?? this.report.disk?.total ?? 0)}` : ''
            })
            MetricBar({
              label: '交换分区',
              percent: this.report && this.report.swap && this.report.swap.total > 0 && this.online()
                ? Math.min(100, Math.max(0, (this.report.swap.used / this.report.swap.total) * 100))
                : -1,
              detail: this.report && this.report.swap && this.report.swap.total > 0
                ? `${FormatUtil.bytes(this.report.swap.used)} / ${FormatUtil.bytes(this.report.swap.total)}`
                : '未启用'
            })
          }
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 网络信息卡（左标签右值；下半区为网络身份：IP/ASN/厂商） =====
          Column({ space: 10 }) {
            SectionTitle({ icon: $r('sys.symbol.ohos_wifi'), title: '网络信息' })

            IconInfoRow({
              icon: $r('sys.symbol.arrow_up'),
              label: '实时上行',
              value: this.online() ? FormatUtil.bitsPerSecond(this.report?.network?.up ?? 0) : '-'
            })
            IconInfoRow({
              icon: $r('sys.symbol.arrow_down'),
              label: '实时下行',
              value: this.online() ? FormatUtil.bitsPerSecond(this.report?.network?.down ?? 0) : '-'
            })
            IconInfoRow({
              icon: $r('sys.symbol.arrow_up'),
              label: '累计发送',
              value: FormatUtil.bytes(this.report?.network?.totalUp ?? 0)
            })
            IconInfoRow({
              icon: $r('sys.symbol.arrow_down'),
              label: '累计接收',
              value: FormatUtil.bytes(this.report?.network?.totalDown ?? 0)
            })
            IconInfoRow({
              icon: $r('sys.symbol.link'),
              label: '连接',
              value: `TCP ${this.report?.connections?.tcp ?? 0} · UDP ${this.report?.connections?.udp ?? 0}`
            })

            Divider()
              .color($r('app.color.page_bg'))
              .strokeWidth(1)
              .width('100%')

            // 网络身份：外层只露一行预览（IPv4 优先），整行可点开居中弹层看全量
            // （ASN/厂商名/完整 IPv6 都可能很长，收进弹层按块折行展示）
            this.netIdentityRow()
          }
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 历史曲线卡 =====
          Column({ space: 10 }) {
            SectionTitle({ icon: $r('sys.symbol.square_grid_2x2'), title: '历史曲线' })

            Scroll() {
              Row({ space: 8 }) {
                ForEach(this.rangeLabels, (label: string, idx: number) => {
                  Text(label)
                    .fontSize(12)
                    .fontColor(this.rangeIdx === idx ? Color.White : $r('app.color.text_secondary'))
                    .backgroundColor(this.rangeIdx === idx ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.card_bg'))
                    .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                    .borderRadius(14)
                    .onClick((): void => {
                      if (this.rangeIdx !== idx) {
                        this.rangeIdx = idx;
                        this.loadHistory();
                      }
                    })
                }, (label: string) => label)
              }
              .padding({ left: 2, right: 2 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .width('100%')

            Column({ space: 8 }) {
              // 第一排：前 3 个卡片
              Row({ space: 8 }) {
                ForEach(this.metricCards.slice(0, Math.min(3, this.metricCount())), (card: MetricCardDef, idx: number) => {
                  Text(card.label)
                    .fontSize(12)
                    .fontColor(this.metricIdx === idx ? Color.White : $r('app.color.text_secondary'))
                    .backgroundColor(this.metricIdx === idx ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.card_bg'))
                    .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                    .borderRadius(14)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)
                    .onClick((): void => {
                      if (this.metricIdx !== idx) {
                        this.metricIdx = idx;
                        this.loadHistory();
                      }
                    })
                }, (card: MetricCardDef) => card.label)
              }
              .width('100%')

              // 第二排：第 4 个及以后
              if (this.metricCount() > 3) {
                Row({ space: 8 }) {
                  ForEach(this.metricCards.slice(3, this.metricCount()), (card: MetricCardDef, idx: number) => {
                    Text(card.label)
                      .fontSize(12)
                      .fontColor(this.metricIdx === idx + 3 ? Color.White : $r('app.color.text_secondary'))
                      .backgroundColor(this.metricIdx === idx + 3 ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.card_bg'))
                      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                      .borderRadius(14)
                      .layoutWeight(1)
                      .textAlign(TextAlign.Center)
                      .onClick((): void => {
                        if (this.metricIdx !== idx + 3) {
                          this.metricIdx = idx + 3;
                          this.loadHistory();
                        }
                      })
                  }, (card: MetricCardDef) => card.label)
                }
                .width('100%')
              }
            }
            .width('100%')

            if (this.historyLoading) {
              Column() {
                LoadingProgress()
                  .width(28)
                  .height(28)
                  .color($r('sys.color.ohos_id_color_emphasize'))
              }
              .width('100%')
              .height(150)
              .justifyContent(FlexAlign.Center)
            } else {
              MpLineChart({
                values: this.historyValues,
                values2: this.historyValues2,
                timestamps: this.historyTimestamps,
                unit: this.historyUnit,
                timeRangeHours: this.rangeHours[this.rangeIdx],
                lineColor: this.histColor(),
                line1Label: this.metricCards[this.metricIdx].mainLabel,
                line2Label: this.metricCards[this.metricIdx].subLabel ?? '',
                line2Color: 0xFF2FA36B,
                histTicks: this.histTicks,
                emptyText: this.historyError.length > 0 ? this.historyError : '暂无数据'
              })
              .margin({ top: 60 })
            }

            Row({ space: 8 }) {
              Text(this.histSummary('当前', this.histCurrent))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.histSummary('最小', this.histMin))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.histSummary('最大', this.histMax))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.histSummary('平均', this.histAvg))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
          }
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 主机与账单卡 =====
          Column({ space: 2 }) {
            SectionTitle({ icon: $r('sys.symbol.gearshape'), title: '主机与账单' })

            IconInfoRow({
              icon: $r('sys.symbol.gearshape'),
              label: '地区',
              value: (this.node?.region || '-')
            })
            IconInfoRow({
              icon: $r('sys.symbol.gearshape'),
              label: '分组',
              value: (this.node?.group || '-')
            })
            if (NodeUtil.tagList(this.node?.tags ?? '').length > 0) {
              IconInfoRow({
                icon: $r('sys.symbol.gearshape'),
                label: '标签',
                value: NodeUtil.tagList(this.node?.tags ?? '').join(' / ')
              })
            }
            if (this.priceLine().length > 0) {
              IconInfoRow({
                icon: $r('sys.symbol.gearshape'),
                label: '价格',
                value: this.priceLine()
              })
            }
            if (this.expireLine().length > 0) {
              IconInfoRow({
                icon: $r('sys.symbol.gearshape'),
                label: '到期',
                value: this.expireLine()
              })
            }
          }
          .padding(14)
          .borderRadius(20)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')
        }
        .padding({ left: 16, right: 16, bottom: 20 })
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .clip(false)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: {
        title: {
          mainTitle: this.node?.name ?? this.uuid,
          subTitle: this.online() ? `在线 · 更新于 ${this.updatedAtText}` : '离线'
        },
        backIcon: {
          icon: $r('sys.symbol.arrow_left'),
          action: (): void => { router.back(); }
        }
      },
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .backgroundColor($r('app.color.page_bg'))
  }
}

/**
 * 网络身份弹层：居中卡片，CustomDialog 默认自带"缩放+淡入"张开动画。
 * 字段块 = 小灰标签 + 完整值（layoutWeight 限宽自动折行，长 IPv6 不会把复制图标顶出界），
 * 点值或点右侧复制图标都写入系统剪贴板，顶部绿色气泡"复制成功"淡入淡出。
 * 取值是打开瞬间的快照（控制器每次打开前现建），点蒙层或右上角圆形叉号关闭。
 */
@CustomDialog
struct NetIdentityDialog {
  controller?: CustomDialogController;
  ip4: string = '—';
  ip6: string = '—';
  asn: string = '—';
  org: string = '—';
  @State copied: boolean = false;
  private copiedTimer: number = -1;

  aboutToDisappear(): void {
    if (this.copiedTimer >= 0) {
      clearTimeout(this.copiedTimer);
      this.copiedTimer = -1;
    }
  }

  /** 写系统剪贴板；成功后顶部弹绿色气泡，1.2s 后淡出 */
  private copyValue(value: string): void {
    if (value.length === 0 || value === '—') {
      return;
    }
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value);
      pasteboard.getSystemPasteboard().setData(data)
        .then((): void => {
          this.copied = true;
          if (this.copiedTimer >= 0) {
            clearTimeout(this.copiedTimer);
          }
          this.copiedTimer = setTimeout((): void => {
            this.copied = false;
            this.copiedTimer = -1;
          }, 1200);
        })
        .catch((_e: Object): void => {
          // 剪贴板写入失败静默
        });
    } catch (e) {
      // 环境异常静默
    }
  }

  /** 单个字段块：标签行 + 值行（值限宽折行，点值或点复制图标都复制） */
  @Builder
  fieldBlock(label: string, value: string) {
    Column({ space: 3 }) {
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
      Row({ space: 6 }) {
        Text(value)
          .fontSize(14)
          .lineHeight(20)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.doc_text_on_doc_text'))
          .fontSize(14)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .alignItems(VerticalAlign.Top)
      .width('100%')
      .onClick((): void => {
        this.copyValue(value);
      })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column({ space: 14 }) {
        // 标题行 + 右上角圆形叉号
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.cloud'))
            .fontSize(16)
            .fontColor([$r('sys.color.ohos_id_color_emphasize')])
          Text('网络身份')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Stack() {
            Circle({ width: 28, height: 28 })
              .fill($r('app.color.page_bg'))
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(12)
              .fontColor([$r('app.color.text_secondary')])
          }
          .onClick((): void => {
            this.controller?.close();
          })
        }
        .width('100%')

        this.fieldBlock('IPv4', this.ip4)
        this.fieldBlock('IPv6', this.ip6)
        this.fieldBlock('ASN', this.asn)
        this.fieldBlock('厂商', this.org)

        Text('轻触内容可复制')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .padding(20)
      .borderRadius(24)
      .backgroundColor($r('app.color.card_bg'))
      .width('92%')

      // 顶部"复制成功"绿色气泡：绿底白字与卡片底色拉开层次，淡入淡出
      if (this.copied) {
        Text('复制成功')
          .fontSize(12)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.status_ok'))
          .borderRadius(999)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .shadow({ radius: 8, color: 'rgba(0,0,0,0.12)', offsetY: 2 })
          .margin({ top: 12 })
          .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
      }
    }
    .width('100%')
  }
}
