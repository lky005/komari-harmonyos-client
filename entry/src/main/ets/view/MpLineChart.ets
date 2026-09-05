/**
 * MpLineChart —— 基于 @ohos/mpchart (3.0.30) 的折线图包装组件（路径 A：自定义触摸）
 *
 * 设计目标：
 *  - 对外接口与 view/LineChart.ets 完全一致（9 个 @Prop），业务页零改动即可替换
 *  - 路径 A：关闭 mpchart 内部触摸（setTouchEnabled(false)），外层 Stack 自定义 onTouch，
 *    手写位移阈值检测（纵向>10vp 让父级 Scroll 接管），手动 model.highlightValue() 触发高亮
 *  - Tooltip 用 ArkUI 组件叠加（非 mpchart MarkerView），完全可控
 *  - 仅使用 mpchart 的 LineChart 单类型
 *
 * 触摸交互流程：
 *  Down  → 记录起始坐标，scrolling=false
 *  Move  → 纵向位移>10vp 且>横向位移 → scrolling=true，清除高亮，return（让 Scroll 接管）
 *          否则 → 计算最近数据点索引，model.highlightValue() 触发高亮，更新 Tooltip
 *  Up    → scrolling 则清除高亮；否则保持 Tooltip 显示
 *  Cancel→ 清除高亮
 *
 * mpchart 3.0.30 API 注意事项：
 *  - 颜色全部用 number（0xAARRGGBB），不接受 string
 *  - LineDataSet 构造函数参数是 JArrayList<EntryOhos>
 *  - LineData 构造函数参数是 ILineDataSet[] 数组
 *  - 设颜色方法叫 setColorByColor(color: Number)
 *  - getXAxis/getAxisLeft 等返回可空类型，需判空
 *  - highlightValue(x, y?, dataSetIndex?, dataIndex?, callListener?) 手动触发高亮
 *  - ohpm latest 稳定版 3.0.30，源码仓库 4.0.0-rc.3 尚未发布
 */

import {
  LineChart,
  LineChartModel,
  LineData,
  LineDataSet,
  EntryOhos,
  XAxis,
  XAxisPosition,
  YAxis,
  Legend,
  Description,
  Mode,
  JArrayList,
  IAxisValueFormatter,
  AxisBase,
  Highlight
} from '@ohos/mpchart';

/**
 * X 轴时间标签格式化器
 * value 是数据点索引（EntryOhos 的 x = 索引），返回对应时间戳的格式化字符串
 */
class TimeAxisFormatter implements IAxisValueFormatter {
  private timestamps: number[] = [];
  private rangeHours: number = 6;

  setData(timestamps: number[], rangeHours: number): void {
    this.timestamps = timestamps;
    this.rangeHours = rangeHours;
  }

  getFormattedValue(value: number, axis: AxisBase): string {
    const idx: number = Math.round(value);
    if (idx < 0 || idx >= this.timestamps.length) {
      return '';
    }
    return this.formatTime(this.timestamps[idx]);
  }

  private formatTime(ts: number): string {
    const d: Date = new Date(ts);
    const hh: string = String(d.getHours()).padStart(2, '0');
    const mm: string = String(d.getMinutes()).padStart(2, '0');
    if (this.rangeHours <= 1) {
      return `${hh}:${mm}`;
    }
    const MM: string = String(d.getMonth() + 1).padStart(2, '0');
    const dd: string = String(d.getDate()).padStart(2, '0');
    return `${MM}-${dd} ${hh}:${mm}`;
  }
}

