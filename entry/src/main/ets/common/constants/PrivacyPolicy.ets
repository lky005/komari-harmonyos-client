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
 * BLOCKS 收录口径（2026-09-07 对照托管页 DOM 定稿）：
 *   - 仅收录网页可见渲染内容，逐字保留（含原始空格与半角标点，如
 *     「不满意, 特别」「网络状态 」）；不改正写、不概括。
 *   - display:none 的隐藏块不收录：「2. 设备权限调用」整节、
 *     「2.4 注销服务」模板段、version-desc/child-policy 等空占位、
 *     「1.1 我们提供下列服务时会处理必要的个人信息。」（仅存在于
 *     未见流节点，可见正文无此行）。
 *   - 层级对齐网页：h5 章节标题（含「您可以通过访问…」一句）用 head()；
 *     2.x 小节标题网页上为普通段落，不做加粗。
 *   - 首段三个词组在网页为 600 字重（Lk监控 / 李科杨 / 服务器与主机状态
 *     监控、节点性能指标查看及数据展示），用 bold span 表达。
 *   - 「提交 Issue：」与链接、后句在网页为同段内 <br> 换行，字符串内用
 *     \n\n 保留断行。
 *   - 打开前校验（仅 http/https、非本机/内网/环回）。
 *   - VERSION：政策版本号，实质变更时 +1，所有用户重新走同意流程
 *
 * 同意标记落 ServerStore 全局偏好（key = AGREED_KEY，value = VERSION）；
 * 拒绝退出不落任何标记，下次启动重新弹层。
 */

/** 段内样式片段：bold 对应网页 600/700 字重片段 */
export interface PolicySpan {
  bold: boolean;
  text: string;
}

/** 条款块：heading=true 网页 h5 章节标题，false=正文段落 */
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
  /** 政策版本：内容有实质变更时 +1，用户将重新看到同意弹层 */
  static readonly VERSION: string = '1.0';

  /** ServerStore 全局偏好 key：记录已同意的政策版本号 */
  static readonly AGREED_KEY: string = 'privacy_agreed';

  /** 声明完整标题（链接标签与关于页弹层标题用） */
  static readonly TITLE: string = '关于Lk监控与隐私的声明';

  /** 首启弹层卡片主标题（短版，视觉更轻） */
  static readonly HEADLINE: string = '关于 Lk监控 与隐私';

  /** 更新日期行（网页居中、14px，关于页弹层顶部展示） */
  static readonly UPDATE_DATE: string = '更新日期：2026.9.7';

  /** 生效日期行（网页文末、正文同色左对齐） */
  static readonly EFFECTIVE_DATE: string = '生效日期：2026.9.7';

  /** 完整政策在线地址（华为协议托管页） */
  static readonly URL: string =
    'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2034043076883838016';

  /** 摘要：链接前的引导句 */
  static readonly SUMMARY_INTRO: string = '欢迎使用 Lk监控！请仔细阅读并充分理解';

  /** 摘要：链接后的收尾句 */
  static readonly SUMMARY_TAIL: string = '。';

  /** 摘要：两条核心事实 */
  static readonly SUMMARY_BODY: string =
    '本应用为服务器监控工具，服务器地址与登录凭据仅在您的设备本地加密保存；仅在查询节点网络归属时，会将节点公网 IP 发送至第三方公开归属库。';

  /** 摘要：同意引导句 */
  static readonly SUMMARY_OUTRO: string = '如您同意上述内容，请点击「同意」开始使用。';

  /** 声明全文（逐字对齐托管页可见渲染；关于页「隐私说明」弹层离线展示用） */
  static readonly BLOCKS: PolicyBlock[] = [
    paraSpans([
      { bold: true, text: 'Lk监控' },
      { bold: false, text: ' 是由 ' },
      { bold: true, text: '李科杨' },
      { bold: false, text: ' （以下简称“我们”）为您提供的，用于' },
      { bold: true, text: '服务器与主机状态监控、节点性能指标查看及数据展示' },
      { bold: false, text: '的应用。本隐私声明由我们为处理您的个人信息而制定。' }
    ]),
    para('我们非常重视您的个人信息和隐私保护，将会按照法律要求和业界成熟的安全标准，为您的个人信息提供相应的安全保护措施。'),
    head('您可以通过访问隐私声明摘要快速了解应用收集、使用个人信息的目的、方式、范围。除上述主要功能外，我们在提供服务过程还涉及如下处理活动：'),
    para('本应用在您的设备本地保存 Komari 服务器地址与登录凭据（加密存储）；查询节点网络归属时，会将节点公网 IP 发送至第三方 IP 归属库。'),

    head('1. 我们如何收集和使用您的个人信息'),
    para('我们仅在有合法性基础的情形下才会使用您的个人信息。根据适用的法律，我们可能会基于您的同意、为履行/订立您与我们的合同所必需、履行法定义务所必需等合法性基础，使用您的个人信息。'),
    para('1.1 我们为您提供下述服务器监控与状态指标查看在您使用相关业务的过程中，我们会处理所必需的信息，以便履行我们的合同义务若您不提供相关信息，会影响到您使用本应用的相关功能/服务。'),
    para('为了实现应用功能，基于履行我们的合同义务我们需要收集您的账号信息、 应用设置信息、 网络类型、 服务器配置与网络状态 。'),

    head('2. 管理您的个人信息'),
    para('关于您的个人信息，您可以通过以下方式，行使查阅、复制、更正、删除等法定权利。'),
    para('2.1 信息访问'),
    para('您可以前往设置 ，访问您的服务器管理。'),
    para('2.2 信息更正'),
    para('当您需要更新您的个人信息，或发现我们处理您的个人信息有误时，您有权作出更正或更新。'),
    para('您可以前往设置，访问并修改您的服务器地址、密码 / API Key。'),
    para('2.3 信息删除'),
    para('您可以前往设置 → 服务器管理（删除服务器），以删除您的服务器配置与登录凭据。'),
    para('2.4 撤销同意'),
    para('如果您需撤销上述个人信息处理您的信息，您可以前往卸载本应用，或在设置中删除已添加的服务器来撤销您的同意。'),
    para('如您对您的数据主体权利有进一步要求或存在任何疑问、意见或建议，可通过本声明中“如何联系我们”章节中所述方式与我们取得联系，并行使您的相关权利。'),

    head('3. 信息存储地点及期限'),
    para('3.1 固定存储期限：服务器地址与登录凭据：保存在您的设备本地，直至您删除对应服务器或卸载应用；IP 归属查询结果：缓存 7 天后自动清除'),
    para('3.2 上述信息将会传输并保存至您的设备本地，以及您个人自建的服务器。'),

    head('4. 如何联系我们'),
    para('您可通过以下方式联系我们，并行使您的相关权利，我们会尽快回复。'),
    para('邮箱：3248076788@qq.com'),
    para('本应用由李科杨（个人开发者）开发与维护。如您对本声明或个人信息处理有任何疑问、意见或建议，可通过上方邮箱与我们联系；亦可在开源社区提交 Issue：\nhttps://github.com/lky005/komari-harmonyos-client/issues\n\n我们会在收到您的反馈后尽快（通常在 15 个工作日内）核实并处理回复。'),
    para('如果您对我们的回复不满意, 特别是当个人信息处理行为损害了您的合法权益时您还可以通过向有管辖权的人民法院提起诉讼、向行业自律协会或政府相关管理机构投诉等外部途径进行解决。 您也可以向我们了解可能适用的相关投诉途径的信息。')
  ];
}
