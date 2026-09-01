/**
 * NodesPage —— 节点列表（MainPage 的 Tab1 内容）
 *
 * 数据流：
 *   启动拉一次节点列表 → 每 POLL_MS 轮询一轮
 *   （列表 + 每个节点的 getClientRecentRecords，取最后一个快照）
 *   → 重建 entries 数组触发卡片刷新。
 *
 * 注意：
 *   - 离线节点的快照可能拿不到（catch 返回 undefined），卡片显示离线
 *   - 游客与管理员看到的节点数量可能不同（隐藏节点），不要缓存长度假设
 *   - 轮询定时器必须在 aboutToDisappear 清理，详情页返回时会重建
 */

import { router } from '@kit.ArkUI';
import { ClientReport, KomariClient } from '../model/KomariTypes';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeUtil } from '../common/NodeUtil';
import { KomariApi } from '../service/KomariApi';
import { NodeCard } from '../view/NodeCard';

interface NodeEntry {
  node: KomariClient;
  report: ClientReport | undefined;
}

interface DetailParam {
  uuid: string;
}

@Component
export struct NodesPage {
  @State entries: NodeEntry[] = [];
  @State keyword: string = '';
  @State groups: string[] = [];
  @State selectedGroup: string = '';
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State lastRefresh: string = '';
  private timerId: number = -1;
  private refreshing: boolean = false;

  aboutToAppear(): void {
    this.startPolling();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  private startPolling(): void {
    this.stopPolling();
    this.refreshOnce();
    this.timerId = setInterval((): void => {
      this.refreshOnce();
    }, 5000);
  }

  private stopPolling(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private async refreshOnce(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    // useServer() 未调用过时 getApi() 会抛错；activeConfig 存在则 api 一定存在
    if (!ServiceRegistry.getActiveConfig()) {
      this.errorMsg = '服务端未连接';
      return;
    }
    const api: KomariApi = ServiceRegistry.getApi();
    this.refreshing = true;
    try {
      const nodes: KomariClient[] = await api.getNodes();

      const tasks: Promise<ClientReport[] | undefined>[] = nodes.map(
        (n: KomariClient): Promise<ClientReport[] | undefined> => {
          return api.getClientRecentRecords(n.uuid).catch((): ClientReport[] | undefined => undefined);
        }
      );
      const results: (ClientReport[] | undefined)[] = await Promise.all(tasks);

      const next: NodeEntry[] = [];
      for (let i = 0; i < nodes.length; i++) {
        const list = results[i];
        const latest: ClientReport | undefined = list && list.length > 0 ? list[list.length - 1] : undefined;
        next.push({ node: nodes[i], report: latest });
      }
      this.entries = next;

      const groupSet: Set<string> = new Set();
      nodes.forEach((n: KomariClient): void => {
        if (n.group && n.group.length > 0) {
          groupSet.add(n.group);
        }
      });
      this.groups = Array.from(groupSet).sort();
      this.errorMsg = '';
      const d: Date = new Date();
      const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
      this.lastRefresh = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
    } catch (err) {
      const e = err as Error;
      this.errorMsg = e?.message ?? '刷新失败';
    } finally {
      this.refreshing = false;
    }
  }

  private filtered(): NodeEntry[] {
    const kw: string = this.keyword.trim().toLowerCase();
    return this.entries.filter((e: NodeEntry): boolean => {
      if (this.selectedGroup.length > 0 && e.node.group !== this.selectedGroup) {
        return false;
      }
      if (kw.length === 0) {
        return true;
      }
      const n: KomariClient = e.node;
      const hay: string = `${n.name} ${n.region} ${n.group} ${n.tags} ${n.os} ${n.cpu_name}`.toLowerCase();
      return hay.includes(kw);
    });
  }

  private openDetail(uuid: string): void {
    const param: DetailParam = { uuid: uuid };
    router.pushUrl({ url: 'pages/NodeDetailPage', params: param });
  }

  build() {
    Column() {
      // 顶部：概览 + 搜索
      Column({ space: 8 }) {
        Row() {
          Text('节点')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Blank()
          if (this.lastRefresh.length > 0) {
            Text(`更新于 ${this.lastRefresh}`)
              .fontSize(11)
              .fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%')

        Row({ space: 8 }) {
          Text(`共 ${this.entries.length}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          Text(`在线 ${this.entries.filter((e: NodeEntry): boolean => NodeUtil.isOnline(e.report)).length}`)
            .fontSize(12)
            .fontColor($r('app.color.status_ok'))
        }
        .width('100%')

        TextInput({ text: this.keyword, placeholder: '搜索名称 / 地区 / 标签' })
          .height(38)
          .fontSize(14)
          .backgroundColor($r('app.color.card_bg'))
          .onChange((v: string): void => {
            this.keyword = v;
          })
      }
      .padding({ left: 16, right: 16, top: 12 })

      // 分组筛选
      if (this.groups.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            this.groupChip('', '全部')
            ForEach(this.groups, (g: string) => {
              this.groupChip(g, g)
            }, (g: string) => g)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .width('100%')
        .margin({ top: 8 })
      }

      if (this.errorMsg.length > 0) {
        Text(`⚠ ${this.errorMsg}`)
          .fontSize(12)
          .fontColor($r('app.color.status_warn'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 })
      }

      // 列表
      if (this.entries.length === 0 && !this.loading) {
        Column({ space: 8 }) {
          Text(this.errorMsg.length > 0 ? '加载失败' : '暂无节点')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
          Text('下拉检查服务端后自动重试')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.filtered(), (entry: NodeEntry) => {
            ListItem() {
              NodeCard({ node: entry.node, report: entry.report })
                .onClick((): void => {
                  this.openDetail(entry.node.uuid);
                })
            }
          }, (entry: NodeEntry) => `${entry.node.uuid}_${entry.report?.updated_at ?? 'na'}`)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 12 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  groupChip(label: string, value: string) {
    Text(label.length === 0 ? value : label)
      .fontSize(12)
      .fontColor(this.selectedGroup === value ? Color.White : $r('app.color.text_secondary'))
      .backgroundColor(this.selectedGroup === value ? $r('app.color.accent') : $r('app.color.card_bg'))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .borderRadius(14)
      .onClick((): void => {
        this.selectedGroup = value;
      })
  }
}
