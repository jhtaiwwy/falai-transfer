use serde::{Deserialize, Serialize};

/// 传输方向
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum Direction {
    Send,
    Receive,
}

/// 传输状态
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum TransferStatus {
    Waiting,
    Transferring,
    Paused,
    Done,
    Failed,
    Canceled,
    Rejected,
}

/// 传输进度
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferProgress {
    pub show: bool,
    pub active: bool,
    pub direction: Direction,
    pub peer_name: String,
    pub status: TransferStatus,
    pub current_file: String,
    pub file_index: u32,
    pub file_count: u32,
    pub total_bytes: u64,
    pub transferred_bytes: u64,
    pub speed_bps: f64,
    pub eta_seconds: u64,
    pub error: Option<String>,
}

impl Default for TransferProgress {
    fn default() -> Self {
        Self {
            show: false,
            active: false,
            direction: Direction::Send,
            peer_name: String::new(),
            status: TransferStatus::Waiting,
            current_file: String::new(),
            file_index: 0,
            file_count: 0,
            total_bytes: 0,
            transferred_bytes: 0,
            speed_bps: 0.0,
            eta_seconds: 0,
            error: None,
        }
    }
}

/// 待发送文件
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResolvedFile {
    pub name: String,
    pub size: u64,
    pub path: String,
}

/// 传入请求
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IncomingRequest {
    pub id: u64,
    pub from_name: String,
    pub from_ip: String,
    pub file_count: u32,
    pub total_bytes: u64,
}

/// 发现的设备
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    pub ip: String,
    pub name: String,
    pub os: String,
    pub tcp_port: u16,
    pub last_seen: u64,
    pub manual: bool,
}

/// 传输日志
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferLog {
    pub time_millis: u64,
    pub outgoing: bool,
    pub peer_name: String,
    pub file_summary: String,
    pub size_bytes: u64,
    pub success: bool,
    pub result_text: String,
    pub duration_ms: u64,
    pub avg_speed_bps: f64,
}

/// 应用设置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    pub device_name: String,
    pub save_path: String,
    pub whitelist: Vec<String>,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            device_name: std::env::var("COMPUTERNAME").unwrap_or_else(|_| "PC".to_string()),
            save_path: dirs::download_dir()
                .unwrap_or_else(|| std::path::PathBuf::from("C:\\Users\\Default\\Downloads"))
                .join("发来")
                .to_string_lossy()
                .to_string(),
            whitelist: Vec::new(),
        }
    }
}