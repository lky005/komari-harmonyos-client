/**
 * ServerManagePage —— 多服务端管理（从设置页进入）
 *
 * 能力：列表 / 点击条目弹出编辑弹层（编辑信息 + 账号登录 + 切换一体）/ 删除（连本地凭据一起清）/ 添加（与编辑共用弹层，承载 ConnectPanel）
 *      / 测试：右侧常驻状态区（固定高度防跳变）内联展示——绿=延迟+状态码、
 *        黄=连得上但异常（代码+异常）、红=没等到响应（超时/无响应），不弹 Toast
 *
 * 切换服务端后必须 bump AppStorage 的 komari_server_seq：
 * NodesPage / PingPage 用 @StorageProp + @Watch 监听这个值，收到变化就清空重建轮询。
 * 否则 MainPage 返回时 Tab 里的组件实例还在，会继续显示旧服务端的数据。
 */

import { router } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { AuthMode, ServerConfig } from '../model/KomariTypes';
import { ServiceRegistry } from '../common/ServiceRegistry';
import { NodeDataStore } from '../common/NodeDataStore';
import { AppKeys } from '../common/constants/AppKeys';
import { KeyFactory } from '../storage/SecretStore';
import { makeServerConfig } from '../storage/ServerStore';
import { HeaderProvider, HttpRpcClient, RpcException } from '../service/RpcClient';
import { KomariApi } from '../service/KomariApi';
import { ServerEditSheet } from '../view/ServerEditSheet';
import { ConnectPanel } from '../view/ConnectPanel';

/**
 * 单次连通性测试的卡片右侧展示结果。
 * state：ok=绿（正常）/ warn=黄（连得上但服务端不对劲）/ bad=红（没等到响应）；
 * latency 已含单位，'超时' 表示没等到响应；status 为状态码，异常时可带 2 字说明；
 * help 为问号气泡里的完整解释（bindPopup message）。
 */
/** bindPopup onStateChange 回调的事件形态（d.ts 里是匿名对象类型，ArkTS 要求显式接口） */
interface PopupVisibleEvent {
  isVisible: boolean;
}

