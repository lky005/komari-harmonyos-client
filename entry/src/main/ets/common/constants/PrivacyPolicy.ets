/**
 * PrivacyPolicy —— 《关于Lk监控与隐私的声明》内容集中地
 *
 * 首启弹层为极简摘要（华为首启隐私确认框习惯）：
 *   - HEADLINE：卡片主标题（短版；链接标签仍用完整 TITLE）
 *   - SUMMARY_INTRO / SUMMARY_TAIL：夹住正文内联蓝字链接
 *     （Span.onClick 打开华为协议托管页全文 URL）
 *   - SUMMARY_BODY：两条核心事实（本地加密存凭据 / 公网 IP 查归属）
 *   - SUMMARY_OUTRO：同意引导句
 * 弹层内不内置长文；声明全文（BLOCKS）供关于页「隐私说明」弹层离线展示。
 *
 * BLOCKS 收录口径（2026-09-17 对照托管页 DOM 定稿，逐字同步在线版）：
 *   - 仅收录网页可见渲染内容，逐字保留（含原始空格与半角标点，如
 *     「不满意, 特别」「网络状态 」）；不改正写、不概括。
 *   - 层级对齐网页：h5 章节标题（#####）用 head()（加粗）；
 *     2.x 小节标题网页上为普通段落，不做加粗。
 *   - 首段三个词组在网页为 600 字重（Lk监控 / 李科杨 / 服务器与主机状态
 *     监控、节点性能指标查看及数据展示），用 bold span 表达。
 *   - GitHub Issue 链接在网页为单独一行（<br> 断行），独立成段。
 *   - 打开前校验（仅 http/https、非本机/内网/环回）。
 *   - VERSION：政策版本号，实质变更时 +1，所有用户重新走同意流程
 *
 * 同意标记落 ServerStore 全局偏好（key = AGREED_KEY，value = VERSION）；
 * 拒绝退出不落任何标记，下次启动重新弹层。
 */

/**
 * ⚠️ 2026-09-11 起接入华为隐私托管，本文件职责收窄（见 common/PrivacyGate.ets）：
 *   - 首启弹层 PrivacyConsentSheet 已下线，VERSION / AGREED_KEY 的「自管版本
 *     与同意标记」机制不再参与隐私闸门；协议版本由华为侧 versionCode 负责
 *   - URL 降级为兜底，关于页优先用 PrivacyGate.getPolicyUrl() 动态取值
 *   - BLOCKS / 排版常量保留：供关于页「隐私说明」离线展示（无网可读是加分项）
 *   - SUMMARY_* 仅 PrivacyConsentSheet 使用，随该弹层一起处于下线状态
 *   迁移说明：_local/docs/privacy-hosting-migration.md
 */

/** 段内样式片段：bold 对应网页 600/700 字重片段 */
export interface PolicySpan {
  bold: boolean;
  text: string;
}

/** 条款块：heading=true 网页 h5 章节标题（加粗），false=正文段落 */
export interface PolicyBlock {
  heading: boolean;
  spans: PolicySpan[];
}

function head(text: string): PolicyBlock {
  return { heading: true, spans: [{ bold: true, text: text }] };
}

function para(text: string): PolicyBlock {
  return { heading: false, spans: [{ bold: false, text: text }] };
}

/** 段内多字重片段（对齐网页 span 结构） */
function paraSpans(spans: PolicySpan[]): PolicyBlock {
  return { heading: false, spans: spans };
}

export class PrivacyPolicy {
  /** @deprecated 2026-09-11 起托管：协议版本由华为侧 versionCode 负责，此常量不再参与闸门 */
  static readonly VERSION: string = '1.0';

  /** @deprecated 2026-09-11 起托管：同意状态改由系统记录（见 common/PrivacyGate.ets） */
  static readonly AGREED_KEY: string = 'privacy_agreed';

  /** 声明完整标题（链接标签与关于页弹层标题用） */
  static readonly TITLE: string = '关于Lk监控与隐私的声明';

