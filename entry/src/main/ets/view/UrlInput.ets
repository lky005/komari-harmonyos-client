/**
 * UrlInput —— 协议 + 域名输入（首启引导页与服务端编辑弹层共用）
 *
 * 设计目标（防错优先）：
 *   - 协议用按钮选择（仅 http/https），用户不输入 "://"；
 *   - 粘贴完整链接自动解析：识别协议并切换按钮，路径部分保留不剥
 *     （Komari 不支持子路径部署，但反代场景下 baseUrl 带路径仍可用，
 *      剥掉路径反而会造成连不上）；
 *   - host 校验 + http/内网风险提示：放行不阻断，仅黄色小字提醒。
 *
 * 约定：https === true 表示 HTTPS（默认）。
 */

/** 解析结果：https + host[:port][/path] */
export interface ParsedUrl {
  https: boolean;
  rest: string;
}

/** 解析粘贴进来的完整/半完整 URL；无协议头时按 https 处理 */
export function parsePastedUrl(raw: string): ParsedUrl {
  let u: string = raw.trim();
  let https: boolean = true;
  const schemeIdx: number = u.indexOf('://');
  if (schemeIdx >= 0) {
    const scheme: string = u.substring(0, schemeIdx).toLowerCase();
    https = scheme !== 'http';
    u = u.substring(schemeIdx + 3);
  }
  // 防粘贴带空格或尾部斜杠
  const spaceIdx: number = u.indexOf(' ');
  if (spaceIdx >= 0) {
    u = u.substring(0, spaceIdx);
  }
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  const r: ParsedUrl = { https: https, rest: u };
  return r;
}

/**
 * host 部分（路径之前）是否为"可能解析得通"的地址。只拦非法内容，正常域名与 IP 一律放行：
 *   - 字符集限 [a-z0-9.-] 加端口冒号（中文等乱码直接拒）；
 *   - 标签不允许空段与连字符开头/结尾；
 *   - 全数字形态必须是合法 IPv4（恰好 4 段、每段 0-255，"123"/"192.168.1" 拒绝）；
 *   - 局域网单标签主机名（如 nas）须含字母；
 *   - IPv6 暂不支持（方括号字面量与裸 v6 一律拒绝，由提示文案说明）。
 */
export function validateHostRest(rest: string): boolean {
  const t: string = rest.trim().toLowerCase();
  if (t.length === 0) {
    return false;
  }
  const hostPart: string = t.split('/')[0];
  if (hostPart.length === 0) {
    return false;
  }
  if (hostPart.startsWith('[')) {
    // IPv6 暂不支持
    return false;
  }
  // 剥端口（裸 IPv6 含多个冒号，会被端口校验拦下）
  let host: string = hostPart;
  const colon: number = hostPart.indexOf(':');
  if (colon >= 0) {
    const port: string = hostPart.substring(colon + 1);
    if (!/^[0-9]{1,5}$/.test(port) || Number(port) < 1 || Number(port) > 65535) {
      return false;
    }
    host = hostPart.substring(0, colon);
  }
  if (host.length === 0 || host.indexOf(':') >= 0) {
    return false;
  }
  if (!/^[a-z0-9.\-]+$/.test(host)) {
    return false;
  }
  const labels: string[] = host.split('.');
  for (let i = 0; i < labels.length; i++) {
    if (labels[i].length === 0 || labels[i].startsWith('-') || labels[i].endsWith('-')) {
      return false;
    }
  }
  let allNumeric: boolean = true;
  let hasLetter: boolean = false;
  for (let i = 0; i < labels.length; i++) {
    if (!/^[0-9]+$/.test(labels[i])) {
      allNumeric = false;
    }
    if (/[a-z]/.test(labels[i])) {
      hasLetter = true;
    }
  }
  if (allNumeric) {
    if (labels.length !== 4) {
      return false;
    }
    for (let i = 0; i < 4; i++) {
      if (Number(labels[i]) > 255) {
        return false;
      }
    }
    return true;
  }
  // 单标签：含字母才视为局域网主机名（纯数字串在上面已被拦）
  if (labels.length === 1) {
    return hasLetter;
  }
  // 多标签：不校验 TLD 形态，正常域名与局域网 FQDN（含 server.1 之类）一律放行
  return true;
}