interface ServerTestOutcome {
  serverId: string;
  state: string;
  latency: string;
  status: string;
  help: string;
}

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
  /** 弹层内容：true=添加服务端（ConnectPanel），false=编辑已有服务端（ServerEditSheet） */
  @State adding: boolean = false;
  /** 正在做连通性测试的服务端 id（按钮显示"测试中…"并防重入） */
  @State testingId: string = '';
  /** 每个服务端最近一次测试结果；整组替换赋值以触发刷新 */
  @State testOutcomes: ServerTestOutcome[] = [];
  /** 当前打开说明气泡的服务端 id（'' = 全部关闭；单开互斥） */
  @State helpFor: string = '';
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
    this.adding = false;
    this.editing = cfg;
    this.sheetShow = true;
  }

  /**
   * 不切换服务端，直接探测该服务端连通性。
   * 用临时 RpcClient 不带任何凭据（与登录态无关），超时 8 秒。
   * 结果落在卡片右侧状态区：绿=正常（延迟+状态码）、黄=连得上但异常（代码+「异常」）、
   * 红=没等到响应（延迟：超时 / 状态：无响应），不弹 Toast。
   */
  private async testServer(cfg: ServerConfig): Promise<void> {
    if (this.testingId.length > 0) {
      return;
    }
    this.testingId = cfg.id;
    this.helpFor = '';
    const emptyHeaders: Record<string, string> = {};
    const provider: HeaderProvider = (): Record<string, string> => emptyHeaders;
    const client = new HttpRpcClient(cfg.baseUrl, provider, 8000);
    const api = new KomariApi(client);
    const t0: number = Date.now();
    let state: string = 'ok';
    let latency: string = '';
    let status: string = '';
    try {
      const pong: string = await api.ping();
      latency = `${Date.now() - t0}ms`;
      if (pong === 'pong') {
        state = 'ok';
        status = `${client.lastStatus}`;
      } else {
        state = 'warn';
        status = `${client.lastStatus} 异常`;
      }
    } catch (err) {
      const e = err as RpcException;
      latency = `${Date.now() - t0}ms`;
      if (e.transport && e.code >= 100 && e.code < 600) {
        // 服务端有响应但拒绝服务（4xx/5xx）：连得上、结果不对 → 黄色异常
        state = 'warn';
        status = `${e.code} 异常`;
      } else if (!e.transport) {
        // RPC 业务层报错：HTTP 通了但内容不对 → 黄色异常
        state = 'warn';
        status = `${client.lastStatus} 异常`;
      } else {
        // 压根没等到响应（超时/DNS/无网络）→ 红色失败
        state = 'bad';
        latency = '超时';
        status = '无响应';
      }
    }
    const oc: ServerTestOutcome = {
      serverId: cfg.id,
      state: state,
      latency: latency,
      status: status,
      help: this.buildHelp(state, latency, status)
    };
    this.testOutcomes = this.testOutcomes.filter((o: ServerTestOutcome): boolean => o.serverId !== cfg.id);
    this.testOutcomes.push(oc);
    this.testingId = '';
  }

  /** 取某服务端最近一次测试结果；无结果时返回 state 为空串的占位（用 state 判空） */
  private outcomeOf(id: string): ServerTestOutcome {
    const found: ServerTestOutcome | undefined =
      this.testOutcomes.find((o: ServerTestOutcome): boolean => o.serverId === id);
    if (found !== undefined) {
      return found;
    }
    return { serverId: id, state: '', latency: '', status: '', help: '' };
  }

  /** 问号气泡的说明：两段式——第一段解释状态码含义，第二段解释当前情况与建议 */
  private buildHelp(state: string, latency: string, status: string): string {
    if (state === 'ok') {
      return `HTTP ${status}：请求成功，服务端健康。\n服务端在 ${latency} 内正常响应；延迟是这次请求的往返耗时，每次测试都会重新测量。`;
    }
    if (state === 'warn') {
      const code: string = status.split(' ')[0];
      if (code.startsWith('2')) {
        return `HTTP ${code}：连接本身没问题，但接口返回的内容不是预期的 pong。\n常见原因：反向代理配置被改动，或服务正在重启，可稍后重试。`;
      }
      if (code.startsWith('5')) {
        return `HTTP ${code}：服务端自身内部出错（5xx 表示服务端侧的错误）。\nKomari 服务异常或数据库问题可能导致此现象，稍后重试；持续出现需上服务器查日志。`;
      }
      return `HTTP ${code}：服务端拒绝了请求（3xx/4xx 表示路径、地址或权限有问题）。\n常见原因：地址填错、反向代理路径不对，或被防火墙拦截。`;
    }
    return '无响应：8 秒内没有收到服务端的任何回复，连不上。\n常见原因：域名解析失败、服务未启动、端口不对，或手机当前网络访问不了该服务器。';
  }

  private closeSheet(): void {
    this.sheetShow = false;
    this.editing = EMPTY_SERVER;
    this.reload();
  }

  @Builder
  sheetBuilder() {
    if (this.adding) {
      ConnectPanel({
        chrome: true,
        sheetMode: true,
        onClose: (): void => {
          this.closeSheet();
        }
      })
    } else {
      ServerEditSheet({
        cfg: this.editing,
        onClose: (): void => {
          this.closeSheet();
        }
      })
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
          // 切换服务端：清空全局数据缓存
          NodeDataStore.getInstance().clear();
          await ServiceRegistry.getAuth().restore();
          AppStorage.setOrCreate(AppKeys.SERVER_SEQ, Date.now());
        } else {
          // 没有服务端了：清掉全局装配与缓存，留在本页显示空列表，
          // 用户可就地再添加（不踢回首启引导页）
          ServiceRegistry.clearActive();
          NodeDataStore.getInstance().clear();
          AppStorage.setOrCreate(AppKeys.SERVER_SEQ, Date.now());
        }
      }
    } catch (err) {
      const e = err as Error;
      this.errorMsg = e?.message ?? '删除失败';
    }
  }

  /** 添加服务端：与编辑共用同一个 bindSheet（同款动画与顶部材质），builder 按 adding 切内容 */
  private addServer(): void {
    this.adding = true;
    this.sheetShow = true;
  }

  /** 测试结果两行：延迟：xxx / 状态：xxx，颜色随结局（绿正常、黄异常、红失败） */
  @Builder
  testStatusNode(oc: ServerTestOutcome) {
    Column({ space: 2 }) {
      Text(`延迟：${oc.latency}`)
        .fontSize(12)
        .maxLines(1)
        .minFontSize(10)
        .maxFontSize(12)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(this.outcomeColor(oc.state))
      Text(`状态：${oc.status}`)
        .fontSize(12)
        .maxLines(1)
        .minFontSize(10)
        .maxFontSize(12)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(this.outcomeColor(oc.state))
    }
    .alignItems(HorizontalAlign.Start)
  }

  private outcomeColor(state: string): Resource {
    if (state === 'ok') {
      return $r('app.color.status_ok');
    }
    if (state === 'warn') {
      return $r('app.color.status_warn');
    }
    return $r('app.color.status_bad');
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

                  // 操作行：测试（主色填充）/ 编辑（中性底）/ 删除（红字），右侧内联测试状态
                  Row({ space: 8 }) {
                    Text('测试')
                      .fontSize(12)
                      .fontColor(Color.White)
                      .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
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
                    // 右侧常驻状态区：固定高度、内容居中——空闲/测试中/出结果三态几何
                    // 不变，卡片不跳变；空闲时仅为占位空白
                    Column() {
                      if (this.testingId === cfg.id) {
                        Row({ space: 6 }) {
                          LoadingProgress()
                            .width(14)
                            .height(14)
                            .color($r('sys.color.ohos_id_color_emphasize'))
                          Text('测试中')
                            .fontSize(12)
                            .fontColor($r('app.color.text_secondary'))
                        }
                      } else if (this.outcomeOf(cfg.id).state.length > 0) {
                        // 整块可点：触发面=整个状态区，问号只是视觉提示；
                        // 内层 onClick 优先于卡片整卡点击（不会误开编辑弹层）
                        Row({ space: 2 }) {
                          this.testStatusNode(this.outcomeOf(cfg.id))
                          Row() {
                            SymbolGlyph($r('sys.symbol.questionmark_circle'))
                              .fontSize(14)
                              .fontColor([$r('app.color.text_tertiary')])
                          }
                          .width(22)
                          .height(22)
                          .justifyContent(FlexAlign.Center)
                          .alignItems(VerticalAlign.Center)
                        }
                        .alignItems(VerticalAlign.Center)
                        .onClick((): void => {
                          this.helpFor = this.helpFor === cfg.id ? '' : cfg.id;
                        })
                        .bindPopup(this.helpFor === cfg.id, {
                          message: this.outcomeOf(cfg.id).help,
                          placement: Placement.Top,
                          onStateChange: (e: PopupVisibleEvent): void => {
                            if (!e.isVisible) {
                              this.helpFor = '';
                            }
                          }
                        })
                      }
                    }
                    .layoutWeight(1)
                    .height(38)
                    .justifyContent(FlexAlign.Center)
                    .alignItems(HorizontalAlign.Center)
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
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
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
        // 添加与编辑共用同一档高度（用户拍板：与编辑弹层保持一致）
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
