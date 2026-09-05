/**
 * LineChart —— 基于 Canvas 的轻量折线图（API 24，无第三方依赖）
 *
 * 功能：
 *  - Canvas onReady 获取真实像素尺寸，零布局竞态（替代原 onAreaChange 方案）
 *  - Y 轴：4 段 nice-number 刻度（向上取整 + 15% 安全内衬），右侧对齐
 *  - X 轴：开始/中间/结束 三个时间标签，按时间范围自动格式化
 *  - 网格：3 条水平虚线
 *  - 触摸：按下/移动显示垂直指示线 + 数据点圆点 + tooltip，抬起隐藏
 *  - 曲线按点数等分撑满绘图区宽度（与真实时间跨度无关）
 *  - 抗锯齿：RenderingContextSettings(true) 显式开启（SDK 默认 false）
 *  - 手势冲突：纵向位移 >10vp 且 >横向位移时自动取消 Tooltip，让父级 Scroll 接管
 *
 * 向后兼容：
 *  - histTicks 未传入（长度 != 4）时，内部 fallbackTicks() 自动计算
 *  - timestamps/unit/timeRangeHours 均有默认值，PingDetailPage 只传 values 也能正常工作
 *  - lineColor 参数保留（PingDetailPage 仍在传），但 Canvas fillStyle 不接受 Resource，
 *    当前浅色模式使用固定主题色 #0A59F7；未来深色模式适配时需传入已解析的颜色字符串
 *
 * 踩坑记录：
 *  - CanvasRenderingContext2D 默认 antialias=false，必须 new RenderingContextSettings(true)
 *  - Canvas 坐标系是 px，触摸坐标是 vp，需 × density 转换
 *  - fillStyle/strokeStyle 类型为 string|number|CanvasGradient|CanvasPattern，不接受 Resource
 *  - @Prop 必须加 @Watch 才能在数据变化时触发 redraw()
 *  - 子组件可变参数必须加 @Prop，否则父组件 @State 变化后子组件不刷新
 *  - build() 中禁止 const 变量声明，ArkTS 编译器误判为多根节点
 *  - onAreaChange 存在布局竞态（布局→回调→改状态→布局循环），Canvas onReady 是标准替代
 */

import { display } from '@kit.ArkUI';

@Component
export struct LineChart {
  // ===== 数据入参 =====
  @Prop @Watch('onDataChanged') values: number[] = [];
  @Prop timestamps: number[] = [];
  @Prop unit: string = '';
  @Prop timeRangeHours: number = 6;
  @Prop lineColor: Resource = $r('sys.color.ohos_id_color_emphasize');  // 保留兼容，Canvas 暂不使用 Resource
  @Prop emptyText: string = '暂无数据';
  @Prop @Watch('onDataChanged') histTicks: number[] = [];  // 父组件预计算的 Y 轴刻度，空则内部 fallback
  @Prop chartHeight: number = 150;   // 绘图区高度（vp），默认 150 保持兼容
  @Prop lineWidthVp: number = 2;      // 折线宽度（vp），默认 2 保持兼容

  // ===== 内部状态 =====
  @State touchIdx: number = -1;
  @State cachedTicks: number[] = [0, 0.25, 0.5, 1];
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private canvasWpx: number = 0;
  private canvasHpx: number = 0;
  private density: number = 1;
  private readonly padXvp: number = 2;
  private readonly yLabelWvp: number = 42;
  private readonly lineColorHex: string = '#0A59F7';  // 与 $r('sys.color.ohos_id_color_emphasize') 一致
  // 手势冲突检测
  private startX: number = 0;
  private startY: number = 0;
  private scrolling: boolean = false;

  // ===== 生命周期 =====
  aboutToDisappear(): void {
    this.touchIdx = -1;
  }

  // ===== 数据变化驱动重绘 =====
  private onDataChanged(): void {
    this.cachedTicks = this.computeTicks();
    if (this.canvasWpx > 0) {
      this.redraw();
    }
  }

  // ===== Y 轴刻度计算 =====
  private computeTicks(): number[] {
    if (Array.isArray(this.histTicks) && this.histTicks.length === 4) {
      return this.histTicks;
    }
    return this.fallbackTicks();
  }

