/**
 * NodeDetailPage —— 节点详情（本轮只做实时区）
 *
 * 参数：router 传入 { uuid }
 * 数据：
 *   - 静态信息：进页拉一次 getNodes() 按 uuid 匹配（价格 / 到期 / 配置）
 *   - 实时快照：每 2s 轮询 getClientRecentRecords，取数组最后一个
 *
 * 已知坑（改前必读 内部记录 第 3 节）：
 *   - network.totalUp / totalDown 是驼峰
 *   - MetricPoint.value 可能为 null（历史曲线时处理，本页是实时快照）
 *   - expired_at 可能是 ''（无到期日）
 */

import { router } from '@kit.ArkUI';
import { ClientReport, KomariClient } from '../model/KomariTypes';
import { FormatUtil } from '../common/FormatUtil';
import { NodeUtil } from '../common/NodeUtil';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { MetricBar } from '../view/MetricBar';

interface DetailParam {
  uuid: string;
}

@Component
struct InfoRow {
  label: string = '';
  value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
      Blank()
      Text(this.value)
        .fontSize(13)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '65%' })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }
}

@Entry
@Component
struct NodeDetailPage {
  @State node: KomariClient | undefined = undefined;
  @State report: ClientReport | undefined = undefined;
  @State errorMsg: string = '';
  @State updatedAtText: string = '';
  private uuid: string = '';
  private timerId: number = -1;
  private refreshing: boolean = false;

  aboutToAppear(): void {
    const p = router.getParams() as DetailParam;
    this.uuid = p.uuid;
    this.loadNodeInfo();
    this.startPolling();
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private async loadNodeInfo(): Promise<void> {
    try {
      const nodes: KomariClient[] = await ServiceRegistry.getApi().getNodes();
      const found: KomariClient[] = nodes.filter((n: KomariClient): boolean => n.uuid === this.uuid);
      if (found.length > 0) {
        this.node = found[0];
      }
    } catch (err) {
      // 静态信息拉不到不阻塞实时区（私有站点游客状态等场景），快照轮询继续
      const e = err as Error;
      this.errorMsg = e?.message ?? '';
    }
  }

  private startPolling(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
    }
    this.refreshSnapshot();
    this.timerId = setInterval((): void => {
      this.refreshSnapshot();
    }, 2000);
  }

  private async refreshSnapshot(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    if (!ServiceRegistry.getActiveConfig()) {
      this.errorMsg = '服务端未连接';
      return;
    }
    this.refreshing = true;
    try {
      const list: ClientReport[] = await ServiceRegistry.getApi().getClientRecentRecords(this.uuid);
      if (list.length > 0) {
        this.report = list[list.length - 1];
        this.updatedAtText = FormatUtil.clock(this.report.updated_at);
        this.errorMsg = '';
      } else {
        this.report = undefined;
        this.updatedAtText = '';
        this.errorMsg = '暂无上报数据';
      }
    } catch (err) {
      const e = err as Error;
      this.errorMsg = e?.message ?? '刷新失败';
    } finally {
      this.refreshing = false;
    }
  }

