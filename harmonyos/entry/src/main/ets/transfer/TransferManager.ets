import { socket, connection } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AppEnv } from '../core/AppEnv';
import { encodeText } from '../core/Protocol';
import { summarizeFiles } from '../core/Format';
import {
  DIR_RECEIVE, DIR_SEND, IncomingRequest, KEY_INCOMING, KEY_PROGRESS, KEY_WHITELIST,
  ResolvedFileItem, STATUS_CANCELED, STATUS_DONE, STATUS_FAILED, STATUS_PAUSED,
  STATUS_REJECTED, STATUS_TRANSFERRING, STATUS_WAITING, TransferLogItem, TransferProgress
} from './TransferModels';
import { sendFilesTo, RejectedError } from './TransferClient';
import { TransferServer, ServerEvents } from './TransferServer';
import { deleteTempFiles } from './FileIO';
import { discoveryService } from '../discovery/DiscoveryService';
import { logRepository } from '../data/LogRepository';
import { fileIo as fs } from '@kit.CoreFileKit';

/**
 * 传输编排（对应安卓 transfer/TransferManager.kt）：
 * 常驻服务端（端口自动后移）、客户端发送、暂停/继续、取消即断连、
 * 网络断开容错、白名单免确认、传输日志。状态经 AppStorage 发布。
 */
export class TransferManager {
  private prefs: preferences.Preferences | null = null;
  private server: TransferServer;
  private progress: TransferProgress = new TransferProgress();
  private whitelist: Set<string> = new Set();

  private active: boolean = false;
  private canceled: boolean = false;
  private paused: boolean = false;
  private cancelReason: string = '';
  private clientTcp: socket.TCPSocket | null = null;
  private pendingResolver: ((accept: boolean) => void) | null = null;
  private pendingRequest: IncomingRequest | null = null;
  private transferStartTime: number = 0;
  private speedTimer: number = -1;
  private lastProgressPush: number = 0;
  private netConnection: connection.NetConnection | null = null;

  constructor() {
    const events: ServerEvents = {
      decide: (request: IncomingRequest) => this.decideIncoming(request),
      onReceiveBegin: (peerName: string, fileCount: number, totalBytes: number, resumedBytes: number) => {
        this.begin(DIR_RECEIVE, peerName, fileCount, totalBytes);
        if (resumedBytes > 0) {
          this.progress.transferredBytes = resumedBytes;
          this.publishProgress();
        }
      },
      onProgress: (fileName: string, fileIndex: number, fileCount: number, transferredBytes: number) => {
        this.pushProgress(fileName, fileIndex, fileCount, transferredBytes);
      },
      onFinished: (peerName: string, fileNames: string[], totalBytes: number, success: boolean,
        error: string, needLog: boolean, savedUri: string) => {
        this.onServerFinished(peerName, fileNames, totalBytes, success, error, needLog, savedUri);
      },
      isBusy: () => this.active,
      isCanceled: () => this.canceled
    };
    this.server = new TransferServer(events);
  }

  init(context: common.Context): void {
    this.prefs = preferences.getPreferencesSync(context, { name: 'falai' });
  }

  start(): void {
    // 白名单
    try {
      const raw = this.prefs != null ? this.prefs.getSync('whitelist', '[]') as string : '[]';
      const arr = JSON.parse(raw) as string[];
      this.whitelist = new Set(arr);
    } catch (e) {
      this.whitelist = new Set();
    }
    AppStorage.setOrCreate<string[]>(KEY_WHITELIST, Array.from(this.whitelist));
    // 常驻 TCP 服务（端口 47801 起自动后移）
    this.server.start().then((ok: boolean) => {
      if (!ok) {
        console.error('[falai] TCP 服务启动失败：47801~47811 均被占用');
      }
    });
    this.cleanupStaleIncoming();
    this.watchNetwork();
  }

  stop(): void {
    this.server.stop();
    this.stopSpeedJob();
  }

  /** 服务端实际绑定端口（广播时携带） */
  get serverPort(): number {
    return this.server.boundPort;
  }

  get deviceName(): string {
    const saved = this.prefs != null ? this.prefs.getSync('deviceName', '') as string : '';
    return saved.length > 0 ? saved : AppEnv.defaultDeviceName();
  }

