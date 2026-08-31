# Komari Client for HarmonyOS

在手机上查看 [Komari](https://github.com/komari-monitor/komari) 服务器监控数据的原生客户端，
基于 HarmonyOS / ArkTS 编写。

> 状态：**地基阶段**。数据层、认证层、存储层已完成，UI 尚未开始。

## 这是什么

Komari 是一个自托管的轻量级服务器监控方案（Go 后端 + Agent 上报 + Web 面板）。
本项目把它的核心监控能力搬到手机上：随时看每台机器的 CPU、内存、磁盘、实时网速，
以及 Ping 延迟与丢包。

## 当前进度

| 层 | 内容 | 状态 |
| --- | --- | --- |
| 数据契约 | `model/KomariTypes.ets` | 已完成 |
| 网络层 | `service/RpcClient.ets` | 已完成 |
| 接口封装 | `service/KomariApi.ets` | 已完成 |
| 凭据存储 | `storage/SecretStore.ets` | 已完成 |
| 配置存储 | `storage/ServerStore.ets` | 已完成 |
| 认证服务 | `service/AuthService.ets` | 已完成 |
| 装配点 | `common/ServiceRegistry.ets` | 已完成 |
| 格式化 | `common/FormatUtil.ets` | 已完成 |
| UI | 连接页 / 节点列表 / 详情 / Ping / 设置 | 未开始 |

## 技术选型

- **语言**：ArkTS
- **SDK**：HarmonyOS `6.1.1(24)`，target 与 compatible 均为 API 24
- **网络**：`@kit.NetworkKit`
- **凭据存储**：`@kit.AssetStoreKit`（关键资产存储，系统级加密）
- **配置存储**：`@kit.ArkData`（Preferences）

## 架构

```
model/       数据契约，后端字段的唯一映射处
service/
  RpcClient  JSON-RPC 2.0 传输，鉴权头由外部注入
  KomariApi  11 个 public 方法 + 4 个自省方法的类型化封装
  AuthService 登录态建立、恢复、失效处理
storage/
  SecretStore  session / 密码 / API Key（加密）
  ServerStore   服务端列表与应用偏好（明文）
common/
  ServiceRegistry  全局装配，换实现只改这里
  FormatUtil       纯函数格式化
pages/        UI（待建）
components/   复用组件（待建）
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
