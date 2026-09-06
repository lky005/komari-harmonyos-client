/**
 * KomariApi —— 对 RpcClient 的一层薄封装，把方法名和参数形状固定下来
 *
 * 覆盖全部 11 个 public 方法 + 4 个 rpc.* 自省方法。
 * 只放"拼参数 + 声明返回类型"，不放业务逻辑，业务在页面/viewmodel 里写。
 *
 * 维护约定：
 *   - 新增接口在这里加方法即可，RpcClient 不用动
 *   - 所有方法名以 'public:' 开头的方法对游客开放；需要登录的方法请加注释说明
 */

import { RpcClient } from './RpcClient';
import {
  ClientReport,
  CommonNodeParams,
  KomariClient,
  KomariClientWithIp,
  MeInfo,
  MetricDefinition,
  MetricSeries,
  PingMetricStatsResponse,
  PingRecordsParams,
  PingRecordsResponse,
  PingTask,
  PublicSettings,
  RpcMethodListParams,
  UuidParams,
  VersionInfo
} from '../model/KomariTypes';

/** 指标查询参数（public:queryMetrics） */
export interface QueryMetricsParams {
  /** 单个指标键；与 metric_keys 二选一 */
  metric_key?: string;
  /** 多个指标键，一次查多条曲线 */
  metric_keys?: string[];
  /** 节点 UUID；与 entity_ids 二选一 */
  entity_id?: string;
  entity_ids?: string[];
  /** 时间范围，与 start/end 二选一；数值型（getPingRecords 的 hours 才是字符串） */
  hours?: number;
  start?: string;
  end?: string;
  /** 返回点上限，默认 500 */
  max_points?: number;
  /** 聚合算法，例如 avg / max / min */
  aggregation?: string;
  algorithm?: string;
  fill_empty?: boolean;
}

/**
 * Ping 统计参数（public:getPingMetricStats）。
 * 服务端 task_id/task_ids 是 any，数字字符串都收；此处按数字传。
 */
export interface PingStatsParams {
  hours?: number;
  task_id?: number;
  task_ids?: number[];
  entity_id?: string;
  entity_ids?: string[];
  max_points?: number;
}

export class KomariApi {
  private rpc: RpcClient;

  constructor(rpc: RpcClient) {
    this.rpc = rpc;
  }

  // ===== 自省与健康检查（guest 可用） =====

  /** 连通性自检，正常返回 'pong' */
  async ping(): Promise<string> {
    return await this.rpc.call<string>('rpc.ping');
  }

  /** 列出服务端当前可调用的方法名 */
  async listMethods(includeInternal: boolean = false): Promise<string[]> {
    const params: RpcMethodListParams = { internal: includeInternal };
    return await this.rpc.call<string[]>('rpc.methods', params);
  }

  // ===== 站点与身份 =====

  async getVersion(): Promise<VersionInfo> {
    return await this.rpc.call<VersionInfo>('public:getVersion');
  }

  /** 必须先调这个方法判断是否私有站点，再决定要不要引导登录 */
  async getPublicSettings(): Promise<PublicSettings> {
    return await this.rpc.call<PublicSettings>('public:getPublicSettings');
  }

  /** 未登录时返回 { username: 'Guest', logged_in: false } */
  async getMe(): Promise<MeInfo> {
    return await this.rpc.call<MeInfo>('public:getMe');
  }

  // ===== 节点 =====

  /**
   * 节点列表。
   * 游客身份下：隐藏节点被剔除，ipv4/ipv6/remark/version/token 被清空。
   */
  async getNodes(): Promise<KomariClient[]> {
    return await this.rpc.call<KomariClient[]>('public:getNodesInformation');
  }

  /**
   * common:getNodes 单节点查询（common 组，游客可调，1.4.3+）。
   * 与 getNodes 的区别：ipv4/ipv6 不被无条件清空——管理员/API Key 拿完整 IP，
   * 游客由服务端设置 send_ip_addr_to_guest 决定打码（1.*.*.*）或清空。
   * 私有站点模式可能对游客拒权（-32041），调用方必须 catch。
   */
  async getCommonNode(uuid: string): Promise<KomariClientWithIp> {
    const params: CommonNodeParams = { uuid: uuid };
    return await this.rpc.call<KomariClientWithIp>('common:getNodes', params);
  }

  /**
   * 节点最近上报快照，返回数组（按时间升序），取最后一个即最新。
   * 建议详情页以 1s 间隔轮询。
   */
  async getClientRecentRecords(uuid: string): Promise<ClientReport[]> {
    const params: UuidParams = { uuid: uuid };
    return await this.rpc.call<ClientReport[]>('public:getClientRecentRecords', params);
  }

  // ===== 指标与历史曲线 =====

  /** 指标定义，建议在进入详情页时拉一次并缓存，单位不要硬编码 */
  async listMetricDefinitions(): Promise<MetricDefinition[]> {
    return await this.rpc.call<MetricDefinition[]>('public:listMetricDefinitions');
  }

  /** 历史曲线数据 */
  async queryMetrics(params: QueryMetricsParams): Promise<MetricSeries[]> {
    return await this.rpc.call<MetricSeries[]>('public:queryMetrics', params as Object);
  }

  // ===== Ping =====

  /** Ping 任务列表 */
  async getPublicPingTasks(): Promise<PingTask[]> {
    return await this.rpc.call<PingTask[]>('public:getPublicPingTasks');
  }

  /**
   * Ping 统计聚合（min/max/avg/p50/p99/stddev/丢包）
   * 比 getPingRecords 轻量，列表页优先用这个。
   * 注意：返回的 stats[].min/max/avg 等是 *float64 + omitempty，可能缺失，渲染前判空。
   */
  async getPingMetricStats(params: PingStatsParams): Promise<PingMetricStatsResponse> {
    return await this.rpc.call<PingMetricStatsResponse>('public:getPingMetricStats', params as Object);
  }

  /**
   * Ping 原始记录。
   * 注意 records[].value < 0 表示丢包，渲染折线前必须过滤或转成断点
   */
  async getPingRecords(uuid: string, taskId: string, hours: number): Promise<PingRecordsResponse> {
    const params: PingRecordsParams = {
      uuid: uuid,
      task_id: taskId,
      hours: `${hours}`
    };
    return await this.rpc.call<PingRecordsResponse>('public:getPingRecords', params);
  }
}
