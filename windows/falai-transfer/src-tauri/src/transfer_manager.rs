use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::file_io::FileIO;
use crate::protocol::Protocol;
use crate::transfer_models::*;
use crate::format;

/// 传输管理器：接收服务端 + 发送客户端 + 进度管理
pub struct TransferManager {
    pub running: Arc<AtomicBool>,
    pub server_port: Arc<AtomicU16>,
    pub progress: Arc<Mutex<TransferProgress>>,
    pub incoming: Arc<Mutex<Option<IncomingRequest>>>,
    pending_responder: Arc<Mutex<Option<Box<dyn FnOnce(bool) + Send>>>>,
    canceled: Arc<AtomicBool>,
    paused: Arc<AtomicBool>,
    client_socket: Arc<Mutex<Option<TcpStream>>>,
    sessions: Arc<Mutex<Vec<TcpStream>>>,
    log_repo: Arc<Mutex<crate::log_repo::LogRepository>>,
    transfer_start: Arc<Mutex<Option<Instant>>>,
    save_path: Arc<Mutex<String>>,
}

impl TransferManager {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            server_port: Arc::new(AtomicU16::new(0)),
            progress: Arc::new(Mutex::new(TransferProgress::default())),
            incoming: Arc::new(Mutex::new(None)),
            pending_responder: Arc::new(Mutex::new(None)),
            canceled: Arc::new(AtomicBool::new(false)),
            paused: Arc::new(AtomicBool::new(false)),
            client_socket: Arc::new(Mutex::new(None)),
            sessions: Arc::new(Mutex::new(Vec::new())),
            log_repo: Arc::new(Mutex::new(crate::log_repo::LogRepository::new())),
            transfer_start: Arc::new(Mutex::new(None)),
            save_path: Arc::new(Mutex::new(crate::transfer_models::AppSettings::default().save_path)),
        }
    }

    /// 启动 TCP 接收服务端（47801~47811 尝试绑定）
    pub fn start_server(&self) -> bool {
        if self.running.load(Ordering::SeqCst) {
            return self.server_port.load(Ordering::SeqCst) > 0;
        }

        let listener = {
            let mut ls = None;
            for port in Protocol::TRANSFER_PORT..=Protocol::TRANSFER_PORT + 10 {
                if let Ok(l) = TcpListener::bind(format!("0.0.0.0:{port}")) {
                    self.server_port.store(port, Ordering::SeqCst);
                    ls = Some(l);
                    break;
                }
            }
            ls
        };

        match listener {
            Some(l) => {
                self.running.store(true, Ordering::SeqCst);
                let running = self.running.clone();
                let sessions = self.sessions.clone();
                let progress = self.progress.clone();
                let incoming = self.incoming.clone();
                let responder = self.pending_responder.clone();
                let canceled = self.canceled.clone();
                let log_repo = self.log_repo.clone();
                let transfer_start = self.transfer_start.clone();
                let save_path = self.save_path.clone();

                thread::spawn(move || {
                    l.set_nonblocking(true).ok();
                    while running.load(Ordering::SeqCst) {
                        match l.accept() {
                            Ok((stream, _addr)) => {
                                // 监听套接字是非阻塞的，Windows 上接受套接字会继承该标志，
                                // 导致后续阻塞读在数据未到达时立即返回 WouldBlock。
                                // 必须显式恢复为阻塞模式，否则断点续传/文件流的 read_exact 会失败。
                                let _ = stream.set_nonblocking(false);
                                let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
                                sessions.lock().unwrap().push(stream.try_clone().unwrap());
                                let s = sessions.clone();
                                let p = progress.clone();
                                let inc = incoming.clone();
                                let rp = responder.clone();
                                let cn = canceled.clone();
                                let lr = log_repo.clone();
                                let ts = transfer_start.clone();
                                let sp = save_path.clone();
                                thread::spawn(move || {
                                    handle_receive_session(stream, s, p, inc, rp, cn, lr, ts, sp);
                                });
                            }
                            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                                thread::sleep(Duration::from_millis(200));
                            }
                            Err(_) => thread::sleep(Duration::from_secs(1)),
                        }
                    }
                });
                true
            }
            None => false,
        }
    }

    pub fn stop_server(&self) {
        self.running.store(false, Ordering::SeqCst);
        let sessions = self.sessions.lock().unwrap();
        for s in sessions.iter() {
            let _ = s.shutdown(std::net::Shutdown::Both);
        }
    }

    /// 发送文件
    pub fn send_files(&self, ip: &str, port: u16, peer_name: &str, files: Vec<ResolvedFile>) {
        let total = files.iter().map(|f| f.size).sum::<u64>();
        let transfer_id = derive_transfer_id(ip, &files);

        // 重置状态
        self.canceled.store(false, Ordering::SeqCst);
        self.paused.store(false, Ordering::SeqCst);
        *self.transfer_start.lock().unwrap() = Some(Instant::now());

        let p = self.progress.clone();
        *p.lock().unwrap() = TransferProgress {
            show: true,
            active: true,
            direction: Direction::Send,
            peer_name: peer_name.to_string(),
            status: TransferStatus::Transferring,
            current_file: String::new(),
            file_index: 0,
            file_count: files.len() as u32,
            total_bytes: total,
            transferred_bytes: 0,
            speed_bps: 0.0,
            eta_seconds: 0,
            error: None,
        };

        let ip = ip.to_string();
        let peer_name = peer_name.to_string();
        let tid = transfer_id.clone();
        let cn = self.canceled.clone();
        let ps = self.paused.clone();
        let cs = self.client_socket.clone();
        let pg = self.progress.clone();
        let lr = self.log_repo.clone();
        let ts = self.transfer_start.clone();

        thread::spawn(move || {
            let result = send_files_impl(&ip, port, &peer_name, &files, &tid, &cn, &ps, &cs, &pg, &ts);
            match result {
                Ok(()) => {
                    let mut p = pg.lock().unwrap();
                    p.active = false;
                    p.status = TransferStatus::Done;
                    lr.lock().unwrap().add(TransferLog {
                        time_millis: chrono::Utc::now().timestamp_millis() as u64,
                        outgoing: true,
                        peer_name: peer_name.clone(),
                        file_summary: format::summarize_files(&files.iter().map(|f| f.name.clone()).collect::<Vec<_>>()),
                        size_bytes: total,
                        success: true,
                        result_text: "成功".to_string(),
                        duration_ms: ts.lock().unwrap().map(|t| t.elapsed().as_millis() as u64).unwrap_or(0),
                        avg_speed_bps: 0.0,
                    });
                }
                Err(e) => {
                    let mut p = pg.lock().unwrap();
                    p.active = false;
                    p.status = if cn.load(Ordering::SeqCst) { TransferStatus::Canceled }
                               else { TransferStatus::Failed };
                    p.error = Some(e.to_string());
                    lr.lock().unwrap().add(TransferLog {
                        time_millis: chrono::Utc::now().timestamp_millis() as u64,
                        outgoing: true,
                        peer_name: peer_name.clone(),
                        file_summary: format::summarize_files(&files.iter().map(|f| f.name.clone()).collect::<Vec<_>>()),
                        size_bytes: total,
                        success: false,
                        result_text: format!("失败: {}", e),
                        duration_ms: ts.lock().unwrap().map(|t| t.elapsed().as_millis() as u64).unwrap_or(0),
                        avg_speed_bps: 0.0,
                    });
                }
            }
        });
    }

    /// 响应传入请求
    pub fn respond_incoming(&self, accept: bool, trust: bool, ip: &str) {
        if let Some(responder) = self.pending_responder.lock().unwrap().take() {
            if trust && !ip.is_empty() {
                // TODO: 添加到白名单
            }
            *self.incoming.lock().unwrap() = None;
            responder(accept);
        }
    }

    pub fn cancel(&self) {
        self.canceled.store(true, Ordering::SeqCst);
        self.paused.store(false, Ordering::SeqCst);
        if let Some(socket) = self.client_socket.lock().unwrap().take() {
            let _ = socket.shutdown(std::net::Shutdown::Both);
        }
        let sessions = self.sessions.lock().unwrap();
        for s in sessions.iter() {
            let _ = s.shutdown(std::net::Shutdown::Both);
        }
    }

    pub fn pause(&self) {
        self.paused.store(true, Ordering::SeqCst);
        let mut p = self.progress.lock().unwrap();
        p.status = TransferStatus::Paused;
    }

    pub fn resume(&self) {
        self.paused.store(false, Ordering::SeqCst);
        let mut p = self.progress.lock().unwrap();
        p.status = TransferStatus::Transferring;
    }

    pub fn set_save_path(&self, path: &str) {
        *self.save_path.lock().unwrap() = path.to_string();
    }

    pub fn get_progress(&self) -> TransferProgress {
        self.progress.lock().unwrap().clone()
    }

    pub fn get_incoming(&self) -> Option<IncomingRequest> {
        self.incoming.lock().unwrap().clone()
    }

    pub fn get_logs(&self) -> Vec<TransferLog> {
        self.log_repo.lock().unwrap().load()
    }

    pub fn delete_log(&self, index: usize) {
        self.log_repo.lock().unwrap().delete(index);
    }

    pub fn clear_logs(&self) {
        self.log_repo.lock().unwrap().clear();
    }
}