@Component
export struct MpLineChart {
  // ===== 数据入参（与 LineChart.ets 完全一致） =====
  @Prop @Watch('onDataChanged') values: number[] = [];
  @Prop @Watch('onDataChanged') timestamps: number[] = [];
  @Prop unit: string = '';
  @Prop timeRangeHours: number = 6;
  @Prop lineColor: Resource = $r('app.color.accent');  // 保留兼容，mpchart 使用固定 number
  @Prop emptyText: string = '暂无数据';
  @Prop @Watch('onDataChanged') histTicks: number[] = [];  // 保留兼容，mpchart 内部自动计算
  @Prop chartHeight: number = 150;   // 绘图区高度（vp）
  @Prop lineWidthVp: number = 2;      // 折线宽度（vp）
  @Prop line1Label: string = '';       // 第一条线名称（Tooltip 显示）
  // ===== 第二条线（双线模式，values2 非空时启用） =====
  @Prop @Watch('onDataChanged') values2: number[] = [];  // 第二条线数据
  @Prop line2Label: string = '';       // 第二条线名称（Tooltip 显示）
  @Prop line2Color: number = 0xFF2FA36B;  // 第二条线颜色（绿色 status_ok）

  // ===== 内部状态 =====
  private model: LineChartModel = new LineChartModel();
  private modelConfigured: boolean = false;
  private timeFormatter: TimeAxisFormatter = new TimeAxisFormatter();
  // 颜色用 0xAARRGGBB 格式 number
  private readonly lineColorNum: number = 0xFF0A59F7;  // 与 $r('app.color.accent') 一致
  private readonly gridColorNum: number = 0xFFE4E3DD;
  private readonly textColorNum: number = 0xFF999999;
  private readonly tooltipBgNum: number = 0xD91A1A1A;  // 85% 不透明深灰，白字清晰
  private readonly tooltipTextNum: number = 0xFFFFFFFF;   // 一级文本（主线数值）
  private readonly tooltipTextSecondary: number = 0xCCFFFFFF;  // 二级文本（副线数值/时间）

  // ===== 触摸状态（路径 A：自定义 onTouch） =====
  @State touchIdx: number = -1;       // 当前选中的数据点索引，-1 表示无选中
  @State touchXvp: number = 0;         // 触摸点 x 坐标（vp），用于 Tooltip 横向定位
  @State tooltipVisible: boolean = false;
  @State chartWvp: number = 1;         // 组件实际宽度（vp），onAreaChange 动态更新
  private startX: number = 0;
  private startY: number = 0;
  private scrolling: boolean = false;
  private readonly SCROLL_THRESHOLD_VP: number = 10;  // 纵向位移阈值，超过则判定为滚动

  // ===== 生命周期 =====
  aboutToAppear(): void {
    this.configureModel();
    this.updateData();
  }

  // ===== 模型配置（仅执行一次） =====
  private configureModel(): void {
    if (this.modelConfigured) {
      return;
    }

    // 路径 A：关闭 mpchart 内部触摸，完全由外层 onTouch 处理
    this.model.setTouchEnabled(false);

    // X 轴：底部，3 个时间标签
    const xAxis: XAxis | null = this.model.getXAxis();
    if (xAxis !== null) {
      xAxis.setPosition(XAxisPosition.BOTTOM);
      xAxis.setDrawGridLines(false);
      xAxis.setDrawLabels(true);
      xAxis.setDrawAxisLine(false);
      xAxis.setTextColor(this.textColorNum);
      xAxis.setTextSize(9);
      xAxis.setLabelCount(3, true);  // 强制 3 个标签（首/中/尾）
      xAxis.setValueFormatter(this.timeFormatter);
      xAxis.setYOffset(5);  // X 轴标签与图表底部的间距
    }

    // 左 Y 轴
    const leftAxis: YAxis | null = this.model.getAxisLeft();
    if (leftAxis !== null) {
      leftAxis.setDrawGridLines(true);
      leftAxis.setGridColor(this.gridColorNum);
      leftAxis.setTextColor(this.textColorNum);
      leftAxis.setTextSize(10);
      leftAxis.setDrawAxisLine(false);
      leftAxis.setLabelCount(4, true);
      leftAxis.setXOffset(8);  // Y 轴标签与图表左侧的间距
      leftAxis.setStartAtZero(true);  // Y 轴底线锁死 0，不出现负数刻度
      leftAxis.setSpaceTop(10);  // 顶部只留 10% 空间，尖峰不被放大
    }

    // 右 Y 轴：隐藏
    const rightAxis: YAxis | null = this.model.getAxisRight();
    if (rightAxis !== null) {
      rightAxis.setEnabled(false);
    }

    // 图例：隐藏
    const legend: Legend | null = this.model.getLegend();
    if (legend !== null) {
      legend.setEnabled(false);
    }

    // 描述：隐藏
    const description: Description | null = this.model.getDescription();
    if (description !== null) {
      description.setEnabled(false);
    }

    // 交互：全部禁用（路径 A 由外层处理）
    this.model.setScaleEnabled(false);
    this.model.setDragEnabled(false);
    this.model.setPinchZoom(false);
    this.model.setDoubleTapToZoomEnabled(false);
    this.model.setHighlightPerTapEnabled(false);
    this.model.setHighlightPerDragEnabled(false);

    this.modelConfigured = true;
  }

