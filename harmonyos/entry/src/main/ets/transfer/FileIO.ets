import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { common } from '@kit.AbilityKit';
import { AppEnv } from '../core/AppEnv';
import { baseName, isVisualMedia, isImageFile, isVideoFile, extLower } from '../core/Format';
import { ResolvedFileItem } from './TransferModels';
import { Protocol } from '../core/Protocol';

/**
 * 文件模块（对应安卓 transfer/FileIO.kt 的 FileResolver 与 FileSaver）：
 * - 选照片/视频：PhotoViewPicker 多选（免权限，临时授权读 uri）
 * - 选文件：DocumentViewPicker 多选
 * - 大小未知时先复制到缓存再取准确字节数（协议要求精确大小，方案.md §4.2）
 * - 接收落点：图片/视频导入相册（createAsset 需要 WRITE_IMAGEVIDEO，启动时已运行时申请），
 *   其他文件写入公共「下载」目录 Download/<包名>/（DocumentViewPicker DOWNLOAD 模式直达，不弹界面）
 */

// ---------- 选择器 ----------

/** 选照片/视频，多选（500 为系统选择器允许的最大值，即不设应用层限制） */
export async function pickMediaFiles(context: common.Context): Promise<ResolvedFileItem[]> {
  const photoPicker = new photoAccessHelper.PhotoViewPicker();
  const options = new photoAccessHelper.PhotoSelectOptions();
  options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
  options.maxSelectNumber = 500;
  const result = await photoPicker.select(options);
  return resolvePickedUris(result.photoUris);
}

/** 选任意文件，多选（500 为系统选择器允许的最大值，即不设应用层限制） */
export async function pickDocumentFiles(context: common.Context): Promise<ResolvedFileItem[]> {
  const docPicker = new picker.DocumentViewPicker(context);
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = 500;
  const uris = await docPicker.select(options);
  return resolvePickedUris(uris);
}

// ---------- 解析（名称 + 准确大小） ----------

export async function resolvePickedUris(uris: string[]): Promise<ResolvedFileItem[]> {
  const out: ResolvedFileItem[] = [];
  for (const uri of uris) {
    const item = await resolveOne(uri);
    if (item != null) {
      out.push(item);
    }
  }
  return out;
}

async function resolveOne(uri: string): Promise<ResolvedFileItem | null> {
  try {
    let name = '';
    try {
      name = decodeURIComponent(baseName(uri));
    } catch (e) {
      name = baseName(uri);
    }
    if (name.length === 0) {
      name = `file_${Date.now()}`;
    }
    // 先尝试直接 stat 拿大小
    const size = trySize(uri);
    if (size >= 0) {
      const item = new ResolvedFileItem();
      item.name = name;
      item.size = size;
      item.uri = uri;
      return item;
    }
    // 大小未知：复制到缓存再取准确字节数（对应安卓 FileResolver 的 tempFile 兜底）
    const tmpPath = `${AppEnv.cacheDir()}/send_${Date.now()}_${name}`;
    copyUriToPath(uri, tmpPath);
    const stat = fs.statSync(tmpPath);
    const item = new ResolvedFileItem();
    item.name = name;
    item.size = stat.size;
    item.tempPath = tmpPath;
    return item;
  } catch (e) {
    console.error(`[falai] 解析文件失败 ${uri}: ${JSON.stringify(e)}`);
    return null;
  }
}

function trySize(uri: string): number {
  let file: fs.File | null = null;
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const stat = fs.statSync(file.fd);
    return stat.size;
  } catch (e) {
    return -1;
  } finally {
    if (file != null) {
      try {
        fs.closeSync(file);
      } catch (e) {
        // ignore
      }
    }
  }
}

/** 打开待发送文件：优先临时缓存路径，否则用 picker uri（对应安卓 FileResolver.open） */
export function openResolved(item: ResolvedFileItem): fs.File {
  if (item.tempPath.length > 0) {
    return fs.openSync(item.tempPath, fs.OpenMode.READ_ONLY);
  }
  return fs.openSync(item.uri, fs.OpenMode.READ_ONLY);
}

function copyUriToPath(uri: string, destPath: string): void {
  const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
  const dst = fs.openSync(destPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    copyFd(src.fd, dst.fd);
  } finally {
    fs.closeSync(src);
    fs.closeSync(dst);
  }
}

/**
 * 32KB 块流式复制，内存占用恒定（方案.md §4.2 流式读写）。
 * 注意：readSync/writeSync 的 options.offset 是「文件位置」而非 buffer 内偏移，
 * 且定位读写不移动 filePointer（曾误当 buffer 偏移导致每个 32KB 块都覆盖写回文件开头，
 * 超过 32KB 的图片导入相册后损坏打不开）。这里用顺序读写，靠 filePointer 自动推进。
 */
export function copyFd(srcFd: number, dstFd: number): void {
  const buf = new ArrayBuffer(Protocol.BUFFER_SIZE);
  while (true) {
    const n = fs.readSync(srcFd, buf);
    if (n <= 0) {
      break;
    }
    let written = 0;
    while (written < n) {
      // writeSync 无 buffer 偏移参数，部分写时用 slice 切出剩余段
      written += fs.writeSync(dstFd, buf.slice(written, n));
    }
  }
}

// ---------- 接收保存 ----------

