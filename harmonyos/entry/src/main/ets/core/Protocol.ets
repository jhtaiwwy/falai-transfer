import { util } from '@kit.ArkTS';

/**
 * 通信协议常量与帧读写工具（与安卓版 core/Protocol.kt 逐字节一致）。
 * 协议契约见 docs/方案.md 第 4 节：
 * UDP 广播发现（47800）+ TCP 直传（47801 起自动后移），
 * 每条控制消息 = [4 字节大端长度][UTF-8 JSON/文本]，随后是原始字节流。
 */
export class Protocol {
  static readonly APP_ID: string = 'FT';
  static readonly VERSION: number = 1;
  static readonly DISCOVERY_PORT: number = 47800;
  static readonly TRANSFER_PORT: number = 47801;
  /** 接收端口冲突时自动后移的最大个数：47801~47811（方案.md §4.2） */
  static readonly PORT_TRY_COUNT: number = 11;
  static readonly BROADCAST_INTERVAL_MS: number = 2000;
  static readonly OFFLINE_TIMEOUT_MS: number = 6000;
  static readonly BUFFER_SIZE: number = 32 * 1024;
  /** 单帧最大长度，与安卓 readFrame 的 maxLen 一致 */
  static readonly MAX_FRAME_LEN: number = 4 * 1024 * 1024;

  static readonly RESP_ACCEPT: string = 'ACCEPT';
  static readonly RESP_REJECT: string = 'REJECT';
  static readonly RESP_ACK: string = 'ACK';
  static readonly RESP_DONE: string = 'DONE';

  /** 服务端等待请求头的超时（对应安卓 socket.soTimeout = 30_000） */
  static readonly HEADER_TIMEOUT_MS: number = 30000;
  /** 数据阶段无数据超时，超时判失败、会话保留可续传（对应安卓 soTimeout = 300_000） */
  static readonly DATA_TIMEOUT_MS: number = 300000;
  /** 客户端等待对方确认的超时（对应安卓 soTimeout = 120_000） */
  static readonly ACCEPT_TIMEOUT_MS: number = 120000;
  /** 服务端等待用户在确认弹窗上操作的超时（对应安卓 deadline = 110_000） */
  static readonly DECIDE_TIMEOUT_MS: number = 110000;
}

const textEncoder = util.TextEncoder.create('utf-8');
const textDecoder = util.TextDecoder.create('utf-8');

export function encodeText(text: string): Uint8Array {
  return textEncoder.encodeInto(text);
}

export function decodeText(data: Uint8Array): string {
  return textDecoder.decodeToString(data);
}

export function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/** 帧发送方抽象：TCP 客户端 socket 与服务端连接都适配成该签名 */
export type FrameSender = (buf: ArrayBuffer) => Promise<void>;

/** 写一帧：[4 字节大端长度][payload]（对应安卓 Protocol.writeFrame） */
export async function sendFrame(sender: FrameSender, payload: Uint8Array): Promise<void> {
  const out = new Uint8Array(4 + payload.length);
  new DataView(out.buffer as ArrayBuffer).setUint32(0, payload.length, false); // 大端，与 Java writeInt 一致
  out.set(payload, 4);
  await sender(out.buffer as ArrayBuffer);
}

export async function sendText(sender: FrameSender, text: string): Promise<void> {
  await sendFrame(sender, encodeText(text));
}

export async function sendJson(sender: FrameSender, obj: Object): Promise<void> {
  await sendText(sender, JSON.stringify(obj));
}

interface ReadWaiter {
  needed: number;
  resolve: (buf: Uint8Array) => void;
  reject: (e: Error) => void;
  timer: number;
}

/**
 * 粘包处理器：TCP on('message') 回调可能任意切片/合并，
 * 这里把分片累积成队列，按「读 n 字节」的 Promise 化语义吐出，
 * 对应安卓端 DataInputStream.readFully 的阻塞读取语义。
 * 用法：会话内严格串行 await（readInt/readText/readBytes），不并发调用。
 */
export class FrameReader {
  private chunks: Uint8Array[] = [];
  private buffered: number = 0;
  private waiter: ReadWaiter | null = null;
  private failed: Error | null = null;

  /** socket on('message') 回调里喂数据 */
  feed(data: ArrayBuffer): void {
    if (this.failed != null) {
      return;
    }
    const u8 = new Uint8Array(data);
    if (u8.length === 0) {
      return;
    }
    this.chunks.push(u8);
    this.buffered += u8.length;
    this.pump();
  }

  /** socket on('close')/on('error')/读取超时 时调用，挂起的读取全部 reject */
  fail(e: Error): void {
    if (this.failed != null) {
      return;
    }
    this.failed = e;
    const w = this.waiter;
    this.waiter = null;
    if (w != null) {
      clearTimeout(w.timer);
      w.reject(e);
    }
  }

  /** 精确读取 n 字节（对应 readFully），timeoutMs 内凑不齐判超时并断开会话 */
  readBytes(n: number, timeoutMs: number): Promise<Uint8Array> {
    if (this.failed != null) {
      return Promise.reject(this.failed);
    }
    if (this.waiter != null) {
      return Promise.reject(new Error('FrameReader: 存在未完成的读取，读取必须串行'));
    }
    return new Promise<Uint8Array>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiter = null;
        const err = new Error('读取超时');
        this.failed = err;
        reject(err);
      }, timeoutMs);
      this.waiter = { needed: n, resolve: resolve, reject: reject, timer: timer };
      this.pump();
    });
  }

  /** 读 4 字节大端长度（对应 DataInputStream.readInt） */
  async readInt(timeoutMs: number): Promise<number> {
    const b = await this.readBytes(4, timeoutMs);
    return new DataView(b.buffer as ArrayBuffer).getUint32(0, false);
  }

  /** 读一帧（长度 + payload），对应安卓 Protocol.readFrame */
  async readFrame(timeoutMs: number): Promise<Uint8Array> {
    const len = await this.readInt(timeoutMs);
    if (len <= 0 || len > Protocol.MAX_FRAME_LEN) {
      throw new Error(`非法帧长度: ${len}`);
    }
    return this.readBytes(len, timeoutMs);
  }

  /** 读一帧并按 UTF-8 解码，对应安卓 Protocol.readText / readJson（调用方再 JSON.parse） */
  async readText(timeoutMs: number): Promise<string> {
    return decodeText(await this.readFrame(timeoutMs));
  }

  /** 队列里凑够 waiter 需要的字节数就一次性切出并 resolve */
  private pump(): void {
    const w = this.waiter;
    if (w == null || this.buffered < w.needed) {
      return;
    }
    const out = new Uint8Array(w.needed);
    let copied = 0;
    while (copied < w.needed) {
      const head = this.chunks[0];
      const take = Math.min(head.length, w.needed - copied);
      out.set(head.subarray(0, take), copied);
      copied += take;
      if (take === head.length) {
        this.chunks.shift();
      } else {
        this.chunks[0] = head.subarray(take);
      }
    }
    this.buffered -= w.needed;
    this.waiter = null;
    clearTimeout(w.timer);
    w.resolve(out);
  }
}