  // ===== 数据更新 =====
  private updateData(): void {
    // 更新 X 轴 formatter 的数据
    this.timeFormatter.setData(this.timestamps, this.timeRangeHours);

    if (this.values.length === 0) {
      this.model.setData(null);
      this.model.invalidate();
      this.clearTouch();
      return;
    }

    // 构造主线 DataSet
    const entries: JArrayList<EntryOhos> = new JArrayList<EntryOhos>();
    for (let i = 0; i < this.values.length; i++) {
      entries.append(new EntryOhos(i, this.values[i]));
    }
    const dataSet: LineDataSet = new LineDataSet(entries, '');
    dataSet.setColorByColor(this.lineColorNum);
    dataSet.setLineWidth(this.lineWidthVp);
    dataSet.setDrawCircles(false);
    dataSet.setDrawValues(false);
    dataSet.setMode(Mode.LINEAR);
    dataSet.setDrawFilled(true);
    dataSet.setFillColor(this.lineColorNum);
    dataSet.setFillAlpha(30);
    dataSet.setHighlightEnabled(true);
    dataSet.setHighLightColor(this.lineColorNum);
    dataSet.setHighlightLineWidth(1);

    // 构造数据集数组（单线或双线）
    const dataSets: LineDataSet[] = [dataSet];

    // 双线模式：values2 非空时添加副线
    if (this.values2.length > 0) {
      const entries2: JArrayList<EntryOhos> = new JArrayList<EntryOhos>();
      for (let i = 0; i < this.values2.length; i++) {
        entries2.append(new EntryOhos(i, this.values2[i]));
      }
      const dataSet2: LineDataSet = new LineDataSet(entries2, '');
      dataSet2.setColorByColor(this.line2Color);
      dataSet2.setLineWidth(this.lineWidthVp);
      dataSet2.setDrawCircles(false);
      dataSet2.setDrawValues(false);
      dataSet2.setMode(Mode.LINEAR);
      dataSet2.setDrawFilled(false);  // 副线不填充，避免与主线填充重叠
      dataSet2.setHighlightEnabled(true);
      dataSet2.setHighLightColor(this.line2Color);
      dataSet2.setHighlightLineWidth(1);
      dataSets.push(dataSet2);
    }

    // 包装为 LineData
    const lineData: LineData = new LineData(dataSets);
    this.model.setData(lineData);
    this.model.invalidate();
  }

  // ===== @Prop 变化回调 =====
  private onDataChanged(): void {
    if (this.modelConfigured) {
      this.updateData();
    }
  }

