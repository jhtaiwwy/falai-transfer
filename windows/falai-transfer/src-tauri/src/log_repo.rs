use std::fs;
use std::path::PathBuf;

use crate::transfer_models::TransferLog;

/// 传输日志持久化（JSON 文件）
pub struct LogRepository {
    path: PathBuf,
}

impl LogRepository {
    pub fn new() -> Self {
        let path = dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("falai-transfer")
            .join("logs.json");
        Self { path }
    }

    /// 读取所有日志
    pub fn load(&self) -> Vec<TransferLog> {
        match fs::read_to_string(&self.path) {
            Ok(content) => {
                serde_json::from_str(&content).unwrap_or_default()
            }
            Err(_) => Vec::new(),
        }
    }

    /// 追加一条日志
    pub fn add(&self, log: TransferLog) {
        let mut logs = self.load();
        logs.push(log);
        // 最多保留 200 条
        if logs.len() > 200 {
            logs = logs.split_off(logs.len() - 200);
        }
        self.save(&logs);
    }

    /// 删除单条日志
    pub fn delete(&self, index: usize) {
        let mut logs = self.load();
        if index < logs.len() {
            logs.remove(index);
            self.save(&logs);
        }
    }

    /// 清空所有日志
    pub fn clear(&self) {
        let _ = fs::remove_file(&self.path);
    }

    fn save(&self, logs: &[TransferLog]) {
        if let Some(parent) = self.path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_string_pretty(logs) {
            let _ = fs::write(&self.path, json);
        }
    }
}