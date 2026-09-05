/**
 * MetricBar —— 带标签的线性指标条（CPU / 内存 / 磁盘等）
 *
 * percent < 0 表示暂无数据，显示 '-'。
 * 颜色分档：<70 正常，<90 警告，>=90 危险。
 * help 非空时标签旁出现问号，点按弹出 bindPopup 指标说明气泡（GPU 在用）。
 */

/** bindPopup onStateChange 回调的事件形态（d.ts 里是匿名对象类型，ArkTS 要求显式接口） */
interface PopupVisibleEvent {
  isVisible: boolean;
}

@Component
export struct MetricBar {
  @Prop label: string = '';
  @Prop percent: number = -1;
  @Prop detail: string = '';
  /** 非空时标签旁显示问号，点按弹出指标说明气泡 */
  @Prop help: string = '';
  @State showHelp: boolean = false;

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
        Row({ space: 2 }) {
          Text(this.label)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          if (this.help.length > 0) {
            // 24vp 命中区：纯小图标难点中；这里无父级点击，不存在误触问题
            Row() {
              SymbolGlyph($r('sys.symbol.questionmark_circle'))
                .fontSize(12)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width(24)
            .height(24)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .onClick((): void => {
              this.showHelp = !this.showHelp;
            })
            .bindPopup(this.showHelp, {
              message: this.help,
              placement: Placement.Top,
              onStateChange: (e: PopupVisibleEvent): void => {
                if (!e.isVisible) {
                  this.showHelp = false;
                }
              }
            })
          }
        }
        .alignItems(VerticalAlign.Center)
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