  set deviceName(v: string) {
    if (this.prefs != null) {
      this.prefs.putSync('deviceName', v);
      this.prefs.flush();
    }
  }

  // ---------- 发送 ----------

  sendFiles(ip: string, port: number, peerName: string, files: ResolvedFileItem[]): void {
    if (this.active || files.length === 0) {
      return;
    }
    const total = files.reduce((s: number, f: ResolvedFileItem) => s + f.size, 0);
    // 同一批文件（同名同大小）发给同一设备 → 相同 transferId → 自动断点续传
    const transferId = this.deriveTransferId(ip, files);
    this.begin(DIR_SEND, peerName, files.length, total);
    (async () => {
      try {
        await sendFilesTo(ip, port, transferId, this.deviceName, files, {
          isCanceled: () => this.canceled,
          isPaused: () => this.paused,
          onWaitingAccept: () => {
            this.progress.status = STATUS_WAITING;
            this.publishProgress();
          },
          onProgress: (name: string, idx: number, transferred: number) => {
            this.pushProgress(name, idx, files.length, transferred);
          },
          onSocket: (tcp: socket.TCPSocket | null) => {
            this.clientTcp = tcp;
          }
        });
        this.finish(true, '', false);
        logRepository.add(this.makeLog(true, peerName, files.map((f: ResolvedFileItem) => f.name), total, true, '成功', ''));
      } catch (e) {
        if (e instanceof RejectedError) {
          this.finish(false, '', true);
          logRepository.add(this.makeLog(true, peerName, files.map((f: ResolvedFileItem) => f.name), total, false, '对方拒绝', ''));
        } else {
          const err = e as Error;
          const result = this.cancelReason.length > 0 ? this.cancelReason
            : (this.canceled ? '已取消' : `失败: ${err.message != null && err.message.length > 0 ? err.message : '未知错误'}`);
          this.finish(false, err.message != null ? err.message : '', false);
          logRepository.add(this.makeLog(true, peerName, files.map((f: ResolvedFileItem) => f.name), total, false, result, ''));
        }
      } finally {
        deleteTempFiles(files);
      }
    })();
  }

  /** 与安卓 TransferManager.deriveTransferId 逐字节一致："t" + md5(ip + name:size|...) 前16位hex */
  private deriveTransferId(ip: string, files: ResolvedFileItem[]): string {
    const raw = ip + files.map((f: ResolvedFileItem) => `${f.name}:${f.size}`).join('|');
    const md = cryptoFramework.createMd('MD5');
    md.updateSync({ data: encodeText(raw) });
    const digest = md.digestSync();
    let hex = '';
    digest.data.forEach((b: number) => {
      hex += b.toString(16).padStart(2, '0');
    });
    return `t${hex.substring(0, 16)}`;
  }

  // ---------- 接收确认 ----------

  private decideIncoming(request: IncomingRequest): Promise<boolean> {
    if (this.whitelist.has(request.fromIp)) {
      return Promise.resolve(true); // 白名单设备免确认（方案.md §4.2）
    }
    this.pendingRequest = request;
    AppStorage.setOrCreate<IncomingRequest | null>(KEY_INCOMING, request);
    return new Promise<boolean>((resolve) => {
      this.pendingResolver = resolve;
    });
  }

  /** 弹窗「接受/拒绝」回调；trust=true 时把对方 IP 加入白名单 */
  respondIncoming(accept: boolean, trust: boolean): void {
    const req = this.pendingRequest;
    if (trust && req != null) {
      this.addToWhitelist(req.fromIp);
    }
    AppStorage.setOrCreate<IncomingRequest | null>(KEY_INCOMING, null);
    const responder = this.pendingResolver;
    this.pendingResolver = null;
    this.pendingRequest = null;
    if (!accept && req != null) {
      const log = new TransferLogItem();
      log.id = logRepository.newId();
      log.timeMillis = Date.now();
      log.outgoing = false;
      log.peerName = req.fromName;
      log.fileSummary = `${req.fileCount} 个文件`;
      log.sizeBytes = req.totalBytes;
      log.success = false;
      log.resultText = '已拒绝';
      log.durationMs = 0;
      log.avgSpeedBps = 0;
      logRepository.add(log);
    }
    if (responder != null) {
      responder(accept);
    }
  }

