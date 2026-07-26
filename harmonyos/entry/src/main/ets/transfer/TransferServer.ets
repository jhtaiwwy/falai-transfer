import { socket } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Protocol, FrameReader, FrameSender, sendJson, sendText, sleep } from '../core/Protocol';
import { AppEnv } from '../core/AppEnv';
import { baseName } from '../core/Format';
import { IncomingRequest } from './TransferModels';
import { importReceivedFile } from './FileIO';

interface FileEntryJson {
  name: string;
  size: number;
}

interface RequestHeaderJson {
  app: string;
  version?: number;
  transferId?: string;
  from?: string;
  total?: number;
  files: FileEntryJson[];
}

interface FileMetaJson {
  name?: string;
  size?: number;
  offset?: number;
}

interface StatusJson {
  status: string;
  offsets?: number[];
}

interface SessionMetaJson {
  files: FileEntryJson[];
}

/** 服务端事件（对应安卓 TransferServer.Events 接口） */
export interface ServerEvents {
  /** 收到传输请求；返回是否接受（白名单秒回 true，否则等用户点弹窗） */
  decide: (request: IncomingRequest) => Promise<boolean>;
  /** 接受请求后开始进度展示；resumedBytes 为断点续传已接收字节 */
  onReceiveBegin: (peerName: string, fileCount: number, totalBytes: number, resumedBytes: number) => void;
  onProgress: (fileName: string, fileIndex: number, fileCount: number, transferredBytes: number) => void;
  /** 一次会话结束（无论成败）。只有接受过的会话 needLog=true；savedUri 为单文件会话的落点 */
  onFinished: (peerName: string, fileNames: string[], totalBytes: number, success: boolean,
    error: string, needLog: boolean, savedUri: string) => void;
  isBusy: () => boolean;
  isCanceled: () => boolean;
}

/**
 * 常驻 TCP 服务（对应安卓 transfer/TransferServer.kt）：
 * 端口 47801 起依次尝试绑定（47801~47811）；收到请求头后交由上层决定接受/拒绝；
 * 数据先写 cacheDir/incoming/<tid>_<i>.part 临时文件，收满后导入相册/文件目录；
 * 相同 transferId 重连时返回各文件 offset 实现断点续传（方案.md §4.2）。
 */
export class TransferServer {
  boundPort: number = 0;
  private running: boolean = false;
  private server: socket.TCPSocketServer | null = null;
  private sessions: Set<socket.TCPSocketConnection> = new Set();
  private events: ServerEvents;

  constructor(events: ServerEvents) {
    this.events = events;
  }

  /** 端口从 47801 起依次尝试绑定，返回是否成功；boundPort 为实际端口 */
  async start(): Promise<boolean> {
    if (this.running) {
      return this.boundPort > 0;
    }
    for (let i = 0; i < Protocol.PORT_TRY_COUNT; i++) {
      const port = Protocol.TRANSFER_PORT + i;
      try {
        const srv = socket.constructTCPSocketServerInstance();
        srv.on('connect', (conn: socket.TCPSocketConnection) => {
          this.handle(conn);
        });
        srv.on('error', (err: BusinessError) => {
          console.error(`[falai] TCP 服务错误: ${err.code} ${err.message}`);
        });
        await srv.listen({ address: '0.0.0.0', port: port, family: 1 });
        this.server = srv;
        this.boundPort = port;
        this.running = true;
        console.info(`[falai] TCP 服务已监听 ${port}`);
        return true;
      } catch (e) {
        console.error(`[falai] 端口 ${port} 绑定失败，尝试下一个`);
        continue;
      }
    }
    return false;
  }

  stop(): void {
    this.running = false;
    this.cancelSessions();
    if (this.server != null) {
      this.server.close().catch((e: BusinessError) => {
        console.error(`[falai] server close: ${e.code}`);
      });
      this.server = null;
    }
    this.boundPort = 0;
  }

  /** 取消进行中的接收会话（关闭 socket 使等待中的读取立即失败） */
  cancelSessions(): void {
    this.sessions.forEach((conn: socket.TCPSocketConnection) => {
      try {
        conn.close();
      } catch (e) {
        // ignore
      }
    });
  }

