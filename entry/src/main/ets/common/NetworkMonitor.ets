/**
 * NetworkMonitor —— 网络状态监听（断连自愈）
 *
 * 用途：
 *   - 监听网络连接状态变化（Wi-Fi/蜂窝切换、进电梯断网等）
 *   - 网络恢复时通知 NodeDataStore 清空排队任务并主动对齐
 *   - 网络断开时通知 NodeDataStore 跳过轮询请求
 *
 * 事件覆盖：netAvailable / netLost / netUnavailable。
 * netUnavailable 用于「有网络接口但上不了网」的假联网场景，netLost 覆盖不到。
 * 注意本监听仍不保证 100% 准确（如部分系统版本不支持 netUnavailable），
 * 因此 NodeDataStore 的连接状态同时参考「最近一次请求的实际结果」，
 * 不把本 flag 当作唯一判据。
 *
 * 需要权限：ohos.permission.GET_NETWORK_INFO（normal 级别，安装时自动授予）
 *
 * 用法：
 *   EntryAbility.onCreate 中调用 NetworkMonitor.getInstance().start();
 */

import connection from '@ohos.net.connection';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NodeDataStore } from './NodeDataStore';

const DOMAIN: number = 0x0001;

export class NetworkMonitor {
  private static instance: NetworkMonitor | undefined = undefined;
  private started: boolean = false;
  private netConn: connection.NetConnection | undefined = undefined;

  private registerCallback: (err: Error) => void = (err: Error): void => {
    if (err) {
      hilog.error(DOMAIN, 'NetworkMonitor', 'register failed: %{public}s', err.message);
    }
  };

  static getInstance(): NetworkMonitor {
    if (!NetworkMonitor.instance) {
      NetworkMonitor.instance = new NetworkMonitor();
    }
    return NetworkMonitor.instance;
  }

  /** 启动网络监听（EntryAbility.onCreate 调用，幂等） */
  start(): void {
    if (this.started) {
      return;
    }
    try {
      this.netConn = connection.createNetConnection();
      this.netConn.on('netAvailable', (): void => {
        hilog.info(DOMAIN, 'NetworkMonitor', 'network available');
        NodeDataStore.getInstance().onNetworkRestore();
      });
      this.netConn.on('netLost', (): void => {
        hilog.info(DOMAIN, 'NetworkMonitor', 'network lost');
        NodeDataStore.getInstance().onNetworkLost();
      });
      // netUnavailable：有网络接口但不可用（典型场景：连上 Wi-Fi 却无法上网）。
      // netLost 只在接口消失时触发，覆盖不到这种"假联网"。
      // 单独 try 包住 —— 个别系统版本若不支持该事件，不能连带影响后面的 register。
      try {
        this.netConn.on('netUnavailable', (): void => {
          hilog.info(DOMAIN, 'NetworkMonitor', 'network unavailable');
          NodeDataStore.getInstance().onNetworkLost();
        });
      } catch (e) {
        hilog.warn(DOMAIN, 'NetworkMonitor', 'netUnavailable unsupported: %{public}s', JSON.stringify(e));
      }
      this.netConn.register(this.registerCallback);
      this.started = true;
      hilog.info(DOMAIN, 'NetworkMonitor', 'started');
    } catch (e) {
      hilog.error(DOMAIN, 'NetworkMonitor', 'start failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 停止网络监听（一般不需要调用，应用生命周期内常驻） */
  stop(): void {
    if (!this.started || !this.netConn) {
      return;
    }
    try {
      this.netConn.unregister(this.registerCallback);
    } catch (e) {
      // 忽略
    }
    this.netConn = undefined;
    this.started = false;
  }
}