export class ImportResult {
  locationDesc: string = '';
  contentUri: string = ''; // 相册 uri（用于日志点击预览）；私有目录保存时为空串
}

/**
 * 接收文件落点（对应安卓 FileSaver.import）：
 * 图片/视频 → 系统相册（photoAccessHelper.createAsset，需 WRITE_IMAGEVIDEO，启动时已运行时申请）；
 * 其他文件 → 公共「下载」目录 Download/<包名>/，系统「文件管理」App 可直接看到。
 * 实现：DocumentViewPicker.save 的 DOWNLOAD 模式不拉起选择界面，直接返回
 * Download/<包名>/ 的目录 uri（形如 file://docs/storage/Users/currentUser/Download/<包名>），
 * 用 fileUri.FileUri 转成真实路径后在该目录下建文件，无需任何权限声明；
 * 失败时回退应用私有目录 filesDir/Download/。
 */
export async function importReceivedFile(partPath: string, rawName: string): Promise<ImportResult> {
  let name = baseName(rawName);
  if (name.length === 0) {
    name = `file_${Date.now()}`;
  }
  const result = new ImportResult();
  if (isVisualMedia(name)) {
    // 相册：createAsset(photoType, extension) 按扩展名推断类型，返回可写 uri
    const helper = photoAccessHelper.getPhotoAccessHelper(AppEnv.context());
    const extension = extLower(name);
    const photoType = isImageFile(name) ? photoAccessHelper.PhotoType.IMAGE : photoAccessHelper.PhotoType.VIDEO;
    const uri = await helper.createAsset(photoType, extension);
    const src = fs.openSync(partPath, fs.OpenMode.READ_ONLY);
    const dst = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    try {
      copyFd(src.fd, dst.fd);
    } finally {
      fs.closeSync(src);
      fs.closeSync(dst);
    }
    result.locationDesc = '相册';
    result.contentUri = uri;
    return result;
  }
  // 其他文件：公共「下载」目录 Download/<包名>/（重名自动加 _1 _2 后缀）
  try {
    const dirUri = await publicDownloadDirUri();
    // 关键：fs.openSync 不能直接用 uri + CREATE（真机报 13900002），
    // 必须按官方文档用 fileUri.FileUri 把 uri 转成真实路径后再 open
    const dirPath = new fileUri.FileUri(dirUri).path;
    const targetPath = uniquePath(dirPath, name);
    const src = fs.openSync(partPath, fs.OpenMode.READ_ONLY);
    const dst = fs.openSync(targetPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    try {
      copyFd(src.fd, dst.fd);
    } finally {
      fs.closeSync(src);
      fs.closeSync(dst);
    }
    result.locationDesc = '系统「文件管理」> 下载';
    return result;
  } catch (e) {
    const err = e as Error;
    console.error(`[falai] 写入公共下载目录失败，回退私有目录: ${JSON.stringify(e)} msg=${err.message}`);
  }
  // 回退：应用私有目录 filesDir/Download/（系统文件管理不可见，仅 hdc 可访问）
  const dir = `${AppEnv.filesDir()}/Download`;
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir, true);
  }
  const target = uniquePath(dir, name);
  fs.copyFileSync(partPath, target);
  result.locationDesc = '应用私有目录/Download';
  result.contentUri = '';
  return result;
}

/**
 * 公共下载目录 Download/<包名>/ 的目录 uri。
 * DOWNLOAD 模式直达下载目录、不拉起 picker 界面，每次调用返回当前可用的目录 uri，
 * 无需 FILE_ACCESS_PERSIST 持久化（uri 权限随本次调用授予，用完即写）。
 */
async function publicDownloadDirUri(): Promise<string> {
  const docPicker = new picker.DocumentViewPicker(AppEnv.context());
  const options = new picker.DocumentSaveOptions();
  options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
  const uris = await docPicker.save(options);
  if (uris.length === 0) {
    throw new Error('DOWNLOAD 模式返回空 uri 数组');
  }
  return uris[0];
}

function uniquePath(dir: string, name: string): string {
  let candidate = `${dir}/${name}`;
  if (!pathExists(candidate)) {
    return candidate;
  }
  const dot = name.lastIndexOf('.');
  const base = dot > 0 ? name.substring(0, dot) : name;
  const ext = dot > 0 ? name.substring(dot) : '';
  for (let i = 1; i < 1000; i++) {
    candidate = `${dir}/${base}_${i}${ext}`;
    if (!pathExists(candidate)) {
      return candidate;
    }
  }
  return `${dir}/${base}_${Date.now()}${ext}`;
}

/**
 * 判断路径/uri 是否存在。不能用 accessSync：对 file://docs 公共目录 uri，
 * 文件不存在时它抛 13900002 异常而非返回 false（真机实测），会把调用方误入回退分支。
 */
function pathExists(path: string): boolean {
  try {
    fs.statSync(path);
    return true;
  } catch (e) {
    return false;
  }
}

/** 清理发送时产生的临时缓存文件 */
export function deleteTempFiles(files: ResolvedFileItem[]): void {
  files.forEach((f: ResolvedFileItem) => {
    if (f.tempPath.length > 0) {
      try {
        fs.unlinkSync(f.tempPath);
      } catch (e) {
        // ignore
      }
    }
  });
}