  private fallbackTicks(): number[] {
    if (this.values.length === 0) {
      return [0, 0.25, 0.5, 1];
    }
    let dataMin: number = Infinity;
    let dataMax: number = -Infinity;
    for (const v of this.values) {
      if (v < dataMin) dataMin = v;
      if (v > dataMax) dataMax = v;
    }
    const range: number = dataMax - dataMin;
    if (range < 1e-6) {
      // 平线/全零：以 0 为底，上限为 max(dataMax, 1)
      const top: number = Math.max(dataMax, 1);
      const roughStep: number = top / 3;
      const exp: number = Math.floor(Math.log10(roughStep));
      const frac: number = roughStep / Math.pow(10, exp);
      const niceFrac: number = frac <= 1 ? 1 : frac <= 2 ? 2 : frac <= 5 ? 5 : 10;
      const tickStep: number = niceFrac * Math.pow(10, exp);
      return [0, tickStep, tickStep * 2, tickStep * 3];
    }
    // 正常范围：15% padding + 扩充范围算步长 + while 兜底防穿透
    const pad: number = range * 0.15;
    const targetMin: number = Math.max(0, dataMin - pad);
    const targetMax: number = dataMax + pad;
    const roughStep: number = (targetMax - targetMin) / 3;
    const exp: number = Math.floor(Math.log10(roughStep));
    const frac: number = roughStep / Math.pow(10, exp);
    const niceFrac: number = frac <= 1 ? 1 : frac <= 2 ? 2 : frac <= 5 ? 5 : 10;
    let tickStep: number = niceFrac * Math.pow(10, exp);
    let niceMin: number = Math.max(0, Math.floor(targetMin / tickStep) * tickStep);
    while (niceMin + tickStep * 3 < dataMax) {
      tickStep *= 1.2;
    }
    const niceMax: number = niceMin + tickStep * 3;
    return [niceMin, niceMin + tickStep, niceMin + tickStep * 2, niceMax];
  }

  // ===== 坐标映射（vp 坐标系）=====
  private valueToY(v: number, ticks: number[]): number {
    const niceMin: number = ticks[0];
    const niceMax: number = ticks[3];
    const range: number = niceMax - niceMin;
    if (range < 1e-9) {
      return this.chartHeight / 2;
    }
    const ratio: number = (v - niceMin) / range;
    return this.chartHeight - ratio * this.chartHeight;  // 顶部 y=0，底部 y=chartH
  }

  private idxToXvp(i: number, n: number): number {
    const w: number = this.canvasWvp() - 2 * this.padXvp;
    return this.padXvp + (i * w) / Math.max(n - 1, 1);
  }

  private canvasWvp(): number {
    return this.density > 0 ? this.canvasWpx / this.density : 0;
  }

  private touchToIdx(touchXvp: number): number {
    const n: number = this.values.length;
    if (n === 0) return -1;
    const w: number = this.canvasWvp() - 2 * this.padXvp;
    if (w <= 0) return 0;
    const ratio: number = Math.max(0, Math.min(1, (touchXvp - this.padXvp) / w));
    return Math.max(0, Math.min(n - 1, Math.round(ratio * (n - 1))));
  }

