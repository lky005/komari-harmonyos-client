/**
 * Komari 客户端数据契约
 *
 * 字段来源（按可靠度）：
 *   1. protocol/v2/jsonrpc.go    —— 实时上报结构 Report
 *   2. database/models/models.go —— Client / Record
 *   3. internal/metricstore/metrics.go —— 指标键常量
 *   4. web/rpc/jsonrpc/public.metric.go —— 指标查询响应
 *
 * 维护约定：
 *   - 本文件是后端契约，任何字段变动都会向下影响所有页面
 *   - 修改前务必对照服务端对应版本的源码，不要在 UI 层临时补字段
 *   - 服务端返回的 null 在 ArkTS 侧统一用 0 / '' 兜底，见 parse 处注释
 */

// ============================================================
// JSON-RPC 2.0 信封
// ============================================================

export interface JsonRpcRequest {
  jsonrpc: string;
  method: string;
  /** 可省略；ArkTS 下不要给它传未声明类型的对象字面量 */
  params?: Object;
  id: number;
}

/**
 * 各 RPC 方法的参数形状。
 * ArkTS 的 arkts-no-untyped-obj-literals 规则要求对象字面量
 * 必须对应显式声明的类型，所以每个不同参数的调用都要先声明一个接口，
 * 不能把 { key: value } 直接内联传给 call()。
 */
export interface RpcMethodListParams {
  internal: boolean;
}

export interface UuidParams {
  uuid: string;
}

export interface PingRecordsParams {
  uuid: string;
  task_id: string;
  hours: string;
}

/** POST /api/login 的请求体 */
export interface LoginRequestBody {
  username: string;
  password: string;
  '2fa_code': string;
}

export interface JsonRpcErrorPayload {
  code: number;
  message: string;
  data: Object;
}

export interface JsonRpcResponse<T> {
  jsonrpc: string;
  result: T;
  error: JsonRpcErrorPayload;
  id: number;
}

// ============================================================
// 节点（Client）
// 注意：游客身份下 ipv4 / ipv6 / remark / version / token 会被服务端清空，
//       hidden = true 的节点会被剔除，因此这些字段不在此契约中。
// ============================================================

export interface KomariClient {
  uuid: string;
  name: string;
  cpu_name: string;
  virtualization: string;
  arch: string;
  cpu_cores: number;
  cpu_physical_cores: number;
  os: string;
  kernel_version: string;
  gpu_name: string;
  region: string;
  public_remark: string;
  mem_total: number;
  swap_total: number;
  disk_total: number;
  weight: number;
  price: number;
  billing_cycle: number;
  auto_renewal: boolean;
  currency: string;
  expired_at: string; // *time.Time，可能为 ''
  group: string;
  tags: string; // 以 ';' 分隔
  hidden: boolean;
  traffic_limit: number;
  traffic_limit_type: string; // sum | max | min | up | down
  created_at: string;
  updated_at: string;
}

// ============================================================
// 实时数据（public:getClientRecentRecords → []v2.Report）
// 返回的是数组，按时间升序，通常取最后一个元素作为最新快照
// ============================================================

export interface CpuReport {
  name: string;
  cores: number;
  arch: string;
  usage: number; // 0 ~ 100
}

export interface RamReport {
  total: number;
  used: number;
}

export interface LoadReport {
  load1: number;
  load5: number;
  load15: number;
}

export interface DiskReport {
  total: number;
  used: number;
}

export interface NetworkReport {
  up: number;
  down: number;
  totalUp: number; // 注意：驼峰，非 snake_case
  totalDown: number;
}

export interface ConnectionsReport {
  tcp: number;
  udp: number;
}

export interface GpuDeviceInfo {
  name: string;
  memory_total: number;
  memory_used: number;
  utilization: number;
  temperature: number;
}

export interface GpuDetailReport {
  count: number;
  average_usage: number;
  detailed_info: GpuDeviceInfo[];
}

export interface ClientReport {
  uuid: string;
  cpu: CpuReport;
  ram: RamReport;
  swap: RamReport;
  load: LoadReport;
  disk: DiskReport;
  network: NetworkReport;
  connections: ConnectionsReport;
  gpu: GpuDetailReport; // 可能为 undefined（无 GPU）
  uptime: number;
  process: number;
  message: string;
  method: string;
  updated_at: string;
}

// ============================================================
// 指标（public:listMetricDefinitions / public:queryMetrics）
// ============================================================

export interface MetricDefinition {
  name: string;
  type: string; // gauge | counter
  unit: string; // % | bytes | bytes/s | ms | count | ratio | °C
  description: string;
  retention_days: number;
}

export interface MetricPoint {
  time: string;
  value: number; // *float64，服务端可能返回 null → 解析时兜底为 0
  count: number;
  tags: Record<string, string>;
  labels: Record<string, string>;
}

export interface MetricSeries {
  metric_key: string;
  entity_id: string;
  type: string;
  unit: string;
  retention_days: number;
  tags: Record<string, string>;
  downsampled: boolean;
  downsample_algorithm: string;
  fill_empty: boolean;
  max_points: number;
  interval_seconds: number;
  count: number;
  points: MetricPoint[];
}

// ============================================================
// Ping（public:getPublicPingTasks / getPingMetricStats / getPingRecords）
// ============================================================

/** public:getPublicPingTasks 的返回元素 */
export interface PingTask {
  id: number;
  weight: number;
  name: string;
  clients: string[];
  default_on: boolean;
  type: string;
  interval: number;
}

/**
 * public:getPingRecords 的返回
 * 注意：records[].value < 0 表示丢包，不是负延迟，判断时必须先过滤
 */
export interface PingRecordItem {
  task_id: number;
  time: string;
  value: number;
  client: string;
}

export interface PingClientBasicInfo {
  client: string;
  loss: number;
  min: number;
  max: number;
}

export interface PingRecordsResponse {
  count: number;
  basic_info: PingClientBasicInfo[];
  records: PingRecordItem[];
  tasks: Record<string, Object>[];
}

/** public:getPingMetricStats 的返回 */
export interface PingMetricStatsResponse {
  start: string;
  end: string;
  interval_seconds: number;
  stats: PingTaskStats[];
  count: number;
}

export interface PingTaskStats {
  entity_id: string;
  task_id: string;
  name: string;
  type: string;
  interval: number;
  total: number;
  valid: number;
  loss: number;
  loss_approximate: boolean;
  min: number;
  max: number;
  avg: number;
  latest: number;
  p50: number;
  p99: number;
  stddev: number;
  p99_p50_ratio: number;
}

// ============================================================
// 站点与身份
// ============================================================

export interface PublicSettings {
  private_site: boolean; // 决定游客能否访问节点数据
  name: string;
  description: string;
}

export interface VersionInfo {
  version: string;
  hash: string;
}

export interface MeInfo {
  username: string;
  logged_in: boolean;
  uuid: string;
  sso_type: string;
  sso_id: string;
}

export interface LoginResult {
  sessionToken: string;
  expireAt: number; // 本地推算的时间戳（毫秒）
}

// ============================================================
// 本地配置（不来自服务端）
// ============================================================

export enum AuthMode {
  Guest = 'guest',
  Password = 'password',
  ApiKey = 'apikey'
}

export interface ServerConfig {
  id: string; // host:port 的稳定标识
  name: string;
  baseUrl: string; // 例如 https://komari.example.com
  authMode: AuthMode;
  username: string; // 仅 Password 模式使用
  rememberPassword: boolean;
}
