import { fileIo as fs } from '@kit.CoreFileKit';
import { AppEnv } from '../core/AppEnv';
import { TransferLogItem, KEY_LOGS } from '../transfer/TransferModels';

/** 日志持久化 JSON 的字段（与安卓 TransferLog.toJson/fromJson 的 key 完全一致） */
interface LogJson {
  id: number;
  time: number;
  outgoing: boolean;
  peer: string;
  files: string;
  size: number;
  success: boolean;
  result: string;
  duration: number;
  avgSpeed: number;
  uri: string;
}

function toJson(log: TransferLogItem): LogJson {
  return {
    id: log.id,
    time: log.timeMillis,
    outgoing: log.outgoing,
    peer: log.peerName,
    files: log.fileSummary,
    size: log.sizeBytes,
    success: log.success,
    result: log.resultText,
    duration: log.durationMs,
    avgSpeed: log.avgSpeedBps,
    uri: log.contentUri
  };
}

function fromJson(j: LogJson): TransferLogItem {
  const log = new TransferLogItem();
  log.id = j.id;
  log.timeMillis = j.time;
  log.outgoing = j.outgoing;
  log.peerName = j.peer;
  log.fileSummary = j.files;
  log.sizeBytes = j.size;
  log.success = j.success;
  log.resultText = j.result;
  log.durationMs = j.duration;
  log.avgSpeedBps = j.avgSpeed;
  log.contentUri = j.uri != null ? j.uri : '';
  return log;
}

/**
 * 传输日志（对应安卓 data/LogRepository.kt）：
 * JSON 文件持久化（filesDir/logs.json），新记录插到最前，最多保留 500 条，
 * 支持单条删除与一键清空；内存列表经 AppStorage 发布给 UI。
 */
export class LogRepository {
  private logs: TransferLogItem[] = [];
  private loaded: boolean = false;

  private filePath(): string {
    return `${AppEnv.filesDir()}/logs.json`;
  }

  /** 启动时加载（EntryAbility.onCreate 调用，异步不阻塞） */
  async init(): Promise<void> {
    try {
      const text = await fs.readText(this.filePath());
      const arr = JSON.parse(text) as LogJson[];
      this.logs = arr.map((j: LogJson) => fromJson(j));
    } catch (e) {
      this.logs = [];
    }
    this.loaded = true;
    this.publish();
  }

  add(log: TransferLogItem): void {
    this.logs.unshift(log);
    this.persist();
    this.publish();
  }

  delete(id: number): void {
    this.logs = this.logs.filter((l: TransferLogItem) => l.id !== id);
    this.persist();
    this.publish();
  }

  clear(): void {
    this.logs = [];
    this.persist();
    this.publish();
  }

  newId(): number {
    return Date.now() + Math.floor(Math.random() * 1000);
  }

  private publish(): void {
    // 整体替换引用，触发 @StorageLink 刷新
    AppStorage.setOrCreate<TransferLogItem[]>(KEY_LOGS, this.logs.slice(0));
  }

  private persist(): void {
    if (!this.loaded) {
      return; // 未加载完成前不写盘，避免用空列表覆盖磁盘数据
    }
    try {
      const arr = this.logs.slice(0, 500).map((l: TransferLogItem) => toJson(l));
      const file = fs.openSync(this.filePath(), fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(arr));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      console.error(`[falai] 日志写盘失败: ${JSON.stringify(e)}`);
    }
  }
}

export const logRepository: LogRepository = new LogRepository();