fn derive_transfer_id(ip: &str, files: &[ResolvedFile]) -> String {
    use md5::{Md5, Digest};
    let raw = ip.to_string() + &files.iter().map(|f| format!("{}:{}", f.name, f.size)).collect::<Vec<_>>().join("|");
    let mut hasher = Md5::new();
    hasher.update(raw.as_bytes());
    let result = hasher.finalize();
    format!("t{}", hex::encode(&result[..8]))
}

fn send_files_impl(
    ip: &str, port: u16, peer_name: &str, files: &[ResolvedFile],
    transfer_id: &str, canceled: &Arc<AtomicBool>, paused: &Arc<AtomicBool>,
    client_socket: &Arc<Mutex<Option<TcpStream>>>,
    progress: &Arc<Mutex<TransferProgress>>,
    transfer_start: &Arc<Mutex<Option<Instant>>>,
) -> Result<(), String> {
    let mut stream = TcpStream::connect(format!("{ip}:{port}"))
        .map_err(|e| format!("连接失败: {e}"))?;
    stream.set_write_timeout(Some(Duration::from_secs(30))).ok();
    *client_socket.lock().unwrap() = Some(stream.try_clone().map_err(|e| e.to_string())?);

    let total = files.iter().map(|f| f.size).sum::<u64>();
    let files_json: Vec<serde_json::Value> = files.iter().map(|f| {
        serde_json::json!({"name": f.name, "size": f.size})
    }).collect();

    let header = serde_json::json!({
        "app": Protocol::APP_ID,
        "version": Protocol::VERSION,
        "transferId": transfer_id,
        "from": peer_name,
        "total": total,
        "files": files_json,
    });
    Protocol::write_json(&mut stream, &header).map_err(|e| format!("发送请求头失败: {e}"))?;

    // 等待接受
    stream.set_read_timeout(Some(Duration::from_secs(120))).ok();
    let resp = Protocol::read_json(&mut stream).map_err(|e| format!("读取响应失败: {e}"))?;
    if resp.get("status").and_then(|v| v.as_str()) != Some(Protocol::RESP_ACCEPT) {
        return Err("对方拒绝了接收请求".to_string());
    }
    stream.set_read_timeout(None).ok();

    let offsets: Vec<u64> = resp.get("offsets")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().map(|o| o.as_u64().unwrap_or(0)).collect())
        .unwrap_or_else(|| vec![0u64; files.len()]);

    let mut transferred = offsets.iter().sum::<u64>();
    let start_offset = transferred;

    for (i, file) in files.iter().enumerate() {
        if canceled.load(Ordering::SeqCst) {
            return Err("已取消".to_string());
        }
        let offset = offsets[i].min(file.size);
        let meta = serde_json::json!({"name": file.name, "size": file.size, "offset": offset});
        Protocol::write_json(&mut stream, &meta).map_err(|e| format!("发送文件元信息失败: {e}"))?;

        if offset < file.size {
            let mut f = File::open(&file.path).map_err(|e| format!("无法打开文件 {}: {e}", file.name))?;
            f.seek(SeekFrom::Start(offset)).ok();

            let mut buf = vec![0u8; Protocol::BUFFER_SIZE];
            let mut remaining = file.size - offset;
            while remaining > 0 {
                if canceled.load(Ordering::SeqCst) {
                    return Err("已取消".to_string());
                }
                while paused.load(Ordering::SeqCst) && !canceled.load(Ordering::SeqCst) {
                    thread::sleep(Duration::from_millis(200));
                }
                if canceled.load(Ordering::SeqCst) {
                    return Err("已取消".to_string());
                }
                let n = f.read(&mut buf).map_err(|e| format!("读取文件失败: {e}"))?;
                if n == 0 {
                    break;
                }
                let write_len = n.min(remaining as usize);
                stream.write_all(&buf[..write_len]).map_err(|e| format!("发送数据失败: {e}"))?;
                remaining -= write_len as u64;
                transferred += write_len as u64;

                let mut p = progress.lock().unwrap();
                p.current_file = file.name.clone();
                p.file_index = (i + 1) as u32;
                p.transferred_bytes = transferred;
                if let Some(start) = *transfer_start.lock().unwrap() {
                    let elapsed = start.elapsed().as_secs_f64();
                    if elapsed > 0.0 {
                        let speed = (transferred - start_offset) as f64 / elapsed;
                        p.speed_bps = speed;
                        if speed > 0.0 {
                            p.eta_seconds = ((total - transferred) as f64 / speed) as u64;
                        }
                    }
                }
            }
            stream.flush().ok();
        }

        // 等待 ACK
        let ack = Protocol::read_text(&mut stream).map_err(|e| format!("读取 ACK 失败: {e}"))?;
        if ack != Protocol::RESP_ACK {
            return Err(format!("对端确认异常: {ack}"));
        }
    }

    // 等待 DONE
    let _ = Protocol::read_text(&mut stream);
    *client_socket.lock().unwrap() = None;
    Ok(())
}