  /** 首启弹层卡片主标题（短版，视觉更轻） */
  static readonly HEADLINE: string = '关于 Lk监控 与隐私';

  /** 更新日期行（网页居中、14px，关于页弹层顶部展示） */
  static readonly UPDATE_DATE: string = '更新日期：2026.9.17';

  /** 生效日期行（网页文末、正文同色左对齐） */
  static readonly EFFECTIVE_DATE: string = '生效日期：2026.9.17';

  /**
   * 完整政策在线地址（华为协议托管页）—— 仅作兜底。
   * 关于页优先用 PrivacyGate.getPolicyUrl() 动态取值：AGC 侧重建设协议后
   * 旧 agreementId 会失效，硬编码不可靠。
   */
  static readonly URL: string =
    'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2034043076883838016';

  /** 摘要：链接前的引导句 */
  static readonly SUMMARY_INTRO: string = '欢迎使用 Lk监控！请仔细阅读并充分理解';

  /** 摘要：链接后的收尾句 */
  static readonly SUMMARY_TAIL: string = '。';

  /** 摘要：两条核心事实 */
  static readonly SUMMARY_BODY: string =
    '本应用为服务器监控工具，服务器地址与登录凭据仅在您的设备本地加密保存；节点网络归属查询在设备本地离线完成（内置 ip2region 与 GeoLite2 数据库），不会将 IP 发送至第三方服务器；节点缓存与 Ping 记录亦仅存储于设备本地。';

  /** 摘要：同意引导句 */
  static readonly SUMMARY_OUTRO: string = '如您同意上述内容，请点击「同意」开始使用。';

