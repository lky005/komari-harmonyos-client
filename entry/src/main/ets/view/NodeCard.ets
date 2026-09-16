/**
 * NodeCard —— 节点列表卡片（订阅模式）
 *
 * 展示：在线状态、名称、地区/分组、系统信息、CPU/内存/磁盘三条指标、网速、在线时长。
 *
 * 数据机制：
 *   - 只接收 uuid，自己从 NodeDataStore 订阅该节点的 nodeInfo 和 latestReport
 *   - aboutToAppear 时同步读缓存（秒开），然后订阅变化
 *   - 单卡片单订阅：其他节点数据变化不会触发本卡片重绘
 *   - clear() 时收到 undefined，通过可选链平滑过渡到占位状态
 */

import { ClientReport, KomariClient } from '../model/KomariTypes';
import { FormatUtil } from '../common/FormatUtil';
import { NodeUtil } from '../common/NodeUtil';
import { MetricBar } from './MetricBar';
import { NodeDataStore } from '../common/NodeDataStore';

@Component
export struct NodeCard {
  @Prop uuid: string = '';
  /**
   * 链路是否可信（由 NodesPage 传入 connState === Online）。
   *
   * 为什么卡片必须知道这件事：NodeUtil.isOnline 用「updated_at 距今 < 90s」判定在线。
   * 断网后轮询被跳过、缓存不再更新，90 秒后**所有**节点都会翻成"离线"——
   * 那是"我看不到"而不是"服务器挂了"。链路不可信时状态点切灰、文案改「数据陈旧」。
   * 指标条仍展示最后一次成功拉取的快照（保留缓存是刻意设计，不是遗漏）。
   */
  @Prop linkOk: boolean = true;
  @State nodeInfo: KomariClient | undefined = undefined;
  @State report: ClientReport | undefined = undefined;
  private unsubscribeReport: (() => void) | undefined = undefined;
  private unsubscribeInfo: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    const store = NodeDataStore.getInstance();
    // 同步读缓存（秒开）
    this.nodeInfo = store.getNodeInfo(this.uuid);
    this.report = store.getLatestReport(this.uuid);
    // 订阅变化
    this.unsubscribeReport = store.subscribeReport(this.uuid, (): void => {
      this.report = store.getLatestReport(this.uuid);
    });
    this.unsubscribeInfo = store.subscribeInfo((): void => {
      this.nodeInfo = store.getNodeInfo(this.uuid);
    });
  }

  aboutToDisappear(): void {
    this.unsubscribeReport?.();
    this.unsubscribeInfo?.();
    this.unsubscribeReport = undefined;
    this.unsubscribeInfo = undefined;
  }

  /** 节点自身是否在线（基于缓存快照的 90s 阈值；链路不可信时该判断不可靠，见 linkOk） */
  private online(): boolean {
    return NodeUtil.isOnline(this.report);
  }

  /**
   * 状态点颜色：链路不可信 → 灰（未知）；可信 → 按节点在线与否取绿/红。
   * 灰色复用 health_none，与 MainPage 健康灯、FreshnessBanner 状态圆点同值同义。
   */
  private dotColor(): Resource {
    if (!this.linkOk) {
      return $r('app.color.health_none');
    }
    return this.online() ? $r('app.color.status_ok') : $r('app.color.status_bad');
  }

  private subLine(): string {
    const n = this.nodeInfo;
    if (!n) {
      return '';
    }
    const parts: string[] = [];
    if (n.os && n.os.length > 0) {
      parts.push(n.os);
    }
    if (n.arch && n.arch.length > 0) {
      parts.push(n.arch);
    }
    if (n.cpu_name && n.cpu_name.length > 0) {
      parts.push(`${n.cpu_cores}C ${n.cpu_name}`);
    }
    return parts.join(' · ');
  }

  private locationLine(): string {
    const n = this.nodeInfo;
    if (!n) {
      return '';
    }
    const parts: string[] = [];
    if (n.group && n.group.length > 0) {
      parts.push(n.group);
    }
    if (n.region && n.region.length > 0) {
      parts.push(n.region);
    }
    return parts.join(' · ');
  }

  private speedLine(): string {
    const r = this.report;
    if (!r || !this.online()) {
      return '';
    }
    const up: string = FormatUtil.bitsPerSecond(r.network?.up ?? 0);
    const down: string = FormatUtil.bitsPerSecond(r.network?.down ?? 0);
    return `↑ ${up}  ↓ ${down}`;
  }

  build() {
    Column({ space: 8 }) {
      // 第一行：状态点 + 名称 + 地区
      Row({ space: 8 }) {
        Circle({ width: 8, height: 8 })
          .fill(this.dotColor())

        Text(this.nodeInfo?.name ?? '')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        // 旗帜独立渲染在行尾：系统 emoji 原色不降透明度；TW 等回退中国国旗。
        // 旗帜放最后（不嵌套子 Row），避免挤占 layoutWeight 的名称空间
        if (FormatUtil.extractFlag(this.locationLine()).length > 0) {
          Text(FormatUtil.extractFlag(this.locationLine()))
            .fontSize(13)
        }
        if (FormatUtil.stripFlag(this.locationLine()).length > 0) {
          Text(FormatUtil.stripFlag(this.locationLine()))
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')

      // 第二行：系统与 CPU 信息
      if (this.subLine().length > 0) {
        Text(this.subLine())
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      // 第三行：三条指标（全部可选链安全）
      Row({ space: 12 }) {
        Column() {
          MetricBar({
            label: 'CPU',
            percent: NodeUtil.cpuUsage(this.report)
          })
        }
        .layoutWeight(1)

        Column() {
          MetricBar({
            label: '内存',
            percent: NodeUtil.memPercent(this.report),
            detail: this.report
              ? `${FormatUtil.bytes(this.report.ram?.used ?? 0)} / ${FormatUtil.bytes(this.nodeInfo?.mem_total ?? this.report.ram?.total ?? 0)}`
              : ''
          })
        }
        .layoutWeight(1)

        Column() {
          MetricBar({
            label: '磁盘',
            percent: NodeUtil.diskPercent(this.report),
            detail: this.report ? FormatUtil.bytes(this.report.disk?.used ?? 0) : ''
          })
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 第四行：网速 + 在线时长 / 数据陈旧 / 离线原因
      Row({ space: 8 }) {
        if (!this.linkOk) {
          // 链路不可信：网速与运行时长都是陈旧快照，且"离线"判断不可靠 ——
          // 这里只说明数据是旧的，不替节点下"挂了"的结论。
          // 用 text_secondary 而非 health_none：后者是圆点/指示灯的颜色，当文字色用
          // 在白卡上只有 2.56:1 对比度；状态信号由上面的灰点承担
          Text('数据陈旧')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        } else if (this.online()) {
          Text(this.speedLine())
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
          Blank()
          Text(`运行 ${FormatUtil.uptime(this.report?.uptime ?? 0)}`)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        } else {
          Text(this.report && this.report.message && this.report.message.length > 0 ? this.report.message : '离线')
            .fontSize(12)
            .fontColor($r('app.color.status_bad'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
    }
    .padding(14)
    .borderRadius(20)
    .backgroundColor($r('app.color.card_bg'))
    .width('100%')
  }
}
