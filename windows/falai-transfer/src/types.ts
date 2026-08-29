// 设备类型
export interface Device {
  ip: string;
  name: string;
  os: string;
  tcp_port: number;
  last_seen: number;
  manual: boolean;
}

// 传输方向
export type Direction = "Send" | "Receive";

// 传输状态
export type TransferStatus =
  | "Waiting"
  | "Transferring"
  | "Paused"
  | "Done"
  | "Failed"
  | "Canceled"
  | "Rejected";

// 传输进度
export interface TransferProgress {
  show: boolean;
  active: boolean;
  direction: Direction;
  peer_name: string;
  status: TransferStatus;
  current_file: string;
  file_index: number;
  file_count: number;
  total_bytes: number;
  transferred_bytes: number;
  speed_bps: number;
  eta_seconds: number;
  error: string | null;
}

// 待发送文件
export interface ResolvedFile {
  name: string;
  size: number;
  path: string;
}

// 传入请求
export interface IncomingRequest {
  id: number;
  from_name: string;
  from_ip: string;
  file_count: number;
  total_bytes: number;
}

// 传输日志
export interface TransferLog {
  time_millis: number;
  outgoing: boolean;
  peer_name: string;
  file_summary: string;
  size_bytes: number;
  success: boolean;
  result_text: string;
  duration_ms: number;
  avg_speed_bps: number;
}

// 应用设置
export interface AppSettings {
  device_name: string;
  save_path: string;
  whitelist: string[];
}

// 工具函数
export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

export function formatSpeed(bps: number): string {
  return `${formatBytes(bps)}/s`;
}

export function formatEta(seconds: number): string {
  if (seconds <= 0) return "即将完成";
  if (seconds < 60) return `约 ${seconds} 秒`;
  if (seconds < 3600) return `约 ${Math.floor(seconds / 60)} 分 ${seconds % 60} 秒`;
  return `约 ${Math.floor(seconds / 3600)} 小时`;
}

export function formatTime(millis: number): string {
  const d = new Date(millis);
  return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")} ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

export function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}秒`;
  return `${Math.floor(ms / 60000)}分${Math.floor((ms % 60000) / 1000)}秒`;
}