/**
 * 全局状态模型（对应安卓 transfer/TransferModels.kt 与 discovery/Device）。
 * 状态经 AppStorage 发布，UI 用 @StorageLink 订阅；更新时整体替换对象/数组触发刷新。
 */

// ---------- AppStorage key ----------
export const KEY_DEVICES: string = 'ftDevices';
export const KEY_LOCAL_IP: string = 'ftLocalIp';
export const KEY_PROGRESS: string = 'ftProgress';
export const KEY_INCOMING: string = 'ftIncoming';
export const KEY_LOGS: string = 'ftLogs';
export const KEY_WHITELIST: string = 'ftWhitelist';
export const KEY_PENDING_FILES: string = 'ftPendingFiles';

/** 初始化全部 AppStorage key（EntryAbility.onCreate 调用一次） */
export function initAppStorage(): void {
  AppStorage.setOrCreate<DeviceItem[]>(KEY_DEVICES, []);
  AppStorage.setOrCreate<string>(KEY_LOCAL_IP, '');
  AppStorage.setOrCreate<TransferProgress>(KEY_PROGRESS, new TransferProgress());
  AppStorage.setOrCreate<IncomingRequest | null>(KEY_INCOMING, null);
  AppStorage.setOrCreate<TransferLogItem[]>(KEY_LOGS, []);
  AppStorage.setOrCreate<string[]>(KEY_WHITELIST, []);
  AppStorage.setOrCreate<ResolvedFileItem[]>(KEY_PENDING_FILES, []);
}

// ---------- 设备（对应安卓 discovery/Device） ----------
export class DeviceItem {
  ip: string = '';
  name: string = '';
  os: string = '';
  tcpPort: number = 0;
  lastSeen: number = 0;
  manual: boolean = false;
}

// ---------- 传输进度（对应安卓 TransferProgress） ----------
export const DIR_SEND: string = 'SEND';
export const DIR_RECEIVE: string = 'RECEIVE';

export const STATUS_WAITING: string = 'WAITING';
export const STATUS_TRANSFERRING: string = 'TRANSFERRING';
export const STATUS_PAUSED: string = 'PAUSED';
export const STATUS_DONE: string = 'DONE';
export const STATUS_FAILED: string = 'FAILED';
export const STATUS_CANCELED: string = 'CANCELED';
export const STATUS_REJECTED: string = 'REJECTED';

export class TransferProgress {
  show: boolean = false;
  active: boolean = false;
  direction: string = DIR_SEND;
  peerName: string = '';
  status: string = STATUS_WAITING;
  currentFile: string = '';
  fileIndex: number = 0;
  fileCount: number = 0;
  totalBytes: number = 0;
  transferredBytes: number = 0;
  speedBps: number = 0;
  etaSeconds: number = 0;
  error: string = '';
}

// ---------- 接收确认请求（对应安卓 IncomingRequest） ----------
export class IncomingRequest {
  id: number = 0;
  fromName: string = '';
  fromIp: string = '';
  fileCount: number = 0;
  totalBytes: number = 0;
}

// ---------- 日志条目（字段与安卓 data/TransferLog 一致，JSON key 也一致） ----------
export class TransferLogItem {
  id: number = 0;
  timeMillis: number = 0;
  outgoing: boolean = false; // true=发送 false=接收
  peerName: string = '';
  fileSummary: string = '';
  sizeBytes: number = 0;
  success: boolean = false;
  resultText: string = ''; // 成功 / 已取消 / 对方拒绝 / 失败原因
  durationMs: number = 0;
  avgSpeedBps: number = 0;
  contentUri: string = ''; // 单文件接收成功的落点 uri，用于点击预览
}

// ---------- 待发送文件（对应安卓 transfer/ResolvedFile） ----------
export class ResolvedFileItem {
  name: string = '';
  size: number = 0;
  uri: string = ''; // picker 返回的 file:// uri（uri 与 tempPath 二选一）
  tempPath: string = ''; // 大小未知时先复制到缓存的沙箱路径
}