  // ---------- 断点续传会话存储（对应安卓 sessionDir/metaFile/partFile/computeOffsets） ----------

  private sessionDir(): string {
    const dir = AppEnv.incomingDir();
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    return dir;
  }

  private sanitizeTid(tid: string): string {
    const cleaned = tid.replace(new RegExp('[^A-Za-z0-9_-]', 'g'), '');
    return cleaned.length > 0 ? cleaned : 'x';
  }

  private metaFile(tid: string): string {
    return `${this.sessionDir()}/${tid}.json`;
  }

  private partFile(tid: string, index: number): string {
    return `${this.sessionDir()}/${tid}_${index}.part`;
  }

  /** 各文件已接收字节：会话元信息与本次请求一致时取 .part 长度，否则清掉旧会话 */
  private async computeOffsets(tid: string, files: FileEntryJson[]): Promise<number[]> {
    const offsets: number[] = files.map(() => 0);
    try {
      const mf = this.metaFile(tid);
      if (fs.accessSync(mf)) {
        const meta = JSON.parse(await fs.readText(mf)) as SessionMetaJson;
        let match = meta.files.length === files.length;
        if (match) {
          for (let i = 0; i < files.length; i++) {
            if (meta.files[i].name !== files[i].name || meta.files[i].size !== files[i].size) {
              match = false;
              break;
            }
          }
        }
        if (match) {
          for (let i = 0; i < files.length; i++) {
            const part = this.partFile(tid, i);
            if (fs.accessSync(part)) {
              const size = fs.statSync(part).size;
              offsets[i] = Math.min(size, files[i].size);
            }
          }
          return offsets;
        }
      }
    } catch (e) {
      // 元信息损坏则按不匹配处理
    }
    // 会话信息不匹配：清理旧临时文件（与安卓一致）
    try {
      const prefix = `${tid}_`;
      const names = fs.listFileSync(this.sessionDir());
      names.forEach((n: string) => {
        if (n.startsWith(prefix) || n === `${tid}.json`) {
          try {
            fs.unlinkSync(`${this.sessionDir()}/${n}`);
          } catch (e) {
            // ignore
          }
        }
      });
    } catch (e) {
      // ignore
    }
    return offsets;
  }

  private saveSessionMeta(tid: string, files: FileEntryJson[]): void {
    try {
      const meta: SessionMetaJson = { files: files };
      const file = fs.openSync(this.metaFile(tid), fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(meta));
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      // ignore
    }
  }

  // ---------- 会话处理（对应安卓 handle） ----------