  // ===== 绘制 =====
  private redraw(): void {
    const ctx: CanvasRenderingContext2D = this.ctx;
    if (this.canvasWpx <= 0 || this.canvasHpx <= 0) {
      return;
    }
    ctx.clearRect(0, 0, this.canvasWpx, this.canvasHpx);
    if (this.values.length === 0) {
      return;
    }
    const ticks: number[] = this.cachedTicks;
    const n: number = this.values.length;
    const d: number = this.density;
    const color: string = this.lineColorHex;

    // --- 网格线（3 条水平虚线）---
    ctx.setLineDash([4 * d, 4 * d]);
    ctx.strokeStyle = '#E4E3DD';
    ctx.lineWidth = 0.5 * d;
    for (let gi: number = 1; gi <= 3; gi++) {
      const ypx: number = this.valueToY(ticks[gi], ticks) * d;
      ctx.beginPath();
      ctx.moveTo(0, ypx);
      ctx.lineTo(this.canvasWpx, ypx);
      ctx.stroke();
    }
    ctx.setLineDash([]);

    // --- 面积填充 ---
    ctx.beginPath();
    const x0px: number = this.idxToXvp(0, n) * d;
    const y0px: number = this.valueToY(this.values[0], ticks) * d;
    ctx.moveTo(x0px, y0px);
    for (let i: number = 1; i < n; i++) {
      ctx.lineTo(this.idxToXvp(i, n) * d, this.valueToY(this.values[i], ticks) * d);
    }
    const xnpx: number = this.idxToXvp(n - 1, n) * d;
    ctx.lineTo(xnpx, this.chartHeight * d);
    ctx.lineTo(x0px, this.chartHeight * d);
    ctx.closePath();
    ctx.fillStyle = color;
    ctx.globalAlpha = 0.12;
    ctx.fill();
    ctx.globalAlpha = 1.0;

    // --- 折线 ---
    ctx.beginPath();
    ctx.moveTo(x0px, y0px);
    for (let i: number = 1; i < n; i++) {
      ctx.lineTo(this.idxToXvp(i, n) * d, this.valueToY(this.values[i], ticks) * d);
    }
    ctx.strokeStyle = color;
    ctx.lineWidth = this.lineWidthVp * d;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.stroke();

    // --- 触摸指示器 ---
    if (this.touchIdx >= 0 && this.touchIdx < n) {
      const xpx: number = this.idxToXvp(this.touchIdx, n) * d;
      const ypx: number = this.valueToY(this.values[this.touchIdx], ticks) * d;

      // 垂直虚线
      ctx.setLineDash([3 * d, 3 * d]);
      ctx.strokeStyle = color;
      ctx.globalAlpha = 0.4;
      ctx.lineWidth = 1 * d;
      ctx.beginPath();
      ctx.moveTo(xpx, 0);
      ctx.lineTo(xpx, this.chartHeight * d);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.globalAlpha = 1.0;

      // 圆点（白填充 + 主题色描边）
      ctx.beginPath();
      ctx.arc(xpx, ypx, 4 * d, 0, Math.PI * 2);
      ctx.fillStyle = '#FFFFFF';
      ctx.fill();
      ctx.strokeStyle = color;
      ctx.lineWidth = 2 * d;
      ctx.stroke();
    }
  }

  // ===== 格式化 =====
  private fmtTick(v: number): string {
    if (Math.abs(v) >= 1000) {
      return `${Math.round(v)}`;
    }
    if (Math.abs(v) >= 100) {
      return v.toFixed(0);
    }
    if (Math.abs(v) >= 10) {
      return v.toFixed(1);
    }
    if (Math.abs(v) >= 1) {
      return v.toFixed(2);
    }
    return v.toFixed(3);
  }

  private fmtTime(ts: number): string {
    if (ts <= 0) return '';
    const d: Date = new Date(ts);
    const hh: string = d.getHours().toString().padStart(2, '0');
    const mm: string = d.getMinutes().toString().padStart(2, '0');
    if (this.timeRangeHours <= 6) {
      return `${hh}:${mm}`;
    }
    if (this.timeRangeHours <= 24) {
      return `${d.getMonth() + 1}-${d.getDate()} ${hh}:${mm}`;
    }
    return `${d.getMonth() + 1}-${d.getDate()}`;
  }

  private fmtTooltipValue(v: number): string {
    if (this.unit.length > 0) {
      return `${v.toFixed(2)} ${this.unit}`;
    }
    if (Math.abs(v) >= 100) {
      return `${Math.round(v)}`;
    }
    return v.toFixed(2);
  }

