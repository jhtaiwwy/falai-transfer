use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crate::protocol::Protocol;
use crate::transfer_models::Device;

/// 局域网设备发现服务（UDP 广播）
pub struct DiscoveryService {
    running: Arc<AtomicBool>,
    devices: Arc<Mutex<HashMap<String, Device>>>,
    own_name: Arc<Mutex<String>>,
    own_port: Arc<Mutex<u16>>,
    os: String,
}

impl DiscoveryService {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            devices: Arc::new(Mutex::new(HashMap::new())),
            own_name: Arc::new(Mutex::new("PC".to_string())),
            own_port: Arc::new(Mutex::new(Protocol::TRANSFER_PORT)),
            os: "windows".to_string(),
        }
    }

    pub fn start(&self, name: String, tcp_port: u16) {
        if self.running.load(Ordering::SeqCst) {
            return;
        }
        self.running.store(true, Ordering::SeqCst);
        *self.own_name.lock().unwrap() = name;
        *self.own_port.lock().unwrap() = tcp_port;

        let running = self.running.clone();
        let devices = self.devices.clone();
        let own_name = self.own_name.clone();
        let own_port = self.own_port.clone();
        let os = self.os.clone();

        // 广播线程
        let r = running.clone();
        let n = own_name.clone();
        let p = own_port.clone();
        thread::spawn(move || {
            Self::broadcast_loop(r, n, p, os);
        });

        // 监听线程
        let r2 = running.clone();
        let d2 = devices.clone();
        thread::spawn(move || {
            Self::listen_loop(r2, d2);
        });

        // 超时清理线程
        let r3 = running.clone();
        let d3 = devices.clone();
        thread::spawn(move || {
            Self::prune_loop(r3, d3);
        });
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
    }

    pub fn get_devices(&self) -> Vec<Device> {
        let map = self.devices.lock().unwrap();
        let mut list: Vec<Device> = map.values().cloned().collect();
        list.sort_by(|a, b| a.name.cmp(&b.name));
        list
    }

    pub fn add_manual_device(&self, ip: String) -> bool {
        let parts: Vec<&str> = ip.split('.').collect();
        if parts.len() != 4 {
            return false;
        }
        for p in &parts {
            if let Ok(v) = p.parse::<u32>() {
                if v > 255 {
                    return false;
                }
            } else {
                return false;
            }
        }
        let mut map = self.devices.lock().unwrap();
        map.insert(ip.clone(), Device {
            ip: ip.clone(),
            name: format!("手动添加 ({ip})"),
            os: "unknown".to_string(),
            tcp_port: crate::protocol::Protocol::TRANSFER_PORT,
            last_seen: chrono::Utc::now().timestamp_millis() as u64,
            manual: true,
        });
        true
    }

    /// 枚举本机所有可用局域网网卡的 (IPv4, 子网广播地址)，排除回环、链路本地
    /// 以及 Clash/Mihomo 等代理 TUN 网卡占用的保留段 198.18.0.0/15。
    /// 结果按 192.168.x.x > 10.x > 172.16-31.x > 其他 排序，保证真实局域网网卡优先。
    fn lan_interfaces() -> Vec<(Ipv4Addr, Ipv4Addr)> {
        let mut list: Vec<(u8, Ipv4Addr, Ipv4Addr)> = Vec::new();
        if let Ok(ifaces) = if_addrs::get_if_addrs() {
            for iface in ifaces {
                if iface.is_loopback() {
                    continue;
                }
                if let if_addrs::IfAddr::V4(v4) = iface.addr {
                    let ip = v4.ip;
                    if ip.is_loopback() || ip.is_link_local() || ip.is_unspecified() {
                        continue;
                    }
                    let o = ip.octets();
                    // 排除代理 fake-ip 保留段 198.18.0.0/15
                    if o[0] == 198 && (o[1] == 18 || o[1] == 19) {
                        continue;
                    }
                    let bcast = v4
                        .broadcast
                        .unwrap_or(Ipv4Addr::new(o[0], o[1], o[2], 255));
                    let prio = if o[0] == 192 && o[1] == 168 {
                        0
                    } else if o[0] == 10 {
                        1
                    } else if o[0] == 172 && (16..=31).contains(&o[1]) {
                        2
                    } else {
                        3
                    };
                    list.push((prio, ip, bcast));
                }
            }
        }
        list.sort_by_key(|(prio, _, _)| *prio);
        list.into_iter().map(|(_, ip, bcast)| (ip, bcast)).collect()
    }

    /// 获取本机局域网主 IP：优先取真实局域网网卡（避开 VPN/TUN 虚拟网卡），
    /// 枚举失败时退回 UDP connect 探测。
    pub fn primary_ip() -> String {
        if let Some((ip, _)) = Self::lan_interfaces().into_iter().next() {
            return ip.to_string();
        }
        if let Ok(sock) = UdpSocket::bind("0.0.0.0:0") {
            if sock.connect("255.255.255.255:1").is_ok() {
                if let Ok(local) = sock.local_addr() {
                    let ip = local.ip().to_string();
                    if ip != "0.0.0.0" {
                        return ip;
                    }
                }
            }
        }
        "127.0.0.1".to_string()
    }

    fn broadcast_loop(
        running: Arc<AtomicBool>,
        own_name: Arc<Mutex<String>>,
        own_port: Arc<Mutex<u16>>,
        os: String,
    ) {
        // 兜底 socket：网卡枚举失败时仍可全局广播
        let fallback = UdpSocket::bind("0.0.0.0:0").ok().map(|s| {
            let _ = s.set_broadcast(true);
            s
        });

        while running.load(Ordering::SeqCst) {
            let name = own_name.lock().unwrap().clone();
            let port = *own_port.lock().unwrap();
            let payload = serde_json::json!({
                "app": Protocol::APP_ID,
                "name": name,
                "os": os,
                "tcpPort": port,
                "version": Protocol::VERSION,
            });
            if let Ok(data) = serde_json::to_string(&payload) {
                let ifaces = Self::lan_interfaces();
                if ifaces.is_empty() {
                    // 枚举不到网卡时退回全局广播
                    if let Some(s) = &fallback {
                        let target = SocketAddr::new(
                            IpAddr::V4(Ipv4Addr::new(255, 255, 255, 255)),
                            Protocol::DISCOVERY_PORT,
                        );
                        let _ = s.send_to(data.as_bytes(), target);
                    }
                }
                // 每张网卡单独绑定发送，确保广播从正确的接口发出
                //（VPN/TUN 虚拟网卡在场时系统默认路由可能走错接口）
                for (ip, bcast) in ifaces {
                    let socket = match UdpSocket::bind(SocketAddr::new(IpAddr::V4(ip), 0)) {
                        Ok(s) => {
                            let _ = s.set_broadcast(true);
                            s
                        }
                        Err(_) => continue,
                    };
                    for target_ip in [bcast, Ipv4Addr::new(255, 255, 255, 255)] {
                        let target =
                            SocketAddr::new(IpAddr::V4(target_ip), Protocol::DISCOVERY_PORT);
                        if let Err(e) = socket.send_to(data.as_bytes(), target) {
                            // 发送失败，记日志但不中断
                            eprintln!("广播发送失败 {target}: {e}");
                        }
                    }
                }
            }
            thread::sleep(Duration::from_millis(Protocol::BROADCAST_INTERVAL_MS));
        }
    }

    fn listen_loop(
        running: Arc<AtomicBool>,
        devices: Arc<Mutex<HashMap<String, Device>>>,
    ) {
        let socket = match UdpSocket::bind(SocketAddr::new(
            IpAddr::V4(Ipv4Addr::UNSPECIFIED),
            Protocol::DISCOVERY_PORT,
        )) {
            Ok(s) => {
                let _ = s.set_read_timeout(Some(Duration::from_secs(1)));
                s
            }
            Err(_) => {
                match UdpSocket::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)) {
                    Ok(s) => {
                        let _ = s.set_read_timeout(Some(Duration::from_secs(1)));
                        s
                    }
                    Err(_) => return,
                }
            }
        };

        let mut buf = [0u8; 4096];
        while running.load(Ordering::SeqCst) {
            // 每轮重新枚举本机 IP（网卡/VPN 状态可能变化），用于跳过自己的广播
            let own_ips: std::collections::HashSet<String> = Self::lan_interfaces()
                .into_iter()
                .map(|(ip, _)| ip.to_string())
                .collect();
            match socket.recv_from(&mut buf) {
                Ok((len, src)) => {
                    let sender_ip = src.ip().to_string();
                    // 跳过自己发出的广播
                    if own_ips.contains(&sender_ip) {
                        continue;
                    }
                    if let Ok(json_str) = String::from_utf8(buf[..len].to_vec()) {
                        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&json_str) {
                            if json.get("app").and_then(|v| v.as_str()) != Some(Protocol::APP_ID) {
                                continue;
                            }
                            let device = Device {
                                ip: sender_ip.clone(),
                                name: json
                                    .get("name")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("未知设备")
                                    .to_string(),
                                os: json
                                    .get("os")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("unknown")
                                    .to_string(),
                                tcp_port: json
                                    .get("tcpPort")
                                    .and_then(|v| v.as_u64())
                                    .unwrap_or(Protocol::TRANSFER_PORT as u64) as u16,
                                last_seen: chrono::Utc::now().timestamp_millis() as u64,
                                manual: false,
                            };
                            let mut map = devices.lock().unwrap();
                            map.insert(sender_ip, device);
                        }
                    }
                }
                Err(_) => continue,
            }
        }
    }

    fn prune_loop(
        running: Arc<AtomicBool>,
        devices: Arc<Mutex<HashMap<String, Device>>>,
    ) {
        while running.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_millis(Protocol::BROADCAST_INTERVAL_MS));
            let now = chrono::Utc::now().timestamp_millis() as u64;
            let mut map = devices.lock().unwrap();
            map.retain(|_, d| {
                d.manual || (now - d.last_seen) < Protocol::OFFLINE_TIMEOUT_MS
            });
        }
    }
}