/** 是否内网/本机地址（仅做提示，不阻断） */
export function isPrivateHost(rest: string): boolean {
  let h: string = rest.trim().split('/')[0].toLowerCase();
  if (h.length === 0) {
    return false;
  }
  if (h.startsWith('[')) {
    // IPv6 字面量 [::1]:8080
    const end: number = h.indexOf(']');
    h = end >= 0 ? h.substring(1, end) : h.substring(1);
  } else {
    const colon: number = h.indexOf(':');
    if (colon >= 0) {
      h = h.substring(0, colon);
    }
  }
  if (h === 'localhost' || h.endsWith('.local') || h.endsWith('.lan') || h.endsWith('.home')) {
    return true;
  }
  if (h.indexOf(':') >= 0) {
    // 裸 IPv6：环回 / 链路本地 fe80::/10 / ULA fc00::/7
    return h === '::1' || h.startsWith('fe80') || h.startsWith('fc') || h.startsWith('fd');
  }
  if (!h.includes('.')) {
    // 单标签含字母的主机名（如 nas）几乎必然是内网机器名；
    // 纯数字串（如 123）没有域名形态，不判内网
    return /[a-z]/.test(h);
  }
  // IPv4 私有/环回/链路本地段
  const seg: string[] = h.split('.');
  if (seg.length !== 4) {
    return false;
  }
  for (let i = 0; i < 4; i++) {
    if (!/^[0-9]+$/.test(seg[i]) || Number(seg[i]) > 255) {
      return false;
    }
  }
  const a: number = Number(seg[0]);
  const b: number = Number(seg[1]);
  if (a === 10 || a === 127) {
    return true;
  }
  if (a === 172 && b >= 16 && b <= 31) {
    return true;
  }
  if (a === 192 && b === 168) {
    return true;
  }
  if (a === 169 && b === 254) {
    return true;
  }
  return false;
}

/** 探测/保存前的归一化：文本里残留显式协议头时以文本为准（覆盖协议按钮选择） */
export function resolveScheme(https: boolean, rest: string): ParsedUrl {
  if (rest.indexOf('://') >= 0) {
    return parsePastedUrl(rest);
  }
  const r: ParsedUrl = { https: https, rest: rest.trim() };
  return r;
}

/** 拼出 baseUrl，规范化掉末尾斜杠；rest 残留协议头时兜底剥掉，保证单一协议 */
export function buildBaseUrl(https: boolean, rest: string): string {
  const scheme: string = https ? 'https' : 'http';
  let u: string = rest.trim();
  const schemeIdx: number = u.indexOf('://');
  if (schemeIdx >= 0) {
    u = u.substring(schemeIdx + 3);
  }
  u = `${scheme}://${u}`;
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  return u;
}

@Component
export struct UrlInput {
  /** true = HTTPS（默认），false = HTTP */
  @Link https: boolean;
  /** host[:port][/path]，无协议头 */
  @Link rest: string;

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        this.pill('HTTPS', true)
        this.pill('HTTP', false)
      }
      .width('100%')

      TextInput({ text: this.rest, placeholder: 'panel.example.com' })
        .height(44)
        .fontSize(15)
        .backgroundColor($r('app.color.card_bg'))
        .onChange((v: string): void => {
          // 粘贴完整链接时自动解析协议与路径；普通输入直接透传
          if (v.indexOf('://') >= 0) {
            const p: ParsedUrl = parsePastedUrl(v);
            this.https = p.https;
            this.rest = p.rest;
          } else {
            this.rest = v;
          }
        })

      if (!this.https) {
        Text('HTTP 为明文传输，登录密码可能被窃听，建议改用 HTTPS')
          .fontSize(11)
          .fontColor($r('app.color.status_warn'))
          .width('100%')
      }
      if (isPrivateHost(this.rest)) {
        Text('这是内网或本机地址，仅在同一网络下可以访问')
          .fontSize(11)
          .fontColor($r('app.color.status_warn'))
          .width('100%')
      }
      if (this.rest.length > 0 && !validateHostRest(this.rest)) {
        Text('不是有效的域名或 IPv4 地址，暂不支持 IPv6')
          .fontSize(11)
          .fontColor($r('app.color.status_bad'))
          .width('100%')
      }
    }
    .width('100%')
  }

  @Builder
  pill(label: string, value: boolean) {
    Text(label)
      .fontSize(12)
      .fontColor(this.https === value ? Color.White : $r('app.color.text_secondary'))
      .backgroundColor(this.https === value ? $r('sys.color.ohos_id_color_emphasize') : $r('app.color.page_bg'))
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(8)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .onClick((): void => {
        this.https = value;
      })
  }
}