fn handle_receive_session(
    mut stream: TcpStream,
    _sessions: Arc<Mutex<Vec<TcpStream>>>,
    progress: Arc<Mutex<TransferProgress>>,
    incoming: Arc<Mutex<Option<IncomingRequest>>>,
    responder: Arc<Mutex<Option<Box<dyn FnOnce(bool) + Send>>>>,
    canceled: Arc<AtomicBool>,
    log_repo: Arc<Mutex<crate::log_repo::LogRepository>>,
    transfer_start: Arc<Mutex<Option<Instant>>>,
    save_path: Arc<Mutex<String>>,
) {
    // 读取请求头
    let header = match Protocol::read_json(&mut stream) {
        Ok(h) => h,
        Err(_) => return,
    };
    if header.get("app").and_then(|v| v.as_str()) != Some(Protocol::APP_ID) {
        return;
    }
    let peer_name = header.get("from").and_then(|v| v.as_str()).unwrap_or("未知").to_string();
    let total = header.get("total").and_then(|v| v.as_u64()).unwrap_or(0);
    let tid = header.get("transferId").and_then(|v| v.as_str()).unwrap_or("legacy")
        .chars().filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_').take(64).collect::<String>();
    let files: Vec<(String, u64)> = header.get("files")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|o| {
            let n = o.get("name").and_then(|v| v.as_str()).unwrap_or("file").to_string();
            let s = o.get("size").and_then(|v| v.as_u64()).unwrap_or(0);
            Some((n, s))
        }).collect())
        .unwrap_or_default();

    let file_count = files.len() as u32;
    let peer_ip = stream.peer_addr().map(|a| a.ip().to_string()).unwrap_or_default();

    // 已有进行中的传输或未处理的请求：直接拒绝。
    // 注意：每个锁必须在独立作用域内获取后立即释放，绝不能在一个表达式里连续
    // 持有多个锁（guard 生命周期会延长到整个 let 语句），否则与 respond_incoming
    // 的 "responder→incoming" 加锁顺序相反会形成死锁。
    let busy;
    {
        busy = progress.lock().unwrap().active;
    }
    let busy = busy || { incoming.lock().unwrap().is_some() };
    let busy = busy || { responder.lock().unwrap().is_some() };
    if busy {
        let _ = Protocol::write_json(&mut stream, &serde_json::json!({"status": Protocol::RESP_REJECT}));
        return;
    }

    // 设置传入请求，等待 UI 通过 respond_incoming 决定接受/拒绝
    let request = IncomingRequest {
        id: chrono::Utc::now().timestamp_millis() as u64,
        from_name: peer_name.clone(),
        from_ip: peer_ip.clone(),
        file_count,
        total_bytes: total,
    };
    // 先注册 responder，再设置 incoming，避免 UI 的 respond_incoming 在两者之间
    // 触发时取不到 responder 而丢掉"接受"决定（会造成 handler 空等直到超时）
    let (tx, rx) = std::sync::mpsc::channel::<bool>();
    *responder.lock().unwrap() = Some(Box::new(move |accept: bool| {
        let _ = tx.send(accept);
    }));
    *incoming.lock().unwrap() = Some(request);
    // 发送端最多等 120 秒，这里 110 秒内必须给出响应
    let decision = rx.recv_timeout(Duration::from_millis(110_000)).unwrap_or(false);
    *incoming.lock().unwrap() = None;

    if !decision {
        let _ = Protocol::write_json(&mut stream, &serde_json::json!({"status": Protocol::RESP_REJECT}));
        return;
    }

    // 已接受，进入接收流程；结束时统一收尾（进度 + 日志）
    let result = receive_files(&mut stream, &tid, &files, total, &peer_name, &progress, &canceled, &transfer_start, &save_path);
    let duration_ms = transfer_start.lock().unwrap().map(|t| t.elapsed().as_millis() as u64).unwrap_or(0);
    {
        let mut p = progress.lock().unwrap();
        p.active = false;
        match &result {
            Ok(()) => {
                p.status = TransferStatus::Done;
            }
            Err(e) => {
                p.status = if canceled.load(Ordering::SeqCst) {
                    TransferStatus::Canceled
                } else {
                    TransferStatus::Failed
                };
                p.error = Some(e.clone());
            }
        }
    }
    log_repo.lock().unwrap().add(TransferLog {
        time_millis: chrono::Utc::now().timestamp_millis() as u64,
        outgoing: false,
        peer_name: peer_name.clone(),
        file_summary: format::summarize_files(&files.iter().map(|f| f.0.clone()).collect::<Vec<_>>()),
        size_bytes: total,
        success: result.is_ok(),
        result_text: match &result {
            Ok(()) => "成功".to_string(),
            Err(e) => format!("失败: {e}"),
        },
        duration_ms,
        avg_speed_bps: 0.0,
    });
}

