/**
 * MetricBar —— 带标签的线性指标条（CPU / 内存 / 磁盘等）
 *
 * percent < 0 表示暂无数据，显示 '-'。
 * 颜色分档：<70 正常，<90 警告，>=90 危险。
 */

@Component
export struct MetricBar {
  @Prop label: string = '';
  @Prop percent: number = -1;
  @Prop detail: string = '';

  private barColor(): Resource {
    if (this.percent < 0) {
      return $r('app.color.text_tertiary');
    }
    if (this.percent >= 90) {
      return $r('app.color.status_bad');
    }
    if (this.percent >= 70) {
      return $r('app.color.status_warn');
    }
    return $r('app.color.status_ok');
  }

  private percentText(): string {
    if (this.percent < 0) {
      return '-';
    }
    return `${Math.round(this.percent)}%`;
  }

  build() {
    Column({ space: 4 }) {
      Row() {
        Text(this.label)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Blank()
        Text(this.percentText())
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.barColor())
      }
      .width('100%')

      Progress({ value: this.percent < 0 ? 0 : this.percent, total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(6)
        .color(this.barColor())
        .backgroundColor($r('app.color.divider'))

      if (this.detail.length > 0) {
        Text(this.detail)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}
