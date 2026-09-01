/**
 * NodeCard —— 节点列表卡片
 *
 * 展示：在线状态、名称、地区/分组、系统信息、CPU/内存/磁盘三条指标、网速、在线时长。
 * 由父组件用 ForEach key(uuid+updated_at) 控制重建，本组件内部不持有轮询逻辑。
 */

import { ClientReport, KomariClient } from '../model/KomariTypes';
import { FormatUtil } from '../common/FormatUtil';
import { NodeUtil } from '../common/NodeUtil';
import { MetricBar } from './MetricBar';

@Component
export struct NodeCard {
  node: KomariClient | undefined = undefined;
  report: ClientReport | undefined = undefined;

  private online(): boolean {
    return NodeUtil.isOnline(this.report);
  }

  private subLine(): string {
    const n = this.node;
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
    const n = this.node;
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
          .fill(this.online() ? $r('app.color.status_ok') : $r('app.color.status_bad'))

        Text(this.node?.name ?? '')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        if (this.locationLine().length > 0) {
          Text(this.locationLine())
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

      // 第三行：三条指标
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
            detail: this.report ? `${FormatUtil.bytes(this.report.ram?.used ?? 0)} / ${FormatUtil.bytes(this.node?.mem_total ?? this.report.ram?.total ?? 0)}` : ''
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

      // 第四行：网速 + 在线时长 / 离线原因
      Row({ space: 8 }) {
        if (this.online()) {
          Text(this.speedLine())
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
          Blank()
          Text(`运行 ${FormatUtil.uptime(this.report?.uptime ?? 0)}`)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        } else {
          Text(this.report && this.report.message.length > 0 ? this.report.message : '离线')
            .fontSize(12)
            .fontColor($r('app.color.status_bad'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
    }
    .padding(14)
    .borderRadius(12)
    .backgroundColor($r('app.color.card_bg'))
    .width('100%')
  }
}