/// 接收文件数据：断点续传（按 transferId 的 .part 临时文件），收满后移动到保存目录
fn receive_files(
    stream: &mut TcpStream,
    tid: &str,
    files: &[(String, u64)],
    total: u64,
    peer_name: &str,
    progress: &Arc<Mutex<TransferProgress>>,
    canceled: &Arc<AtomicBool>,
    transfer_start: &Arc<Mutex<Option<Instant>>>,
    save_path: &Arc<Mutex<String>>,
) -> Result<(), String> {
    let tmp = FileIO::incoming_dir();
    let offsets = compute_offsets(&tmp, tid, files);
    save_session_meta(&tmp, tid, files);

    Protocol::write_json(stream, &serde_json::json!({
        "status": Protocol::RESP_ACCEPT,
        "offsets": offsets,
    })).map_err(|e| format!("发送接受响应失败: {e}"))?;

    // 数据阶段：5 分钟无数据判超时
    let _ = stream.set_read_timeout(Some(Duration::from_millis(Protocol::DATA_TIMEOUT_MS)));
    *transfer_start.lock().unwrap() = Some(Instant::now());

    let mut transferred = offsets.iter().sum::<u64>();
    let start_offset = transferred;
    *progress.lock().unwrap() = TransferProgress {
        show: true,
        active: true,
        direction: Direction::Receive,
        peer_name: peer_name.to_string(),
        status: TransferStatus::Transferring,
        current_file: String::new(),
        file_index: 0,
        file_count: files.len() as u32,
        total_bytes: total,
        transferred_bytes: transferred,
        speed_bps: 0.0,
        eta_seconds: 0,
        error: None,
    };

    for (i, (hname, hsize)) in files.iter().enumerate() {
        if canceled.load(Ordering::SeqCst) {
            return Err("已取消".to_string());
        }
        let meta = Protocol::read_json(stream).map_err(|e| format!("读取文件元信息失败: {e}"))?;
        let raw_name = meta.get("name").and_then(|v| v.as_str()).unwrap_or(hname);
        // 只取文件名部分，防止路径穿越
        let name = PathBuf::from(raw_name)
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| format!("file_{i}"));
        let size = meta.get("size").and_then(|v| v.as_u64()).unwrap_or(*hsize);
        let offset = meta.get("offset").and_then(|v| v.as_u64()).unwrap_or(0).min(size);

        let part = tmp.join(format!("{tid}_{i}.part"));
        if offset < size {
            let mut f = OpenOptions::new().read(true).write(true).create(true).open(&part)
                .map_err(|e| format!("无法创建临时文件: {e}"))?;
            // 截掉 offset 之后可能存在的脏数据
            f.set_len(offset).map_err(|e| format!("临时文件截断失败: {e}"))?;
            f.seek(SeekFrom::Start(offset)).ok();

            let mut buf = vec![0u8; Protocol::BUFFER_SIZE];
            let mut remaining = size - offset;
            while remaining > 0 {
                if canceled.load(Ordering::SeqCst) {
                    return Err("已取消".to_string());
                }
                let want = (buf.len() as u64).min(remaining) as usize;
                let n = stream.read(&mut buf[..want]).map_err(|e| format!("接收数据失败: {e}"))?;
                if n == 0 {
                    return Err("连接中断".to_string());
                }
                f.write_all(&buf[..n]).map_err(|e| format!("写入文件失败: {e}"))?;
                remaining -= n as u64;
                transferred += n as u64;

                let mut p = progress.lock().unwrap();
                p.current_file = name.clone();
                p.file_index = (i + 1) as u32;
                p.transferred_bytes = transferred;
                if let Some(start) = *transfer_start.lock().unwrap() {
                    let elapsed = start.elapsed().as_secs_f64();
                    if elapsed > 0.0 {
                        let speed = (transferred - start_offset) as f64 / elapsed;
                        p.speed_bps = speed;
                        if speed > 0.0 {
                            p.eta_seconds = ((total - transferred) as f64 / speed) as u64;
                        }
                    }
                }
            }
        }

        // 收满：移动到保存目录并删除临时文件
        let save_dir = save_path.lock().unwrap().clone();
        FileIO::ensure_dir(&save_dir).map_err(|e| format!("无法创建保存目录: {e}"))?;
        let dest = FileIO::available_path(&save_dir, &name);
        if part.exists() {
            move_file(&part, &dest).map_err(|e| format!("保存文件失败: {e}"))?;
        } else {
            // 0 字节文件：直接创建空文件
            File::create(&dest).map_err(|e| format!("保存文件失败: {e}"))?;
        }
        Protocol::write_frame(stream, Protocol::RESP_ACK.as_bytes())
            .map_err(|e| format!("发送 ACK 失败: {e}"))?;
        eprintln!("[handler] file {i} done, ACK sent");
    }

    Protocol::write_frame(stream, Protocol::RESP_DONE.as_bytes())
        .map_err(|e| format!("发送 DONE 失败: {e}"))?;
    let _ = fs::remove_file(tmp.join(format!("{tid}.json")));
    Ok(())
}

