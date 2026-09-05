# Komari Client for HarmonyOS

在手机上查看 [Komari](https://github.com/komari-monitor/komari) 服务器监控数据的原生客户端，
基于 HarmonyOS / ArkTS 编写。

> 状态：**功能基本成型**。地基层 + UI 三轮全部完成，沉浸光感 UI 已完成真机调优（三 Tab 头部统一、渐变模糊、材质等级），详见 `内部记录` 第 10 节。

## 这是什么

Komari 是一个自托管的轻量级服务器监控方案（Go 后端 + Agent 上报 + Web 面板）。
本项目把它的核心监控能力搬到手机上：随时看每台机器的 CPU、内存、磁盘、实时网速，
以及 Ping 延迟与丢包。

## 当前进度

| 层 | 内容 | 状态 |
| --- | --- | --- |
| 数据契约 | `model/KomariTypes.ets` | 已完成 |
| 网络层 | `service/RpcClient.ets`（JSON-RPC 2.0） | 已完成 |
| 接口封装 | `service/KomariApi.ets`（11 个 public 方法） | 已完成 |
| 凭据存储 | `storage/SecretStore.ets`（系统级加密 Asset） | 已完成 |
| 配置存储 | `storage/ServerStore.ets`（Preferences） | 已完成 |
| 认证服务 | `service/AuthService.ets`（登录/静默重登/会话探测/API Key） | 已完成 |
| 装配点 | `common/ServiceRegistry.ets` | 已完成 |
| 工具 | `common/FormatUtil.ets` / `common/NodeUtil.ets` | 已完成 |
| UI — 启动 | `Index.ets`（路由分发 + 登录态自动恢复） | 已完成 |
| UI — 连接 | `ConnectPage.ets`（引导页：协议按钮 + 域名输入 + 探测防错 + 跳过；兼作添加服务端） | 已完成 |
| UI — 主框架 | `MainPage.ets`（三 Tab + 登录态提示 + 过期提醒） | 已完成 |
| UI — 节点列表 | `NodesPage.ets`（5s 轮询 + 实时指标卡片） | 已完成 |
| UI — 节点详情 | `NodeDetailPage.ets`（实时区 + mpchart 历史曲线 8 指标 × 4 时段） | 已完成 |
| UI — Ping | `PingPage.ets` / `PingDetailPage.ets`（任务列表 + 延迟折线 + 丢包统计） | 已完成 |
| UI — 登录 | `AuthPage.ets`（账号密码 / API Key / 记住密码；2FA 已移除） | 已完成 |
| UI — 服务端管理 | `ServerManagePage.ets`（编辑弹层：信息 + 账号 + 切换一体 / 添加 / 删除清凭据） | 已完成 |
| UI — 设置 | `SettingsPane.ets`（展示卡 + 入口卡）/ `RefreshPerfPage.ets`（刷新性能二级页） | 已完成 |
| UI — 复用组件 | `view/MpLineChart.ets` / `view/LineChart.ets`（自绘） / `view/NodeCard.ets` / `view/MetricBar.ets` / `view/UrlInput.ets` / `view/LoginForm.ets` / `view/ServerEditSheet.ets` | 已完成 |
| 沉浸光感 | API 24 规范重构（HdsNavigation 穿透 + 动态 bindToScrollable + ADAPTIVE 材质） | 已完成 |
| 构建与签名 | 调试签名已配置，产出 `entry-default-signed.hap`（0 错误） | 已完成 |
| 真机验证 | 无线推送安装 `192.0.2.1:40977`，成功调起 EntryAbility 运行 | **已验证运行** |

## 技术选型

- **语言**：ArkTS
- **SDK**：HarmonyOS `6.1.1(24)`，target 与 compatible 均为 API 24
- **网络**：`@kit.NetworkKit`
- **图表**：`@ohos/mpchart`（折线图渲染）
- **凭据存储**：`@kit.AssetStoreKit`（关键资产存储，系统级加密）
- **配置存储**：`@kit.ArkData`（Preferences）

## 架构

```
model/       数据契约，后端字段的唯一映射处
service/
  RpcClient  JSON-RPC 2.0 传输，鉴权头由外部注入
  KomariApi  11 个 public 方法 + 4 个自省方法的类型化封装
  AuthService 登录态建立、恢复、失效处理（含静默重登）
storage/
  SecretStore  session / 密码 / API Key（系统级加密 Asset）
  ServerStore   服务端列表与应用偏好（Preferences 明文）
common/
  ServiceRegistry  全局装配，换实现只改这里
  NodeDataStore    节点动静数据仓库 + 轮询/缓存偏好（PollConfig）
  PingRecordStore  Ping 详情记录进程内缓存（SWR，按 serverId 隔离）
  FormatUtil       纯函数格式化
  NodeUtil         节点状态/在线判断工具
pages/
  Index            启动路由，自动恢复登录态（支持跳过配置的空态直入）
  ConnectPage      首启引导 / 添加服务端（协议按钮 + 域名输入 + 探测防错 + 跳过）
  MainPage         三 Tab 主框架（节点 / Ping / 设置）
  NodesPage        节点列表，5s 轮询实时指标
  NodeDetailPage   节点详情 + 历史曲线（8 指标 × 1h/6h/24h/7d）
  PingPage         Ping 任务列表（整卡可点进对应任务详情）
  PingDetailPage   Ping 详情（延迟折线 + 丢包统计 + 服务端聚合，缓存有效期内秒开）
  AuthPage         登录（账号密码 / API Key / 记住密码；2FA 已移除）
  ServerManagePage 多服务端管理（编辑弹层：信息 + 账号 + 切换一体 / 添加 / 删除清凭据）
  RefreshPerfPage  刷新与性能设置二级页（轮询频率 / 并发 / Ping 缓存）
view/
  MpLineChart      mpchart 封装折线图（NodeDetail / PingDetail 使用）
  LineChart        自绘折线图（面积填充 + 描边；暂无业务页引用，演示页已移出仓库，见 内部记录 第 15 节）
  NodeCard         节点卡片
  MetricBar        指标进度条
  UrlInput         协议按钮 + 域名输入（粘贴解析 / host 校验 / http·内网提醒）
  LoginForm        账号密码表单 + 记住密码安全说明（AuthPage / ServerEditSheet 复用）
  ServerEditSheet  服务端编辑半模态弹层（信息 + 账号 + 保存并切换）
```

依赖方向严格单向：`pages → service → storage / model`。
`model` 不依赖任何层，改动它会影响全局，修改前请对照服务端源码。

## 接口使用范围

本项目只使用 Komari 的**免登录公开接口**（`public:*` 命名空间），
不触碰任何需要管理员权限的写操作。

- `public:getPublicSettings` / `getVersion` / `getMe`
- `public:getNodesInformation` / `getClientRecentRecords`
- `public:listMetricDefinitions` / `queryMetrics`
- `public:getPublicPingTasks` / `getPingMetricStats` / `getPingRecords`
- `rpc.ping` / `rpc.methods`（自省与健康检查）

若服务端开启了「私有站点」，匿名用户会被拦截，此时客户端会引导用户登录。

## 登录与凭据

- 会话 token 存于系统关键资产存储（`AssetStoreKit`），不落明文
- 支持「记住密码」，在会话过期后静默重登，避免频繁输入
- 支持 API Key 方式（`Authorization: Bearer`），配置一次长期有效
- 开启 2FA 的账号无法静默重登，会要求输入验证码

## 构建

1. DevEco Studio 打开本目录
2. 等待 `oh_modules` 同步完成
3. 连接真机或启动模拟器，运行 `entry`

要求 DevEco Studio 及 HarmonyOS SDK 版本支持 API 24。

## 相关文档

- 设计文档：`docs/komari-client-design.md`
- 维护与踩坑记录：`内部记录`（内部用）

## 许可

上游 Komari 使用 MIT 许可，本项目同样采用 MIT。