  // ===== 触摸处理（路径 A 核心：PanGesture 消费横向 + onTouch 处理纵向/立即响应） =====
  // 设计：
  //   横向滑动 → PanGesture(direction=Horizontal) 消费手势，父级不滚动，连续更新 Tooltip
  //   纵向滑动 → PanGesture 不识别，onTouch Move 检测到纵向>10vp 后 clearTouch，父级 List 接管滚动
  //   按下瞬间 → onTouch Down 立即显示 Tooltip（PanGesture 需要 distance 才触发，有延迟）
  private handleTouch(event: TouchEvent): void {
    if (this.values.length === 0) {
      return;
    }
    const touch: TouchObject = event.touches[0];

    if (event.type === TouchType.Down) {
      this.startX = touch.x;
      this.startY = touch.y;
      this.scrolling = false;
      this.updateTouch(touch.x);
    } else if (event.type === TouchType.Move) {
      const dx: number = touch.x - this.startX;
      const dy: number = touch.y - this.startY;
      // 纵向位移 > 阈值 且 > 横向位移 → 用户意图为滚动页面，取消 Tooltip
      if (!this.scrolling && Math.abs(dy) > this.SCROLL_THRESHOLD_VP && Math.abs(dy) > Math.abs(dx)) {
        this.scrolling = true;
        this.clearTouch();
        return;  // 让父级 Scroll/List 接管
      }
      if (!this.scrolling) {
        this.updateTouch(touch.x);
      }
    } else if (event.type === TouchType.Up) {
      if (this.scrolling) {
        this.clearTouch();
      }
      // 非滚动状态：保持 Tooltip 显示（点击后持续显示）
    } else if (event.type === TouchType.Cancel) {
      // PanGesture 识别横向手势后会触发 Cancel，此时不清除 Tooltip（由 PanGesture 接管）
      // 只有 scrolling 状态才清除
      if (this.scrolling) {
        this.clearTouch();
      }
    }
  }

  // PanGesture 回调：横向滑动时连续更新 Tooltip
  private handlePanStart(event: GestureEvent): void {
    if (this.values.length === 0 || event.fingerList.length === 0) {
      return;
    }
    const x: number = event.fingerList[0].localX;
    this.startX = x;
    this.startY = event.fingerList[0].localY;
    this.scrolling = false;
    this.updateTouch(x);
  }

  private handlePanUpdate(event: GestureEvent): void {
    if (this.values.length === 0 || event.fingerList.length === 0 || this.scrolling) {
      return;
    }
    this.updateTouch(event.fingerList[0].localX);
  }

  private handlePanEnd(): void {
    // 横向滑动结束：保持 Tooltip 显示
  }

  private handlePanCancel(): void {
    this.clearTouch();
  }

  // 根据触摸 x 坐标计算最近数据点并更新高亮+Tooltip
  private updateTouch(touchX: number): void {
    const n: number = this.values.length;
    if (n === 0 || this.chartWvp < 1) {
      return;
    }
    // 按比例映射触摸 x 坐标到数据索引
    const ratio: number = Math.max(0, Math.min(1, touchX / this.chartWvp));
    const idx: number = Math.round(ratio * (n - 1));

    this.touchIdx = idx;
    this.touchXvp = touchX;
    this.tooltipVisible = true;

    // 手动触发 mpchart 高亮（垂直指示线）
    if (this.values2.length > 0) {
      // 双线模式：同时高亮两个数据集
      const h1: Highlight = new Highlight(idx, 0, 0, idx, 0, 0, 0, null);
      const h2: Highlight = new Highlight(idx, 0, 1, idx, 0, 0, 0, null);
      this.model.highlightValuesForArray([h1, h2]);
    } else {
      this.model.highlightValue(idx, 0, 0, idx, true);
    }
  }

  // 清除触摸状态
  private clearTouch(): void {
    this.touchIdx = -1;
    this.tooltipVisible = false;
    this.model.highlightValueForObject(null, false);
  }

  // 图表宽度（vp）
  private chartWidth(): number {
    return this.chartWvp;
  }

  // Tooltip 显示文本
  private tooltipTimeText(): string {
    if (this.touchIdx < 0 || this.touchIdx >= this.timestamps.length) {
      return '';
    }
    const d: Date = new Date(this.timestamps[this.touchIdx]);
    const hh: string = String(d.getHours()).padStart(2, '0');
    const mm: string = String(d.getMinutes()).padStart(2, '0');
    if (this.timeRangeHours <= 1) {
      return `${hh}:${mm}`;
    }
    const MM: string = String(d.getMonth() + 1).padStart(2, '0');
    const dd: string = String(d.getDate()).padStart(2, '0');
    return `${MM}-${dd} ${hh}:${mm}`;
  }

