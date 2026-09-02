/**
 * ServerManagePage —— 多服务端管理（从设置页进入）
 *
 * 能力：列表 / 切换（useServer + restore）/ 删除（连本地凭据一起清）/ 添加（走 ConnectPage）
 *
 * 切换服务端后必须 bump AppStorage 的 komari_server_seq：
 * NodesPage / PingPage 用 @StorageProp + @Watch 监听这个值，收到变化就清空重建轮询。
 * 否则 MainPage 返回时 Tab 里的组件实例还在，会继续显示旧服务端的数据。
 */

import { router } from '@kit.ArkUI';
import { ServerConfig } from '../model/KomariTypes';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { KeyFactory } from '../storage/SecretStore';

@Entry
@Component
struct ServerManagePage {
  @State servers: ServerConfig[] = [];
  @State activeId: string = '';
  @State errorMsg: string = '';

  aboutToAppear(): void {
    this.reload();
  }

  onPageShow(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    try {
      const store = ServiceRegistry.getServerStore();
      this.servers = await store.listServers();
      this.activeId = await store.getActiveServerId();
    } catch (e) {
      this.errorMsg = '读取服务端列表失败';
    }
  }

  private confirmSwitch(cfg: ServerConfig): void {
    if (cfg.id === this.activeId) {
      return;
    }
    AlertDialog.show({
      title: '切换服务端',
      message: `切换到「${cfg.name}」？`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {
          // 不切换
        }
      },
      secondaryButton: {
        value: '切换',
        fontColor: Color.White,
        backgroundColor: $r('app.color.accent'),
        action: (): void => {
          this.doSwitch(cfg);
        }
      }
    });
  }

  private async doSwitch(cfg: ServerConfig): Promise<void> {
    try {
      await ServiceRegistry.useServer(cfg);
      await ServiceRegistry.getAuth().restore();
      AppStorage.setOrCreate('komari_server_seq', Date.now());
      router.back();
    } catch (err) {
      const e = err as Error;
      this.errorMsg = e?.message ?? '切换失败';
    }
  }

  private confirmDelete(cfg: ServerConfig): void {
    AlertDialog.show({
      title: '删除服务端',
      message: `删除「${cfg.name}」？该服务端的登录凭据会从本机一并清除。`,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: (): void => {
          // 不删除
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Color.White,
        backgroundColor: $r('app.color.status_bad'),
        action: (): void => {
          this.doDelete(cfg);
        }
      }
    });
  }

  private async doDelete(cfg: ServerConfig): Promise<void> {
    const wasActive: boolean = cfg.id === this.activeId;
    try {
      // 先清凭据再删配置，避免残留孤儿 Asset 条目
      const secrets = ServiceRegistry.getSecrets();
      const aliases: string[] = [
        KeyFactory.sessionToken(cfg.id),
        KeyFactory.password(cfg.id),
        KeyFactory.apiKey(cfg.id)
      ];
      for (let i = 0; i < aliases.length; i++) {
        await secrets.remove(aliases[i]);
      }
      // removeServer 会在删掉当前服务端时把 active 指到剩余第一个
      await ServiceRegistry.getServerStore().removeServer(cfg.id);
      await this.reload();

      if (wasActive) {
        if (this.servers.length > 0) {
          const next: ServerConfig = this.servers[0];
          await ServiceRegistry.useServer(next);
          await ServiceRegistry.getAuth().restore();
          AppStorage.setOrCreate('komari_server_seq', Date.now());
        } else {
          // 没有服务端了，回连接页并清掉页面栈
          router.clear();
          router.replaceUrl({ url: 'pages/ConnectPage' });
        }
      }
    } catch (err) {
      const e = err as Error;
      this.errorMsg = e?.message ?? '删除失败';
    }
  }

  private addServer(): void {
    router.pushUrl({ url: 'pages/ConnectPage' });
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('←')
          .fontSize(22)
          .fontColor($r('app.color.text_primary'))
          .onClick((): void => {
            router.back();
          })
          .padding({ right: 8 })
        Text('服务端管理')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      if (this.errorMsg.length > 0) {
        Text(`⚠ ${this.errorMsg}`)
          .fontSize(12)
          .fontColor($r('app.color.status_warn'))
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 6 })
      }

      if (this.servers.length === 0) {
        Column({ space: 8 }) {
          Text('暂无服务端')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.servers, (cfg: ServerConfig) => {
            ListItem() {
              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Row({ space: 6 }) {
                    Text(cfg.name)
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .constraintSize({ maxWidth: '70%' })
                    if (cfg.id === this.activeId) {
                      Text('当前')
                        .fontSize(11)
                        .fontColor(Color.White)
                        .backgroundColor($r('app.color.status_ok'))
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .borderRadius(8)
                    }
                  }
                  Text(cfg.baseUrl)
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text('删除')
                  .fontSize(12)
                  .fontColor($r('app.color.status_bad'))
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .onClick((): void => {
                    this.confirmDelete(cfg);
                  })
              }
              .width('100%')
              .padding(14)
              .onClick((): void => {
                this.confirmSwitch(cfg);
              })
            }
            .backgroundColor($r('app.color.card_bg'))
            .borderRadius(12)
          }, (cfg: ServerConfig) => cfg.id)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      }

      Button('添加服务端')
        .fontSize(15)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.accent'))
        .width('100%')
        .height(44)
        .margin({ left: 16, right: 16, bottom: 20 })
        .onClick((): void => {
          this.addServer();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
