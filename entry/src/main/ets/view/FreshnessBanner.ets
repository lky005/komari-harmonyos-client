/**
 * FreshnessBanner —— 断网 / 数据陈旧的统一提示条（跨页面共享）
 *
 * 存在意义：把「连接状态」与「数据新鲜度」两件事用同一种视觉语言表达，
 * 并且**只有这一份文案逻辑** —— NodesPage / PingPage / NodeDetailPage 复用同一组件，
 * 结构上就不可能再出现"某个页面忘了提示"或"提示口径不一致"。
 *
 * 视觉：内联在列表里（跟随滚动），不吸顶、不遮罩、不弹窗。只有一种配色：
 *   连接不可见（断网 / 降级 / 数据陈旧）→ 中性灰
 *
 * **本组件不承担「硬过期」态**。硬过期时内容区已被 expiredCard 空态接管，且空态自带
 * 「重新连接」—— 再叠一条提示条就是同一件事说两遍、两个按钮做同一件事。因此调用方
 * （NodesPage / PingPage）在 dataExpired 时直接不渲染本组件；红色的「数据已过期」语义
 * 由 expiredCard 的图标与标题承载。
 * 原先的 expired 入参随之移除 —— 抑制之后它恒为 false，是死参数。
 *
 * 形态对齐卡片语言：中性极浅底 + 左侧 3vp 状态色条 + 8vp 状态圆点 + 圆角 20。
 * 状态圆点与 NodeCard 的在线点、MainPage 的健康灯共用同一套「8vp 实心圆 = 状态」词汇。
 *
 * 刻意不用红色表达"断网"：红色在本项目里是「节点故障」的语义，
 * 混用会让用户把"我看不到"误读成"服务器挂了"。
 * 也刻意不用琥珀：琥珀已被「配置警告」(status_warn) 与「部分节点在线」(health_partial)
 * 占用，再叠加会让用户无法凭颜色建立直觉。
 * 走灰的第二个理由是自洽 —— MainPage.getHealthColor() 在断网/降级时本就返回
 * health_none(#94A3B8)，两处必须同值同义。
 *
 * 用法：
 *   if (FreshnessUtil.shouldShow(state, lastSuccessAt)) {
 *     FreshnessBanner({ state, lastSuccessAt, onRetry: () => {...} })
 *   }
 * 注意必须由调用方用 if 包裹：List 的 space 会给空组件留出间距。
 * 有过期空态的页面（NodesPage / PingPage）还要再叠加 !dataExpired 的判断，见 showBanner()。
 */

import { ConnectivityState } from '../common/NodeDataStore';

/** 数据年龄超过该阈值即视为「陈旧」，开始提示 */
const STALE_MS: number = 5 * 60 * 1000;

/**
 * 提示条出现 / 消失的转场：淡入 + 轻微下移。
 *
 * 为什么不直接在组件上挂 transition：提示条是插在 List 首个 ListItem 里的，
 * 出现/消失会让下方内容整体位移。纯淡入配合布局位移已经足够柔和；
 * 这里返回新实例而不是共享常量 —— TransitionEffect 带内部状态，跨页面复用同一实例不安全。
 * 调用方需包一层容器再把 transition 挂上去（自定义组件对通用属性的支持面较窄）。
 */
export function freshnessTransition(): TransitionEffect {
  return TransitionEffect.OPACITY
    .combine(TransitionEffect.translate({ y: -8 }))
    .animation({ duration: 200, curve: Curve.EaseInOut });
}

/**
 * 提示条的判定与文案工具。
 * 抽成独立类是为了让调用方能先判定再决定是否渲染组件（见文件头说明）。
 */
export class FreshnessUtil {
  /**
   * 是否需要展示提示条。
   *
   * **刻意不含 dataExpired 判断**：有过期空态的页面（NodesPage / PingPage）需要额外抑制，
   * 而 NodeDetailPage 没有过期空态 —— 提示条是那里唯一的连接信号，必须保留。
   * 抑制逻辑因此放在各页面的 showBanner() 里，而不是收进本方法。
   */
  static shouldShow(state: ConnectivityState, lastSuccessAt: number): boolean {
    if (state === ConnectivityState.Offline || state === ConnectivityState.Degraded) {
      return true;
    }
    if (lastSuccessAt <= 0) {
      return false;
    }
    return Date.now() - lastSuccessAt > STALE_MS;
  }

