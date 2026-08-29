use std::fs;
use std::io;
use std::path::PathBuf;

/// 文件操作工具
pub struct FileIO;

impl FileIO {
    /// 确保目录存在
    pub fn ensure_dir(path: &str) -> io::Result<()> {
        fs::create_dir_all(path)
    }

    /// 获取临时接收目录
    pub fn incoming_dir() -> PathBuf {
        let dir = std::env::temp_dir().join("falai_transfer").join("incoming");
        let _ = fs::create_dir_all(&dir);
        dir
    }

    /// 获取保存目录下的可用文件名（重名自动加 _1 _2 后缀）
    pub fn available_path(dir: &str, name: &str) -> PathBuf {
        let base = PathBuf::from(dir).join(name);
        if !base.exists() {
            return base;
        }
        let stem = base.file_stem().unwrap_or_default().to_string_lossy().to_string();
        let ext = base.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
        for i in 1..1000 {
            let candidate = PathBuf::from(dir).join(format!("{}_{}{}", stem, i, ext));
            if !candidate.exists() {
                return candidate;
            }
        }
        base
    }

    /// 清理超过 24 小时的临时文件
    pub fn cleanup_stale_temp() {
        let dir = Self::incoming_dir();
        if let Ok(entries) = fs::read_dir(&dir) {
            let cutoff = chrono::Utc::now().timestamp_millis() as u64 - 24 * 3600 * 1000;
            for entry in entries.flatten() {
                if let Ok(meta) = entry.metadata() {
                    if let Ok(modified) = meta.modified() {
                        if let Ok(duration) = modified.elapsed() {
                            if duration.as_millis() as u64 > cutoff {
                                let _ = fs::remove_file(entry.path());
                            }
                        }
                    }
                }
            }
        }
    }
}