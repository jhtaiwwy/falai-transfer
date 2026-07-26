/** 格式化工具，与安卓版 core/Format.kt 输出保持一致 */

export function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

export function formatSpeed(bps: number): string {
  return `${formatBytes(Math.floor(bps))}/s`;
}

export function formatEta(seconds: number): string {
  if (seconds <= 0) {
    return '即将完成';
  }
  if (seconds < 60) {
    return `约 ${seconds} 秒`;
  }
  if (seconds < 3600) {
    return `约 ${Math.floor(seconds / 60)} 分 ${seconds % 60} 秒`;
  }
  return `约 ${Math.floor(seconds / 3600)} 小时`;
}

export function formatDuration(ms: number): string {
  if (ms < 1000) {
    return `${ms}ms`;
  }
  if (ms < 60000) {
    return `${(ms / 1000).toFixed(1)}秒`;
  }
  return `${Math.floor(ms / 60000)}分${Math.floor((ms % 60000) / 1000)}秒`;
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/** 对应安卓 SimpleDateFormat("MM-dd HH:mm:ss") */
export function formatTime(millis: number): string {
  const d = new Date(millis);
  return `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

/** 日志里的文件摘要：单文件用原名，多文件「xxx 等N个文件」 */
export function summarizeFiles(names: string[]): string {
  if (names.length === 0) {
    return '-';
  }
  if (names.length === 1) {
    return names[0];
  }
  return `${names[0]} 等${names.length}个文件`;
}

/** 取路径最后一段作为文件名（等价安卓 File(name).name 的 basename 语义） */
export function baseName(path: string): string {
  const idx1 = path.lastIndexOf('/');
  const idx2 = path.lastIndexOf('\\');
  const idx = Math.max(idx1, idx2);
  return idx >= 0 ? path.substring(idx + 1) : path;
}

export function extLower(name: string): string {
  const idx = name.lastIndexOf('.');
  return idx >= 0 ? name.substring(idx + 1).toLowerCase() : '';
}

const IMAGE_EXTS: string[] = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif'];
const VIDEO_EXTS: string[] = ['mp4', 'mov', 'mkv', 'avi', '3gp', 'webm'];

export function isImageFile(name: string): boolean {
  return IMAGE_EXTS.indexOf(extLower(name)) >= 0;
}

export function isVideoFile(name: string): boolean {
  return VIDEO_EXTS.indexOf(extLower(name)) >= 0;
}

/** 是否图片/视频（接收后导入相册，对应安卓 FileSaver 的 mime 判断） */
export function isVisualMedia(name: string): boolean {
  return isImageFile(name) || isVideoFile(name);
}