  // ---------- 暂停 / 继续 / 取消 ----------

  pauseTransfer(): void {
    if (!this.active || this.progress.direction !== DIR_SEND) {
      return;
    }
    this.paused = true;
    this.progress.status = STATUS_PAUSED;
    this.progress.speedBps = 0;
    this.progress.etaSeconds = 0;
    this.publishProgress();
  }

  resumeTransfer(): void {
    if (!this.paused) {
      return;
    }
    this.paused = false;
    this.progress.status = STATUS_TRANSFERRING;
    this.publishProgress();
  }

  cancelTransfer(reason: string = ''): void {
    this.cancelReason = reason;
    this.canceled = true;
    this.paused = false;
    if (this.clientTcp != null) {
      this.clientTcp.close().catch(() => {
        // ignore
      });
    }
    this.server.cancelSessions();
  }

  dismissProgress(): void {
    if (!this.progress.active) {
      this.progress = new TransferProgress();
      this.publishProgress();
    }
  }

  // ---------- 白名单 ----------

  addToWhitelist(ip: string): void {
    if (ip.length === 0) {
      return;
    }
    this.whitelist.add(ip);
    this.persistWhitelist();
  }

  removeFromWhitelist(ip: string): void {
    this.whitelist.delete(ip);
    this.persistWhitelist();
  }

  private persistWhitelist(): void {
    const arr = Array.from(this.whitelist);
    if (this.prefs != null) {
      this.prefs.putSync('whitelist', JSON.stringify(arr));
      this.prefs.flush();
    }
    AppStorage.setOrCreate<string[]>(KEY_WHITELIST, arr);
  }

  // ---------- 内部 ----------

  private begin(direction: string, peer: string, fileCount: number, total: number): void {
    this.active = true;
    this.canceled = false;
    this.paused = false;
    this.cancelReason = '';
    this.transferStartTime = Date.now();
    const p = new TransferProgress();
    p.show = true;
    p.active = true;
    p.direction = direction;
    p.peerName = peer;
    p.status = STATUS_TRANSFERRING;
    p.fileCount = fileCount;
    p.totalBytes = total;
    this.progress = p;
    this.publishProgress();
    this.startSpeedJob();
  }

  private finish(success: boolean, error: string, rejected: boolean): void {
    this.stopSpeedJob();
    this.active = false;
    this.paused = false;
    if (success) {
      this.progress.status = STATUS_DONE;
    } else if (rejected) {
      this.progress.status = STATUS_REJECTED;
    } else if (this.canceled && this.cancelReason.length === 0) {
      this.progress.status = STATUS_CANCELED;
    } else {
      this.progress.status = STATUS_FAILED;
    }
    this.progress.active = false;
    this.progress.error = error;
    this.progress.speedBps = 0;
    this.progress.etaSeconds = 0;
    this.publishProgress();
  }

  private onServerFinished(peerName: string, fileNames: string[], totalBytes: number,
    success: boolean, error: string, needLog: boolean, savedUri: string): void {
    if (!needLog) {
      return;
    }
    let result: string;
    if (success) {
      result = '成功';
    } else if (this.cancelReason.length > 0) {
      result = this.cancelReason;
    } else if (this.canceled) {
      result = '已取消';
    } else {
      result = `失败: ${error.length > 0 ? error : '未知错误'}`;
    }
    this.finish(success, error, false);
    logRepository.add(this.makeLog(false, peerName, fileNames, totalBytes, success, result, savedUri));
  }

  private pushProgress(name: string, idx: number, count: number, transferred: number): void {
    // 100ms 节流，避免每 32KB 触发一次 UI 刷新
    const now = Date.now();
    if (now - this.lastProgressPush < 100 && transferred < this.progress.totalBytes) {
      return;
    }
    this.lastProgressPush = now;
    this.progress.currentFile = name;
    this.progress.fileIndex = idx + 1;
    this.progress.fileCount = count;
    this.progress.transferredBytes = transferred;
    this.progress.status = this.paused ? STATUS_PAUSED : STATUS_TRANSFERRING;
    this.publishProgress();
  }

