import { socket, connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Protocol, encodeText, decodeText } from '../core/Protocol';
import { DeviceItem, KEY_DEVICES, KEY_LOCAL_IP } from '../transfer/TransferModels';

/** 广播报文格式（方案.md §4.1），os 固定 "harmony" 与安卓版区分 */
interface DiscoveryJson {
  app: string;
  name: string;
  os: string;
  tcpPort: number;
  version: number;
}

/**
 * UDP 广播自动发现（对应安卓 discovery/DiscoveryService.kt）：
 * 每 2 秒向 255.255.255.255:47800 广播自身信息，同时监听 47800 收集他端广播；
 * 忽略本机 IP；超过 6 秒无心跳踢出；支持手动添加 IP 兜底（AP 隔离场景）。
 */
export class DiscoveryService {
  private udp: socket.UDPSocket | null = null;
  private broadcastTimer: number = -1;
  private pruneTimer: number = -1;
  private found: Map<string, DeviceItem> = new Map();
  private manual: Map<string, DeviceItem> = new Map();
  private ownIps: Set<string> = new Set();
  private running: boolean = false;
  private nameProvider: () => string = () => 'HarmonyOS';
  private portProvider: () => number = () => Protocol.TRANSFER_PORT;

  start(nameProvider: () => string, portProvider: () => number): void {
    if (this.running) {
      return;
    }
    this.running = true;
    this.nameProvider = nameProvider;
    this.portProvider = portProvider;
    this.setupSocket();
    this.refreshOwnIps();
    this.broadcastTimer = setInterval(() => {
      this.tickBroadcast();
    }, Protocol.BROADCAST_INTERVAL_MS);
    this.pruneTimer = setInterval(() => {
      this.prune();
    }, Protocol.BROADCAST_INTERVAL_MS);
  }

  stop(): void {
    this.running = false;
    if (this.broadcastTimer >= 0) {
      clearInterval(this.broadcastTimer);
      this.broadcastTimer = -1;
    }
    if (this.pruneTimer >= 0) {
      clearInterval(this.pruneTimer);
      this.pruneTimer = -1;
    }
    if (this.udp != null) {
      this.udp.close().catch((e: BusinessError) => {
        console.error(`[falai] udp close: ${e.code}`);
      });
      this.udp = null;
    }
    this.found.clear();
    this.publish();
  }

  /** 手动添加 IP 兜底（路由器 AP 隔离导致广播不通时），tcpPort 用默认 47801 */
  addManualDevice(ip: string): boolean {
    const trimmed = ip.trim();
    const reg = new RegExp('^(\\d{1,3}\\.){3}\\d{1,3}$');
    if (reg.exec(trimmed) == null) {
      return false;
    }
    const dev = new DeviceItem();
    dev.ip = trimmed;
    dev.name = '手动添加的设备';
    dev.os = 'unknown';
    dev.tcpPort = Protocol.TRANSFER_PORT;
    dev.lastSeen = Date.now();
    dev.manual = true;
    this.manual.set(trimmed, dev);
    this.publish();
    return true;
  }

  /** 网络断开/切换：清空在线设备（方案.md §4.2 容错） */
  onNetworkLost(): void {
    this.ownIps.clear();
    AppStorage.setOrCreate<string>(KEY_LOCAL_IP, '');
    if (this.found.size > 0) {
      this.found.clear();
      this.publish();
    }
  }

  onNetworkAvailable(): void {
    this.refreshOwnIps();
  }

