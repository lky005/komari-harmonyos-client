/**
 * AppKeys —— AppStorage 全局 key 集中注册
 *
 * 所有 @StorageProp / @StorageLink / AppStorage.setOrCreate 必须引用此处常量，
 * 禁止在业务代码中直接写字面量字符串。
 *
 * 新增 key 时：
 *   1. 在此处添加 static readonly 常量
 *   2. 注释说明写入方和读取方
 *   3. 命名用大写下划线，值保持与历史一致（避免旧版本数据丢失）
 */
export class AppKeys {
  /** 搜索关键词：MainPage 搜索框写入，NodesPage 读取过滤 */
  static readonly SEARCH_KEYWORD = 'search_keyword';

  /** 服务端切换序列号：ServerManagePage/ConnectPage 写入，NodesPage/PingPage @Watch 监听 */
  static readonly SERVER_SEQ = 'komari_server_seq';

  /** 节点总数：NodesPage 写入，MainPage 健康指示灯读取 */
  static readonly NODES_TOTAL = 'komari_nodes_total';

  /** 在线节点数：NodesPage 写入，MainPage 健康指示灯读取 */
  static readonly NODES_ONLINE = 'komari_nodes_online';

  /** 状态栏高度(vp)：EntryAbility 沉浸式窗口写入，页面顶部占位计算 */
  static readonly STATUS_BAR_HEIGHT = 'app_status_bar_height_vp';

  /** 底部导航条高度(vp)：EntryAbility 沉浸式窗口写入，页面底部避让计算 */
  static readonly NAV_INDICATOR_HEIGHT = 'app_nav_indicator_height_vp';

  /** 应用前后台状态：EntryAbility.onForeground/onBackground 写入，各页面轮询检查 */
  static readonly APP_FOREGROUND = 'app_foreground';
}