  private startSpeedJob(): void {
    this.stopSpeedJob();
    let lastBytes = 0;
    let lastTime = Date.now();
    this.speedTimer = setInterval(() => {
      const p = this.progress;
      const now = Date.now();
      const dt = (now - lastTime) / 1000;
      if (dt > 0 && !this.paused) {
        const speed = (p.transferredBytes - lastBytes) / dt;
        const eta = speed > 1 ? Math.floor((p.totalBytes - p.transferredBytes) / speed) : 0;
        p.speedBps = Math.max(speed, 0);
        p.etaSeconds = Math.max(eta, 0);
        this.publishProgress();
      }
      lastBytes = p.transferredBytes;
      lastTime = now;
    }, 500);
  }

  private stopSpeedJob(): void {
    if (this.speedTimer >= 0) {
      clearInterval(this.speedTimer);
      this.speedTimer = -1;
    }
  }

  private makeLog(outgoing: boolean, peer: string, files: string[], total: number,
    success: boolean, result: string, contentUri: string): TransferLogItem {
    const duration = Date.now() - this.transferStartTime;
    const log = new TransferLogItem();
    log.id = logRepository.newId();
    log.timeMillis = Date.now();
    log.outgoing = outgoing;
    log.peerName = peer;
    log.fileSummary = summarizeFiles(files);
    log.sizeBytes = total;
    log.success = success;
    log.resultText = result;
    log.durationMs = duration;
    log.avgSpeedBps = duration > 0 && success ? total / (duration / 1000) : 0;
    log.contentUri = contentUri;
    return log;
  }

  /** 临时文件超过 24 小时自动清理（方案.md §4.2） */
  private cleanupStaleIncoming(): void {
    try {
      const dir = AppEnv.incomingDir();
      if (!fs.accessSync(dir)) {
        return;
      }
      const cutoff = Date.now() - 24 * 3600 * 1000;
      const names = fs.listFileSync(dir);
      names.forEach((n: string) => {
        try {
          const path = `${dir}/${n}`;
          const stat = fs.statSync(path);
          if (stat.mtime * 1000 < cutoff) {
            fs.unlinkSync(path);
          }
        } catch (e) {
          // ignore
        }
      });
    } catch (e) {
      // ignore
    }
  }

  /** WiFi 断开/切换时立即终止进行中的传输（方案.md §4.2 容错），临时文件保留可续传 */
  private watchNetwork(): void {
    if (this.netConnection != null) {
      return;
    }
    try {
      const nc = connection.createNetConnection();
      nc.register((err) => {
        if (err != null) {
          console.error(`[falai] 网络监听注册失败: ${JSON.stringify(err)}`);
        }
      });
      nc.on('netLost', () => {
        if (this.active) {
          this.cancelTransfer('网络已断开或切换');
        }
        discoveryService.onNetworkLost();
      });
      nc.on('netAvailable', () => {
        discoveryService.onNetworkAvailable();
      });
      this.netConnection = nc;
    } catch (e) {
      console.error(`[falai] 网络监听失败: ${JSON.stringify(e)}`);
    }
  }

  /** 进度对象整体替换发布（@StorageLink 只观测引用变化），逐字段拷贝避免依赖 Object.assign */
  private publishProgress(): void {
    const copy = new TransferProgress();
    copy.show = this.progress.show;
    copy.active = this.progress.active;
    copy.direction = this.progress.direction;
    copy.peerName = this.progress.peerName;
    copy.status = this.progress.status;
    copy.currentFile = this.progress.currentFile;
    copy.fileIndex = this.progress.fileIndex;
    copy.fileCount = this.progress.fileCount;
    copy.totalBytes = this.progress.totalBytes;
    copy.transferredBytes = this.progress.transferredBytes;
    copy.speedBps = this.progress.speedBps;
    copy.etaSeconds = this.progress.etaSeconds;
    copy.error = this.progress.error;
    AppStorage.setOrCreate<TransferProgress>(KEY_PROGRESS, copy);
  }
}

export const transferManager: TransferManager = new TransferManager();
