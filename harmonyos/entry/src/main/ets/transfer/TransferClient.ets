import { socket } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Protocol, FrameReader, FrameSender, sendJson, sleep } from '../core/Protocol';
import { ResolvedFileItem } from './TransferModels';
import { openResolved } from './FileIO';

/** 对方拒绝接收时抛出（对应安卓 TransferClient.RejectedException） */
export class RejectedError extends Error {
  constructor(msg: string) {
    super(msg);
    this.name = 'RejectedError';
  }
}

/** 请求头 JSON（方案.md §4.2 步骤①） */
interface RequestHeaderJson {
  app: string;
  version: number;
  transferId: string;
  from: string;
  total: number;
  files: FileEntryJson[];
}

interface FileEntryJson {
  name: string;
  size: number;
}

/** 服务端应答（步骤②）：ACCEPT 时带各文件已收字节数 offsets */
interface AcceptResponseJson {
  status: string;
  offsets?: number[];
}

/** 单文件元信息（步骤③） */
interface FileMetaJson {
  name: string;
  size: number;
  offset: number;
}

/** 发送过程回调（对应安卓 TransferClient.send 的各 lambda 参数） */
export interface ClientCallbacks {
  isCanceled: () => boolean;
  isPaused: () => boolean;
  onWaitingAccept: () => void;
  onProgress: (currentFile: string, fileIndex: number, transferredBytes: number) => void;
  onSocket: (tcp: socket.TCPSocket | null) => void;
}

/**
 * 发送方会话（对应安卓 transfer/TransferClient.kt）：
 * 连接 → ① 发请求头（含 transferId）→ ② 等 {status, offsets} →
 * 逐文件 ③ 发元信息（带 offset）④ 从断点续传字节流 → ⑤ 等 ACK → ⑥ 等 DONE。
 * 支持暂停/继续与取消（取消直接 close socket）。
 */
export async function sendFilesTo(
  ip: string,
  port: number,
  transferId: string,
  fromName: string,
  files: ResolvedFileItem[],
  cb: ClientCallbacks
): Promise<void> {
  const total = files.reduce((sum: number, f: ResolvedFileItem) => sum + f.size, 0);
  const tcp = socket.constructTCPSocketInstance();
  cb.onSocket(tcp);
  const reader = new FrameReader();
  tcp.on('message', (info: socket.SocketMessageInfo) => {
    reader.feed(info.message);
  });
  tcp.on('close', () => {
    reader.fail(new Error('连接中断'));
  });
  tcp.on('error', (err: BusinessError) => {
    reader.fail(new Error(`连接错误: ${err.code}`));
  });
  try {
    await tcp.connect({ address: { address: ip, port: port, family: 1 }, timeout: 8000 });
    const sender: FrameSender = (buf: ArrayBuffer) => tcp.send({ data: buf });

    // ① 请求头
    const header: RequestHeaderJson = {
      app: Protocol.APP_ID,
      version: Protocol.VERSION,
      transferId: transferId,
      from: fromName,
      total: total,
      files: files.map((f: ResolvedFileItem): FileEntryJson => {
        return { name: f.name, size: f.size };
      })
    };
    await sendJson(sender, header);

    // ② 等待对方确认（对方用户可能考虑较久，120 秒超时；白名单设备秒回）
    cb.onWaitingAccept();
    const resp = JSON.parse(await reader.readText(Protocol.ACCEPT_TIMEOUT_MS)) as AcceptResponseJson;
    if (resp.status !== Protocol.RESP_ACCEPT) {
      throw new RejectedError('对方拒绝了接收请求');
    }

    // 断点续传：各文件已接收字节数（方案.md §4.2 步骤②）
    const offsets: number[] = files.map((f: ResolvedFileItem, i: number): number => {
      if (resp.offsets != null && i < resp.offsets.length) {
        const o = resp.offsets[i];
        return Math.min(Math.max(o, 0), f.size);
      }
      return 0;
    });
    let transferred = offsets.reduce((s: number, o: number) => s + o, 0);
    if (transferred > 0) {
      let resumeIdx = offsets.findIndex((o: number, i: number) => o > 0 && o < files[i].size);
      if (resumeIdx < 0) {
        resumeIdx = 0;
      }
      cb.onProgress(files[resumeIdx].name, 0, transferred);
    }

    for (let idx = 0; idx < files.length; idx++) {
      if (cb.isCanceled()) {
        throw new Error('已取消');
      }
      const f = files[idx];
      const offset = offsets[idx];
      // ③ 单文件元信息（带 offset）
      const meta: FileMetaJson = { name: f.name, size: f.size, offset: offset };
      await sendJson(sender, meta);
      // ④ 从 offset 处续传字节流
      if (offset < f.size) {
        const file = openResolved(f);
        try {
          const buf = new ArrayBuffer(Protocol.BUFFER_SIZE);
          let pos = offset;
          let remaining = f.size - offset;
          while (remaining > 0) {
            if (cb.isCanceled()) {
              throw new Error('已取消');
            }
            // 暂停：停止推流、连接保持（方案.md §4.2 暂停/继续）
            while (cb.isPaused() && !cb.isCanceled()) {
              await sleep(200);
            }
            if (cb.isCanceled()) {
              throw new Error('已取消');
            }
            const want = Math.min(Protocol.BUFFER_SIZE, remaining);
            const n = fs.readSync(file.fd, buf, { offset: pos, length: want });
            if (n <= 0) {
              throw new Error(`读取文件中断: ${f.name}`);
            }
            await tcp.send({ data: buf.slice(0, n) });
            pos += n;
            remaining -= n;
            transferred += n;
            cb.onProgress(f.name, idx, transferred);
          }
        } finally {
          try {
            fs.closeSync(file);
          } catch (e) {
            // ignore
          }
        }
      }
      // ⑤ 单文件 ACK（对方要把数据导入相册/目录，大文件可能耗时，给 5 分钟）
      const ack = await reader.readText(Protocol.DATA_TIMEOUT_MS);
      if (ack !== Protocol.RESP_ACK) {
        throw new Error(`对端确认异常: ${ack}`);
      }
    }
    // ⑥ 全部完成
    await reader.readText(Protocol.DATA_TIMEOUT_MS);
  } finally {
    cb.onSocket(null);
    try {
      await tcp.close();
    } catch (e) {
      // ignore
    }
  }
}
