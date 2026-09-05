/**
 * ConcurrencyLimiter —— 并发请求限流器（支持取消与动态调整）
 *
 * 用途：NodesPage 对多节点并行拉取 getClientRecentRecords 时，
 * 限制同时进行的请求数，避免弱网下请求堆积、基带发热、服务端过载。
 *
 * 关键特性：
 *   - 排队项带取消标志，clearQueue() 时废弃任务直接退出，不发请求
 *   - dispatchNext() 跳过已取消项，不会唤醒无效任务
 *   - setMaxConcurrent() 运行时动态调整并发上限
 *
 * 用法：
 *   const limiter = new ConcurrencyLimiter(3);
 *   const result = await limiter.run(() => api.getClientRecentRecords(uuid));
 *   // result 可能为 undefined（任务被取消时）
 */

interface QueueItem {
  resolve: () => void;
  cancelled: boolean;
}

export class ConcurrencyLimiter {
  private running: number = 0;
  private maxConcurrent: number;
  private queue: QueueItem[] = [];

  constructor(maxConcurrent: number = 3) {
    this.maxConcurrent = Math.max(1, maxConcurrent);
  }

  /**
   * 提交一个异步任务，受并发上限约束。
   * 返回 undefined 表示任务被 clearQueue() 取消，未实际执行。
   */
  async run<T>(fn: () => Promise<T>): Promise<T | undefined> {
    // 排队阶段
    if (this.running >= this.maxConcurrent) {
      const item: QueueItem = { resolve: (): void => {}, cancelled: false };
      this.queue.push(item);
      await new Promise<void>((resolve): void => {
        item.resolve = resolve;
      });
      // 被 clearQueue 唤醒后检查取消标志
      if (item.cancelled) {
        return undefined;
      }
    }

    // 执行阶段
    this.running++;
    try {
      return await fn();
    } finally {
      this.running--;
      this.dispatchNext();
    }
  }

  /** 正常完成一个任务后，调度下一个未取消的排队项 */
  private dispatchNext(): void {
    while (this.queue.length > 0) {
      const next = this.queue.shift()!;
      if (!next.cancelled) {
        next.resolve();
        return;
      }
      // 已取消的项跳过，继续找下一个
    }
  }

  /**
   * 断网自愈时调用：标记所有排队项取消并唤醒。
   * 废弃任务被唤醒后检查 cancelled=true，直接 return undefined，绝不发请求。
   * 正在执行中的任务不受影响（会自然完成）。
   */
  clearQueue(): void {
    this.queue.forEach((item: QueueItem): void => {
      item.cancelled = true;
      item.resolve();
    });
    this.queue = [];
  }

  /** 运行时动态调整并发上限（设置页修改后调用） */
  setMaxConcurrent(n: number): void {
    this.maxConcurrent = Math.max(1, n);
    // 如果提高了并发上限，立即调度排队任务
    while (this.running < this.maxConcurrent && this.queue.length > 0) {
      const next = this.queue.shift()!;
      if (!next.cancelled) {
        next.resolve();
        this.running++;
      }
    }
  }

  get pendingCount(): number {
    return this.queue.filter((item: QueueItem): boolean => !item.cancelled).length;
  }

  get runningCount(): number {
    return this.running;
  }
}
