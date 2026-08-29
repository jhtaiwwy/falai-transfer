/// 字节格式化
pub fn format_bytes(bytes: u64) -> String {
    if bytes < 1024 {
        format!("{bytes} B")
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else if bytes < 1024 * 1024 * 1024 {
        format!("{:.1} MB", bytes as f64 / 1024.0 / 1024.0)
    } else {
        format!("{:.2} GB", bytes as f64 / 1024.0 / 1024.0 / 1024.0)
    }
}

/// 速度格式化
pub fn format_speed(bps: f64) -> String {
    format!("{}/s", format_bytes(bps as u64))
}

/// 预计剩余时间格式化
pub fn format_eta(seconds: u64) -> String {
    if seconds <= 0 {
        "即将完成".to_string()
    } else if seconds < 60 {
        format!("约 {seconds} 秒")
    } else if seconds < 3600 {
        format!("约 {} 分 {} 秒", seconds / 60, seconds % 60)
    } else {
        format!("约 {} 小时", seconds / 3600)
    }
}

/// 持续时间格式化
pub fn format_duration(ms: u64) -> String {
    if ms < 1000 {
        format!("{ms}ms")
    } else if ms < 60_000 {
        format!("{:.1}秒", ms as f64 / 1000.0)
    } else {
        format!("{}分{}秒", ms / 60_000, (ms % 60_000) / 1000)
    }
}

/// 文件列表摘要
pub fn summarize_files(names: &[String]) -> String {
    match names.len() {
        0 => "-".to_string(),
        1 => names[0].clone(),
        _ => format!("{} 等{}个文件", names[0], names.len()),
    }
}