  private tooltipValueText(): string {
    if (this.touchIdx < 0 || this.touchIdx >= this.values.length) {
      return '';
    }
    const v: number = this.values[this.touchIdx];
    const formatted: string = v % 1 === 0 ? v.toFixed(0) : v.toFixed(2);
    const label: string = this.line1Label.length > 0 ? `${this.line1Label} ` : '';
    return this.unit.length > 0 ? `${label}${formatted} ${this.unit}` : `${label}${formatted}`;
  }

  // 副线数值文本（双线模式）
  private tooltipValue2Text(): string {
    if (this.touchIdx < 0 || this.touchIdx >= this.values2.length) {
      return '';
    }
    const v: number = this.values2[this.touchIdx];
    const formatted: string = v % 1 === 0 ? v.toFixed(0) : v.toFixed(2);
    const label: string = this.line2Label.length > 0 ? `${this.line2Label} ` : '';
    return this.unit.length > 0 ? `${label}${formatted} ${this.unit}` : `${label}${formatted}`;
  }

  // Tooltip 水平偏移（避边）
  private tooltipLeftOffset(): number {
    const bubbleWidth: number = 120;  // 估算气泡宽度
    const half: number = bubbleWidth / 2;
    return Math.max(4, Math.min(this.touchXvp - half, this.chartWidth() - bubbleWidth - 4));
  }

  // Tooltip 垂直偏移：固定在图表最顶部上方，不跟随手指 Y 坐标
  // 原因：数据到顶时手指在图表顶部，跟随 Y 会被 -50vp 下限卡住导致被手指遮挡；
  // 固定在顶部则气泡永远在指尖上方区域，仅横向跟随确保对应正确数据点
  private tooltipTopOffset(): number {
    // 双线模式气泡更高（三行），需要更大的负偏移
    return this.values2.length > 0 ? -52 : -36;
  }

  // ===== UI 构建 =====
  build() {
    Column() {
      if (this.values.length === 0) {
        Text(this.emptyText)
          .fontSize(12)
          .fontColor(this.textColorNum)
          .width('100%')
          .height(this.chartHeight)
          .textAlign(TextAlign.Center)
      } else {
        Stack({ alignContent: Alignment.TopStart }) {
          // mpchart 折线图（内部触摸已关闭）
          LineChart({ model: this.model })
            .width('100%')
            .height(this.chartHeight)

          // 路径 A：自定义触摸层（覆盖在 LineChart 上方）
          // onTouch 处理 Down 立即响应 + 纵向滑动检测；PanGesture 消费横向滑动
          Column()
            .width('100%')
            .height(this.chartHeight)
            .onTouch((event: TouchEvent): void => {
              this.handleTouch(event);
            })
            .gesture(
              PanGesture({ direction: PanDirection.Horizontal, distance: 1 })
                .onActionStart((event: GestureEvent): void => {
                  this.handlePanStart(event);
                })
                .onActionUpdate((event: GestureEvent): void => {
                  this.handlePanUpdate(event);
                })
                .onActionEnd((): void => {
                  this.handlePanEnd();
                })
                .onActionCancel((): void => {
                  this.handlePanCancel();
                })
            )

          // Tooltip 气泡（ArkUI 组件叠加）
          if (this.tooltipVisible && this.touchIdx >= 0) {
            Column({ space: 2 }) {
              Text(this.tooltipTimeText())
                .fontSize(10)
                .fontColor(this.tooltipTextSecondary)
              Text(this.tooltipValueText())
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.tooltipTextNum)
              if (this.values2.length > 0) {
                Text(this.tooltipValue2Text())
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.tooltipTextSecondary)
              }
            }
            .padding({ left: 8, right: 8, top: 5, bottom: 5 })
            .borderRadius(6)
            .backgroundColor(this.tooltipBgNum)
            .position({ x: this.tooltipLeftOffset(), y: this.tooltipTopOffset() })
            .transition(TransitionEffect.OPACITY)
          }
        }
        .width('100%')
        .height(this.chartHeight)
        .onAreaChange((oldArea: Area, newArea: Area): void => {
          this.chartWvp = newArea.width as number;
        })
      }
    }
    .width('100%')
  }
}