  private async handle(conn: socket.TCPSocketConnection): Promise<void> {
    this.sessions.add(conn);
    let peerName = '未知设备';
    const fileNames: string[] = [];
    let total = 0;
    let success = false;
    let error = '';
    let needLog = false;
    let savedUri = '';
    const reader = new FrameReader();
    conn.on('message', (info: socket.SocketMessageInfo) => {
      reader.feed(info.message);
    });
    conn.on('close', () => {
      reader.fail(new Error('连接中断'));
    });
    conn.on('error', (err: BusinessError) => {
      reader.fail(new Error(`连接错误: ${err.code}`));
    });
    try {
      try {
        const remote = await conn.getRemoteAddress();
        peerName = remote.address;
      } catch (e) {
        // 保持默认
      }
      const fromIp = peerName;
      const sender: FrameSender = (buf: ArrayBuffer) => conn.send({ data: buf });

      // ① 请求头（30 秒超时）
      const header = JSON.parse(await reader.readText(Protocol.HEADER_TIMEOUT_MS)) as RequestHeaderJson;
      if (header.app !== Protocol.APP_ID) {
        return;
      }
      if (header.from != null && header.from.length > 0) {
        peerName = header.from;
      }
      total = header.total != null ? header.total : 0;
      const tid = this.sanitizeTid(header.transferId != null && header.transferId.length > 0 ? header.transferId : 'legacy');
      const files = header.files.map((f: FileEntryJson): FileEntryJson => {
        return { name: baseName(f.name).length > 0 ? baseName(f.name) : 'file', size: f.size };
      });

      // 正在收发别的文件：直接拒绝（与安卓 isBusy 一致）
      if (this.events.isBusy()) {
        const rej: StatusJson = { status: Protocol.RESP_REJECT };
        await sendJson(sender, rej);
        return;
      }

      // ② 白名单自动接受 / 弹窗确认（最多等 110 秒）
      const req = new IncomingRequest();
      req.id = Date.now();
      req.fromName = peerName;
      req.fromIp = fromIp;
      req.fileCount = files.length;
      req.totalBytes = total;
      const accepted = await Promise.race<boolean>([
        this.events.decide(req),
        this.timeoutFalse(Protocol.DECIDE_TIMEOUT_MS)
      ]);
      if (!accepted) {
        try {
          const rej: StatusJson = { status: Protocol.RESP_REJECT };
          await sendJson(sender, rej);
        } catch (e) {
          // ignore
        }
        return;
      }

      // 断点续传：返回各文件已接收字节数
      const offsets = await this.computeOffsets(tid, files);
      this.saveSessionMeta(tid, files);
      const ackJson: StatusJson = { status: Protocol.RESP_ACCEPT, offsets: offsets };
      await sendJson(sender, ackJson);

      // 数据阶段：5 分钟无数据判超时（暂停超 5 分钟会断开，可再次重连续传）
      needLog = true;
      let transferred = offsets.reduce((s: number, o: number) => s + o, 0);
      this.events.onReceiveBegin(peerName, files.length, total, transferred);

      const importedUris: string[] = [];
      for (let i = 0; i < files.length; i++) {
        // ③ 单文件元信息
        const meta = JSON.parse(await reader.readText(Protocol.DATA_TIMEOUT_MS)) as FileMetaJson;
        const name = meta.name != null && baseName(meta.name).length > 0 ? baseName(meta.name) : files[i].name;
        const size = meta.size != null ? meta.size : files[i].size;
        let offset = meta.offset != null ? meta.offset : 0;
        offset = Math.min(Math.max(offset, 0), size);
        fileNames.push(name);
        const part = this.partFile(tid, i);
        if (offset < size) {
          // 等价安卓 RandomAccessFile：截掉 offset 之后的脏数据，再追加写入
          if (offset > 0) {
            fs.truncateSync(part, offset);
          }
          const openMode = offset > 0
            ? (fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND | fs.OpenMode.CREATE)
            : (fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          const file = fs.openSync(part, openMode);
          try {
            let remaining = size - offset;
            while (remaining > 0) {
              if (this.events.isCanceled()) {
                throw new Error('已取消');
              }
              const chunk = await reader.readBytes(Math.min(Protocol.BUFFER_SIZE, remaining), Protocol.DATA_TIMEOUT_MS);
              fs.writeSync(file.fd, chunk.buffer as ArrayBuffer);
              remaining -= chunk.length;
              transferred += chunk.length;
              this.events.onProgress(name, i, files.length, transferred);
            }
          } finally {
            try {
              fs.closeSync(file);
            } catch (e) {
              // ignore
            }
          }
        }
        // 收满：导入相册/文件目录并删除临时文件（方案.md §4.2 步骤⑤）
        const result = await importReceivedFile(part, name);
        try {
          fs.unlinkSync(part);
        } catch (e) {
          // ignore
        }
        importedUris.push(result.contentUri);
        await sendText(sender, Protocol.RESP_ACK);
      }
      // ⑥ 全部完成
      await sendText(sender, Protocol.RESP_DONE);
      try {
        fs.unlinkSync(this.metaFile(tid));
      } catch (e) {
        // ignore
      }
      success = true;
      if (importedUris.length === 1 && importedUris[0].length > 0) {
        savedUri = importedUris[0];
      }
    } catch (e) {
      const err = e as Error;
      error = err.message != null && err.message.length > 0 ? err.message : '未知错误';
    } finally {
      this.sessions.delete(conn);
      try {
        await conn.close();
      } catch (e) {
        // ignore
      }
      this.events.onFinished(peerName, fileNames, total, success, error, needLog, savedUri);
    }
  }

  private timeoutFalse(ms: number): Promise<boolean> {
    return sleep(ms).then(() => false);
  }
}