  /** 本机主 IP（优先私网段），用于「本机卡片」展示与自广播过滤 */
  primaryIp(): string {
    let fallback = '';
    let found = false;
    let result = '';
    this.ownIps.forEach((ip: string) => {
      if (!found) {
        if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.') || ip.startsWith('169.254.')) {
          found = true;
          result = ip;
        } else if (fallback.length === 0) {
          fallback = ip;
        }
      }
    });
    if (found) {
      return result;
    }
    return fallback.length > 0 ? fallback : '未连接网络';
  }

  private async setupSocket(): Promise<void> {
    try {
      const udp = socket.constructUDPSocketInstance();
      udp.on('message', (info: socket.SocketMessageInfo) => {
        this.onMessage(info);
      });
      udp.on('error', (err: BusinessError) => {
        console.error(`[falai] udp error: ${err.code} ${err.message}`);
      });
      await udp.bind({ address: '0.0.0.0', port: Protocol.DISCOVERY_PORT, family: 1 });
      // 开启广播发送能力（方案.md §4.1：向 255.255.255.255 广播）
      await udp.setExtraOptions({ broadcast: true });
      this.udp = udp;
      console.info('[falai] UDP 发现已监听 47800');
    } catch (e) {
      console.error(`[falai] UDP 初始化失败: ${JSON.stringify(e)}`);
    }
  }

  private async refreshOwnIps(): Promise<void> {
    try {
      const net = await connection.getDefaultNet();
      const props = await connection.getConnectionProperties(net);
      const ips = new Set<string>();
      props.linkAddresses.forEach((la: connection.LinkAddress) => {
        const addr = la.address.address;
        if (addr.length > 0 && addr.indexOf(':') < 0) { // 只保留 IPv4
          ips.add(addr);
        }
      });
      this.ownIps = ips;
      AppStorage.setOrCreate<string>(KEY_LOCAL_IP, this.primaryIp());
    } catch (e) {
      // 无网络时 getDefaultNet 会失败，保持原状
    }
  }

  private selfJson(): DiscoveryJson {
    return {
      app: Protocol.APP_ID,
      name: this.nameProvider(),
      os: 'harmony',
      tcpPort: this.portProvider(),
      version: Protocol.VERSION
    };
  }

  private tickBroadcast(): void {
    if (!this.running || this.udp == null) {
      return;
    }
    this.refreshOwnIps();
    const data = encodeText(JSON.stringify(this.selfJson()));
    this.udp.send({
      data: data.buffer as ArrayBuffer,
      address: { address: '255.255.255.255', port: Protocol.DISCOVERY_PORT, family: 1 }
    }).catch((e: BusinessError) => {
      console.error(`[falai] 广播发送失败: ${e.code}`);
    });
  }

  private onMessage(info: socket.SocketMessageInfo): void {
    const senderIp = info.remoteInfo.address;
    if (this.ownIps.has(senderIp)) {
      return; // 忽略本机广播
    }
    try {
      const json = JSON.parse(decodeText(new Uint8Array(info.message))) as DiscoveryJson;
      if (json.app !== Protocol.APP_ID) {
        return;
      }
      const dev = new DeviceItem();
      dev.ip = senderIp;
      dev.name = json.name != null && json.name.length > 0 ? json.name : '未知设备';
      dev.os = json.os != null ? json.os : 'unknown';
      dev.tcpPort = json.tcpPort > 0 ? json.tcpPort : Protocol.TRANSFER_PORT;
      dev.lastSeen = Date.now();
      dev.manual = false;
      this.found.set(senderIp, dev);
      this.publish();
    } catch (e) {
      // 非本协议报文，忽略
    }
  }

  private prune(): void {
    const now = Date.now();
    let changed = false;
    this.found.forEach((dev: DeviceItem, ip: string) => {
      if (now - dev.lastSeen > Protocol.OFFLINE_TIMEOUT_MS) {
        this.found.delete(ip);
        changed = true;
      }
    });
    if (changed) {
      this.publish();
    }
  }

  private publish(): void {
    // 广播发现的实时信息优先于手动添加的占位（与安卓 publish 一致）
    const merged = new Map<string, DeviceItem>();
    this.manual.forEach((dev: DeviceItem, ip: string) => {
      merged.set(ip, dev);
    });
    this.found.forEach((dev: DeviceItem, ip: string) => {
      merged.set(ip, dev);
    });
    const list: DeviceItem[] = [];
    merged.forEach((dev: DeviceItem) => {
      list.push(dev);
    });
    list.sort((a: DeviceItem, b: DeviceItem) => a.name.localeCompare(b.name));
    AppStorage.setOrCreate<DeviceItem[]>(KEY_DEVICES, list);
  }
}

export const discoveryService: DiscoveryService = new DiscoveryService();