  // ===== 触摸处理（含 Scroll 手势冲突检测）=====
  private handleTouch(event: TouchEvent): void {
    if (this.values.length === 0) return;
    const touch: TouchObject | undefined = event.touches[0];
    if (!touch) return;

    if (event.type === TouchType.Down) {
      this.startX = touch.x;
      this.startY = touch.y;
      this.scrolling = false;
      const idx: number = this.touchToIdx(touch.x);
      if (idx >= 0 && idx !== this.touchIdx) {
        this.touchIdx = idx;
        this.redraw();
      }
    } else if (event.type === TouchType.Move) {
      const dx: number = touch.x - this.startX;
      const dy: number = touch.y - this.startY;
      // 纵向位移 >10vp 且 >横向位移 → 用户意图为滚动页面，取消 Tooltip
      if (!this.scrolling && Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) {
        this.scrolling = true;
        if (this.touchIdx !== -1) {
          this.touchIdx = -1;
          this.redraw();
        }
        return;
      }
      if (this.scrolling) {
        return;
      }
      const idx: number = this.touchToIdx(touch.x);
      if (idx >= 0 && idx !== this.touchIdx) {
        this.touchIdx = idx;
        this.redraw();
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.scrolling = false;
      if (this.touchIdx !== -1) {
        this.touchIdx = -1;
        this.redraw();
      }
    }
  }

  // ===== Tooltip 定位（vp，自动避边）=====
  private tooltipXvp(): number {
    if (this.touchIdx < 0) return 0;
    const xvp: number = this.idxToXvp(this.touchIdx, this.values.length);
    const tooltipWvp: number = 90;
    const maxX: number = Math.max(0, this.canvasWvp() - tooltipWvp - 4);
    return Math.max(4, Math.min(maxX, xvp - tooltipWvp / 2));
  }

  build() {
    Row() {
      // ===== Y 轴标签 =====
      Column() {
        ForEach(this.cachedTicks, (tick: number, idx: number) => {
          Text(this.fmtTick(tick))
            .fontSize(10)
            .fontColor('#999999')
            .width('100%')
            .textAlign(TextAlign.End)
            .layoutWeight(1)
        }, (tick: number, idx: number) => `ytick-${idx}-${tick}`)
      }
      .width(this.yLabelWvp)

      // ===== 图表区 =====
      Column({ space: 2 }) {
        Stack({ alignContent: Alignment.TopStart }) {
          Canvas(this.ctx)
            .width('100%')
            .height(this.chartHeight)
            .onReady((): void => {
              this.density = display.getDefaultDisplaySync().densityPixels;
              this.canvasWpx = this.ctx.width;
              this.canvasHpx = this.ctx.height;
              this.cachedTicks = this.computeTicks();
              this.redraw();
            })
            .onTouch((event: TouchEvent): void => {
              this.handleTouch(event);
            })

          // 空态
          if (this.values.length === 0) {
            Column() {
              Text(this.emptyText)
                .fontSize(12)
                .fontColor('#999999')
            }
            .width('100%')
            .height(this.chartHeight)
            .justifyContent(FlexAlign.Center)
          }

          // Tooltip
          if (this.touchIdx >= 0 && this.touchIdx < this.values.length && this.timestamps.length > this.touchIdx) {
            Column({ space: 2 }) {
              Text(this.fmtTime(this.timestamps[this.touchIdx]))
                .fontSize(9)
                .fontColor('#FFFFFF')
                .opacity(0.8)
              Text(this.fmtTooltipValue(this.values[this.touchIdx]))
                .fontSize(11)
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Medium)
            }
            .padding({ left: 8, right: 8, top: 5, bottom: 5 })
            .borderRadius(8)
            .backgroundColor('rgba(0,0,0,0.75)')
            .position({ x: this.tooltipXvp(), y: 6 })
          }
        }
        .width('100%')
        .height(this.chartHeight)
        .clip(true)

        // ===== X 轴标签 =====
        if (this.timestamps.length >= 2) {
          Row() {
            Text(this.fmtTime(this.timestamps[0]))
              .fontSize(10)
              .fontColor('#999999')
              .layoutWeight(1)
            Text(this.fmtTime(this.timestamps[Math.floor(this.timestamps.length / 2)]))
              .fontSize(10)
              .fontColor('#999999')
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
            Text(this.fmtTime(this.timestamps[this.timestamps.length - 1]))
              .fontSize(10)
              .fontColor('#999999')
              .textAlign(TextAlign.End)
              .layoutWeight(1)
          }
          .width('100%')
        }
      }
      .layoutWeight(1)
    }
    .width('100%')
  }
}