  /** 数据年龄文案：'刚刚' / '5 分钟前' / '3 小时前' / '2 天前'；未知返回空串 */
  static ageText(lastSuccessAt: number): string {
    if (lastSuccessAt <= 0) {
      return '';
    }
    const ms: number = Date.now() - lastSuccessAt;
    if (ms < 60 * 1000) {
      return '刚刚';
    }
    const min: number = Math.floor(ms / 60000);
    if (min < 60) {
      return `${min} 分钟前`;
    }
    const hour: number = Math.floor(min / 60);
    if (hour < 24) {
      return `${hour} 小时前`;
    }
    return `${Math.floor(hour / 24)} 天前`;
  }

  /**
   * 提示条主文案。
   * 三种连接状态各自措辞不同 —— 对用户的行动指引不同：
   *   离线 = 你的设备没网；降级 = 服务端暂时联系不上；在线但陈旧 = 数据老了。
   */
  static message(state: ConnectivityState, lastSuccessAt: number): string {
    const age: string = FreshnessUtil.ageText(lastSuccessAt);
    const tail: string = age.length > 0 ? ` · 数据更新于 ${age}` : '';
    if (state === ConnectivityState.Offline) {
      return `网络已断开${tail}`;
    }
    if (state === ConnectivityState.Degraded) {
      return `服务端暂时无法连接${tail}`;
    }
    return age.length > 0 ? `数据更新于 ${age}` : '数据待更新';
  }
}

@Component
export struct FreshnessBanner {
  /** 全局连接状态（来自 NodeDataStore.getConnectivityState()） */
  @Prop state: ConnectivityState = ConnectivityState.Online;
  /** 最近一次成功拉取的时刻（来自 NodeDataStore.getLastSuccessAt()） */
  @Prop lastSuccessAt: number = 0;
  /** 点击「重试」的回调 */
  onRetry: () => void = (): void => {};

  build() {
    // 外层容器只负责底色 + 圆角 + 裁剪。不能用 .border({ width: { left: 3 } }) 画左色条：
    // 单边描边会沿圆角路径绘制，在两个左侧弧段堆出楔形填充（横幅左上/左下角的异常色块）。
    // 色条改为真实子组件，弧段由容器 borderRadius + clip 裁出，与 LineChart 同一手法。
    Row() {
      // 左侧 3vp 状态色条：满高贯穿，两端圆角由容器裁剪给出
      Column()
        .width(3)
        .height('100%')
        .backgroundColor($r('app.color.offline_bar'))

      Row({ space: 8 }) {
        // 状态圆点：与 NodeCard 的在线点、MainPage 的健康灯同一套「8vp 实心圆 = 状态」词汇
        Circle({ width: 8, height: 8 })
          .fill($r('app.color.offline_bar'))

        Text(FreshnessUtil.message(this.state, this.lastSuccessAt))
          .fontSize(12)
          .fontColor($r('app.color.offline_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        // 「重试」是操作项、不是状态，走主色 chip（与 NodesPage.groupChip 同语言）。
        // chip 自身只有 26 高，外层 Row 补 9+9 撑到 44 触控高度。
        Row() {
          Text('重试')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_emphasize'))
            .backgroundColor($r('app.color.accent_soft'))
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(14)
        }
        .padding({ top: 9, bottom: 9 })
        .onClick((): void => {
          this.onRetry();
        })
      }
      // 9 + 色条 3 = 12：内容左缘与旧版 padding(12) 对齐
      .padding({ left: 9, right: 8 })
      .height('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    // 44 = chip 26 + 上下 9×2：维持旧版总高与触控高度；
    // 色条与内容行的 height('100%') 拉伸也需要确定的父高，不能用自适应撑开
    .height(44)
    .backgroundColor($r('app.color.offline_bg'))
    .borderRadius(20)
    .clip(true)
    .alignItems(VerticalAlign.Center)
  }
}