  private goBack(): void {
    router.back();
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

  build() {
    Column() {
      // 顶栏
      Row({ space: 8 }) {
        Text('←')
          .fontSize(22)
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => {
            this.goBack();
          })
          .padding({ right: 8 })
        Column({ space: 2 }) {
          Text(this.node?.name ?? this.uuid)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.online() ? `在线 · 更新于 ${this.updatedAtText}` : '离线')
            .fontSize(12)
            .fontColor(this.online() ? $r('app.color.status_ok') : $r('app.color.status_bad'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      if (this.errorMsg.length > 0) {
        Text(`⚠ ${this.errorMsg}`)
          .fontSize(12)
          .fontColor($r('app.color.status_warn'))
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 4 })
      }

      Scroll() {
        Column({ space: 12 }) {
          // ===== 实时指标卡 =====
          Column({ space: 12 }) {
            Text('实时状态')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')

            MetricBar({
              label: 'CPU 使用率',
              percent: this.online() ? NodeUtil.cpuUsage(this.report) : -1,
              detail: this.node && this.node.cpu_name.length > 0 ? `${this.node.cpu_cores} 核 · ${this.node.cpu_name}` : ''
            })
            MetricBar({
              label: '内存',
              percent: this.online() ? NodeUtil.memPercent(this.report) : -1,
              detail: this.report ? `${FormatUtil.bytes(this.report.ram?.used ?? 0)} / ${FormatUtil.bytes(this.node?.mem_total ?? this.report.ram?.total ?? 0)}` : ''
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
            MetricBar({
              label: '磁盘',
              percent: this.online() ? NodeUtil.diskPercent(this.report) : -1,
              detail: this.report ? `${FormatUtil.bytes(this.report.disk?.used ?? 0)} / ${FormatUtil.bytes(this.node?.disk_total ?? this.report.disk?.total ?? 0)}` : ''
            })
          }
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 网络卡 =====
          Column({ space: 8 }) {
            Text('网络')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')

            Row() {
              Column({ space: 2 }) {
                Text('实时 ↑')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                Text(this.online() ? FormatUtil.bitsPerSecond(this.report?.network?.up ?? 0) : '-')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Column({ space: 2 }) {
                Text('实时 ↓')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                Text(this.online() ? FormatUtil.bitsPerSecond(this.report?.network?.down ?? 0) : '-')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Column({ space: 2 }) {
                Text('累计发送')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                Text(FormatUtil.bytes(this.report?.network?.totalUp ?? 0))
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Column({ space: 2 }) {
                Text('累计接收')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                Text(FormatUtil.bytes(this.report?.network?.totalDown ?? 0))
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')

            Row({ space: 16 }) {
              Text(`TCP 连接 ${this.report?.connections?.tcp ?? 0}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
              Text(`UDP 连接 ${this.report?.connections?.udp ?? 0}`)
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
          }
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 系统卡 =====
          Column({ space: 2 }) {
            Text('系统')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .padding({ bottom: 4 })

            InfoRow({ label: '在线时长', value: this.online() ? FormatUtil.uptime(this.report?.uptime ?? 0) : '-' })
            InfoRow({ label: '负载 1/5/15min', value: this.report && this.report.load ? `${(this.report.load.load1 ?? 0).toFixed(2)} / ${(this.report.load.load5 ?? 0).toFixed(2)} / ${(this.report.load.load15 ?? 0).toFixed(2)}` : '-' })
            InfoRow({ label: '进程数', value: this.report ? `${this.report.process ?? 0}` : '-' })
            InfoRow({ label: '虚拟化', value: this.node?.virtualization ?? '-' })
            InfoRow({ label: '内核', value: this.node?.kernel_version ?? '-' })
            if (this.node && this.node.gpu_name && this.node.gpu_name.length > 0) {
              InfoRow({ label: 'GPU', value: this.node.gpu_name })
            }
          }
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')

          // ===== 主机与账单卡 =====
          Column({ space: 2 }) {
            Text('主机信息')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .padding({ bottom: 4 })

            InfoRow({ label: '操作系统', value: this.node?.os ?? '-' })
            InfoRow({ label: '架构', value: this.node?.arch ?? '-' })
            InfoRow({ label: '地区', value: this.node?.region ?? '-' })
            InfoRow({ label: '分组', value: this.node?.group ?? '-' })
            if (this.priceLine().length > 0) {
              InfoRow({ label: '价格', value: this.priceLine() })
            }
            if (this.expireLine().length > 0) {
              InfoRow({ label: '到期', value: this.expireLine() })
            }
            if (NodeUtil.tagList(this.node?.tags ?? '').length > 0) {
              InfoRow({ label: '标签', value: NodeUtil.tagList(this.node?.tags ?? '').join(' / ') })
            }
          }
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_bg'))
          .width('100%')
        }
        .padding({ left: 16, right: 16, bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
