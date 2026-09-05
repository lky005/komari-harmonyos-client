/**
 * NetworkMonitor —— 网络状态监听（断连自愈）
 *
 * 用途：
 *   - 监听网络连接状态变化（Wi-Fi/蜂窝切换、进电梯断网等）
 *   - 网络恢复时通知 NodeDataStore 清空排队任务并主动对齐
 *   - 网络断开时通知 NodeDataStore 跳过轮询请求
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