/// 计算各文件已接收字节：会话元信息与本次请求一致时取 .part 长度，否则清掉旧会话
fn compute_offsets(tmp: &std::path::Path, tid: &str, files: &[(String, u64)]) -> Vec<u64> {
    let meta_path = tmp.join(format!("{tid}.json"));
    if let Ok(text) = fs::read_to_string(&meta_path) {
        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) {
            if let Some(arr) = json.get("files").and_then(|v| v.as_array()) {
                let matches = arr.len() == files.len() && arr.iter().enumerate().all(|(i, o)| {
                    o.get("name").and_then(|v| v.as_str()) == Some(files[i].0.as_str())
                        && o.get("size").and_then(|v| v.as_u64()) == Some(files[i].1)
                });
                if matches {
                    return files.iter().enumerate().map(|(i, (_, size))| {
                        let part = tmp.join(format!("{tid}_{i}.part"));
                        fs::metadata(&part).map(|m| m.len().min(*size)).unwrap_or(0)
                    }).collect();
                }
            }
        }
    }
    // 会话信息不匹配：清理旧临时文件
    if let Ok(entries) = fs::read_dir(tmp) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with(&format!("{tid}_")) || name == format!("{tid}.json") {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
    vec![0u64; files.len()]
}

/// 保存会话元信息，供断点续传匹配
fn save_session_meta(tmp: &std::path::Path, tid: &str, files: &[(String, u64)]) {
    let arr: Vec<serde_json::Value> = files.iter()
        .map(|(n, s)| serde_json::json!({"name": n, "size": s}))
        .collect();
    let _ = fs::write(
        tmp.join(format!("{tid}.json")),
        serde_json::json!({"files": arr}).to_string(),
    );
}

/// 移动文件：优先 rename，跨盘失败时退回复制 + 删除
fn move_file(src: &std::path::Path, dst: &std::path::Path) -> std::io::Result<()> {
    match fs::rename(src, dst) {
        Ok(()) => Ok(()),
        Err(_) => {
            fs::copy(src, dst)?;
            fs::remove_file(src)
        }
    }
}
