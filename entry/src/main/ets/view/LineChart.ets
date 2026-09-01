/**
 * LineChart —— 轻量折线图（自绘，无第三方依赖）
 *
 * 输入：已清洗的数值数组（null/NaN 由调用方过滤）。
 * 宽度自适应：onAreaChange 拿到实际宽度后重算路径。
 * 实现：两层 Path——面积填充 + 描边线，M/L 指令字符串拼接。
 *
 * 已知限制：无坐标轴刻度、无时间轴标签，摘要（当前/最小/最大/平均）由调用方渲染。
 */

@Component
export struct LineChart {
  @Prop values: number[] = [];
  @Prop lineColor: Resource = $r('app.color.accent');
  @Prop emptyText: string = '暂无数据';
  @State chartW: number = 0;
  @State chartH: number = 150;

  /** 生成 SVG Path 指令串；area=true 时闭合到底部做面积填充 */
  private buildCmds(area: boolean): string {
    const n: number = this.values.length;
    if (n === 0 || this.chartW <= 0 || this.chartH <= 0) {
      return '';
    }
    let min: number = this.values[0];
    let max: number = this.values[0];
    this.values.forEach((v: number): void => {
      if (v < min) {
        min = v;
      }
      if (v > max) {
        max = v;
      }
    });
    const padTop: number = 10;
    const padBottom: number = 10;
    const padX: number = 2;
    const w: number = this.chartW - padX * 2;
    const h: number = this.chartH - padTop - padBottom;
    if (w <= 0 || h <= 0) {
      return '';
    }
    const range: number = max - min;
    const parts: string[] = [];
    for (let i = 0; i < n; i++) {
      const x: number = padX + (n === 1 ? w / 2 : (i * w) / (n - 1));
      const y: number = padTop + (range <= 0 ? h / 2 : (1 - (this.values[i] - min) / range) * h);
      parts.push(`${i === 0 ? 'M' : 'L'}${x.toFixed(1)} ${y.toFixed(1)}`);
    }
    if (area) {
      parts.push(`L${(padX + w).toFixed(1)} ${(this.chartH - 1).toFixed(1)}`);
      parts.push(`L${padX.toFixed(1)} ${(this.chartH - 1).toFixed(1)}`);
      parts.push('Z');
    }
    return parts.join(' ');
  }

  build() {
    Stack() {
      if (this.values.length === 0) {
        Text(this.emptyText)
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
      } else {
        Path({ width: this.chartW, height: this.chartH })
          .commands(this.buildCmds(true))
          .fill(this.lineColor)
          .fillOpacity(0.12)
          .strokeOpacity(0)
        Path({ width: this.chartW, height: this.chartH })
          .commands(this.buildCmds(false))
          .fillOpacity(0)
          .stroke(this.lineColor)
          .strokeWidth(2)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
      }
    }
    .width('100%')
    .height(this.chartH)
    .alignContent(Alignment.TopStart)
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      const w: number = Number(newArea.width);
      if (w > 0 && Math.abs(w - this.chartW) > 0.5) {
        this.chartW = w;
      }
    })
  }
}