  /** 声明全文（逐字对齐托管页可见渲染；关于页「隐私说明」弹层离线展示用） */
  static readonly BLOCKS: PolicyBlock[] = [
    // ===== 首段：三个词组 600 字重加粗 =====
    paraSpans([
      { bold: true, text: 'Lk监控' },
      { bold: false, text: ' 是由 ' },
      { bold: true, text: '李科杨' },
      { bold: false, text: ' （以下简称“我们”）为您提供的，用于' },
      { bold: true, text: '服务器与主机状态监控、节点性能指标查看及数据展示' },
      { bold: false, text: '的应用。本隐私声明由我们为处理您的个人信息而制定。' }
    ]),
    para('我们非常重视您的个人信息和隐私保护，将会按照法律要求和业界成熟的安全标准，为您的个人信息提供相应的安全保护措施。'),

    // ===== 更新内容说明（h5 标题加粗）=====
    head('请您仔细阅读此次隐私声明的更新内容：'),
    para('1. 我们如何收集和使用您的个人信息 / 3. 信息存储地点及期限 章节中 节点网络归属查询由在线第三方查询改为设备本地离线查询（内置 ip2region 与 GeoLite2-ASN 数据库），不再将节点公网 IP 发送至第三方服务器；补充说明节点缓存与 Ping 记录的本地存储；新增「撤回隐私授权」一键清除功能说明。'),

    // ===== 摘要引导（h5 标题加粗）=====
    head('您可以通过访问隐私声明摘要快速了解应用收集、使用个人信息的目的、方式、范围。除上述主要功能外，我们在提供服务过程还涉及如下处理活动：'),
    para('本应用在您的设备本地保存 Komari 服务器地址与登录凭据（加密存储）；节点网络归属查询在您的设备本地完成（使用内置的 ip2region 与 GeoLite2 离线数据库），不会将 IP 发送至任何第三方服务器；节点缓存与 Ping 记录亦仅存储于您的设备本地。'),

    // ===== 第1章：收集和使用（h5 标题加粗）=====
    head('1. 我们如何收集和使用您的个人信息'),
    para('我们仅在有合法性基础的情形下才会使用您的个人信息。根据适用的法律，我们可能会基于您的同意、为履行/订立您与我们的合同所必需、履行法定义务所必需等合法性基础，使用您的个人信息。'),
    para('1.1 我们提供下列服务时会处理必要的个人信息。'),
    para('1.1 我们为您提供下述服务器监控与状态指标查看。在您使用相关业务的过程中，我们会处理所必需的信息，以便履行我们的合同义务若您不提供相关信息，会影响到您使用本应用的相关功能/服务。'),
    paraSpans([
      { bold: false, text: '为了' },
      { bold: true, text: '实现应用功能' },
      { bold: false, text: '，基于履行我们的合同义务我们需要收集您的应用设置信息、 网络连接状态、Ping 详情记录、 节点监控数据缓存、 ' },
      { bold: true, text: '服务器配置与登录凭据' },
      { bold: false, text: ' 。' }
    ]),

    // ===== 第2章前置：设备权限调用（h5 标题加粗）=====
    head('2. 设备权限调用'),
    para('本服务在运行过程中需要使用以下权限，我们会在使用之前征求您的意见，任何未明确同意使用的权限，均不会被随意调用。'),
    para('您可以随时访问系统“设置”来管理本服务的权限。'),

    // ===== 第2章：管理个人信息（h5 标题加粗）=====
    head('2. 管理您的个人信息'),
    para('关于您的个人信息，您可以通过以下方式，行使查阅、复制、更正、删除等法定权利。'),
    para('2.1 信息访问'),
    para('您可以前往「设置」页面，访问您的服务器列表与配置信息。'),
    para('2.2 信息更正'),
    para('当您需要更新您的个人信息，或发现我们处理您的个人信息有误时，您有权作出更正或更新。'),
    para('您可以前往「设置」页面，访问并修改您的服务器地址、密码。'),
    para('2.3 信息删除'),
    para('您可以前往「设置 → 服务器管理」，以删除您的服务器配置与登录凭据；或在「关于」页面点击「撤回隐私授权」清除全部本地数据。'),
    para('2.4 撤销同意'),
    para('如果您需撤销授权我们处理您的信息，您可以前往「关于」页面点击「撤回隐私授权」，或直接卸载本应用来撤销您的同意。'),
    para('2.4 注销服务'),
    para('您可以前往注销此前注册的账户。在注销账户之后，我们将停止为您提供产品或服务，并依据您的要求，删除您的个人信息，法律法规另有规定的除外。'),
    para('如您对您的数据主体权利有进一步要求或存在任何疑问、意见或建议，可通过本声明中“如何联系我们”章节中所述方式与我们取得联系，并行使您的相关权利。'),

    // ===== 第3章：存储地点及期限（h5 标题加粗）=====
    head('3. 信息存储地点及期限'),
    para('3.1 固定存储期限：服务器地址与登录凭据：保存在您的设备本地（加密存储），直至您删除对应服务器或卸载应用；节点监控数据缓存与 Ping 详情记录：保存在您的设备本地，可在「撤回隐私授权」时一并清除，或随应用卸载清除；IP 归属查询：使用设备本地内置的离线数据库完成查询，不发送至第三方服务器，查询结果随节点缓存一并管理。 '),
    para('3.2 上述信息将会传输并保存至您的设备本地，以及由您自行部署与管理的服务器。'),

    // ===== 第4章：联系我们（h5 标题加粗）=====
    head('4. 如何联系我们'),
    para('您可通过以下方式联系我们，并行使您的相关权利，我们会尽快回复。'),
    para('邮箱：3248076788@qq.com'),
    para('本应用由李科杨（个人开发者）开发与维护。如您对本声明或个人信息处理有任何疑问、意见或建议，可通过上方邮箱与我们联系；亦可在开源社区提交 Issue：'),
    para('https://github.com/lky005/komari-harmonyos-client/issues'),
    para('我们会在收到您的反馈后尽快（通常在 15 个工作日内）核实并处理回复。'),
    para('如果您对我们的回复不满意, 特别是当个人信息处理行为损害了您的合法权益时您还可以通过向有管辖权的人民法院提起诉讼、向行业自律协会或政府相关管理机构投诉等外部途径进行解决。 您也可以向我们了解可能适用的相关投诉途径的信息。')
  ];
}
