/**
 * ServerManagePage —— 多服务端管理（从设置页进入）
 *
 * 能力：列表 / 点击条目弹出编辑弹层（编辑信息 + 账号登录 + 切换一体）/ 删除（连本地凭据一起清）/ 添加（走 ConnectPage）
 *
 * 切换服务端后必须 bump AppStorage 的 komari_server_seq：
 * NodesPage / PingPage 用 @StorageProp + @Watch 监听这个值，收到变化就清空重建轮询。
 * 否则 MainPage 返回时 Tab 里的组件实例还在，会继续显示旧服务端的数据。
 */

import { promptAction, router } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { AuthMode, ServerConfig } from '../model/KomariTypes';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';
import { AppKeys } from '../common/constants/AppKeys';
import { KeyFactory } from '../storage/SecretStore';
import { makeServerConfig } from '../storage/ServerStore';
import { HeaderProvider, HttpRpcClient } from '../service/RpcClient';
import { KomariApi } from '../service/KomariApi';
import { ServerEditSheet } from '../view/ServerEditSheet';

/** 弹层关闭期间的占位配置（editing 用条件构建卸载，不会真正渲染它） */
const EMPTY_SERVER: ServerConfig = makeServerConfig('', '', AuthMode.Guest);

@Entry
@Component
struct ServerManagePage {
  @State servers: ServerConfig[] = [];
  @State activeId: string = '';
  @State errorMsg: string = '';
  /** 编辑弹层：关闭时同时置回 EMPTY_SERVER，下次打开组件是全新实例 */
  @State sheetShow: boolean = false;
  @State editing: ServerConfig = EMPTY_SERVER;
  /** 正在做连通性测试的服务端 id（按钮显示"测试中…"并防重入） */
  @State testingId: string = '';
  private scroller: Scroller = new Scroller();

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

  /** 点击条目：打开编辑弹层（信息 + 账号 + 切换一体） */
  private openSheet(cfg: ServerConfig): void {
    this.editing = cfg;
    this.sheetShow = true;
  }

  /**
   * 不切换服务端，直接探测该服务端连通性。
   * 用临时 RpcClient 不带任何凭据（与登录态无关），超时 8 秒。
   */
  private async testServer(cfg: ServerConfig): Promise<void> {
    if (this.testingId.length > 0) {
      return;
    }
    this.testingId = cfg.id;
    let msg: string = '';
    try {
      const emptyHeaders: Record<string, string> = {};
      const provider: HeaderProvider = (): Record<string, string> => emptyHeaders;
      const api = new KomariApi(new HttpRpcClient(cfg.baseUrl, provider, 8000));
      const pong: string = await api.ping();
      msg = pong === 'pong' ? `「${cfg.name}」连接正常` : `「${cfg.name}」服务端响应异常`;
    } catch (err) {
      const e = err as Error;
      msg = `「${cfg.name}」连接失败：${e?.message ?? '网络错误'}`;
    }
    try {
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (e) {
      // 忽略
    }
    this.testingId = '';
  }

  private closeSheet(): void {
    this.sheetShow = false;
    this.editing = EMPTY_SERVER;
    this.reload();
  }

  @Builder
  sheetBuilder() {
    ServerEditSheet({
      cfg: this.editing,
      onClose: (): void => {
        this.closeSheet();
      }
    })
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
          // 切换服务端：清空全局数据缓存
          NodeDataStore.getInstance().clear();
          await ServiceRegistry.getAuth().restore();
          AppStorage.setOrCreate(AppKeys.SERVER_SEQ, Date.now());
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
    HdsNavigation() {
      Column() {
        if (this.errorMsg.length > 0) {
          Text(`⚠ ${this.errorMsg}`)
            .fontSize(12)
            .fontColor($r('app.color.status_warn'))
            .width('100%')
            .margin({ bottom: 6 })
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
          List({ space: 10, scroller: this.scroller }) {
            ForEach(this.servers, (cfg: ServerConfig) => {
              ListItem() {
                Column({ space: 10 }) {
                  // 名称 + 域名信息行（点卡片空白处 = 编辑）
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
                  }
                  .width('100%')

                  // 操作行：测试（主色填充）/ 编辑（中性底）/ 删除（红字）
                  Row({ space: 8 }) {
                    Text(this.testingId === cfg.id ? '测试中…' : '测试')
                      .fontSize(12)
                      .fontColor(Color.White)
                      .backgroundColor($r('app.color.accent'))
                      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                      .borderRadius(14)
                      .onClick((): void => {
                        this.testServer(cfg);
                      })

                    Text('编辑')
                      .fontSize(12)
                      .fontColor($r('app.color.text_secondary'))
                      .backgroundColor($r('app.color.page_bg'))
                      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                      .borderRadius(14)
                      .onClick((): void => {
                        this.openSheet(cfg);
                      })

                    Text('删除')
                      .fontSize(12)
                      .fontColor($r('app.color.status_bad'))
                      .backgroundColor($r('app.color.page_bg'))
                      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                      .borderRadius(14)
                      .onClick((): void => {
                        this.confirmDelete(cfg);
                      })
                    Blank()
                  }
                  .width('100%')
                }
                .width('100%')
                .padding(14)
                .onClick((): void => {
                  this.openSheet(cfg);
                })
              }
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(20)
            }, (cfg: ServerConfig) => cfg.id)
          }
          .layoutWeight(1)
          .width('100%')
          .clip(false)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        }

        Button('添加服务端')
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.accent'))
          .width('100%')
          .height(44)
          .margin({ top: 10, bottom: 8 })
          .onClick((): void => {
            this.addServer();
          })
      }
      .width('100%')
      .height('100%')
      .clip(false)
      .padding({ left: 16, right: 16, bottom: 20 })
      .bindSheet($$this.sheetShow, this.sheetBuilder(), {
        height: SheetSize.LARGE,
        // 弹层内是嵌套 HdsNavigation，自带标题栏与关闭按钮；
        // dragBar 会形成双重头部，关闭手势（下滑）不受影响
        dragBar: false,
        // 关闭按钮由弹层内 HdsNavigation backIcon 提供，避免系统叉号与内容重叠
        showClose: false
      })
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      content: {
        title: { mainTitle: '服务端管理' },
        backIcon: {
          icon: $r('sys.symbol.arrow_left'),
          action: (): void => { router.back(); }
        }
      },
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .bindToScrollable([this.scroller])
    .backgroundColor($r('app.color.page_bg'))
  }
}
