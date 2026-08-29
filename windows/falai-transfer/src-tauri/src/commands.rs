use tauri::{Manager, State};

use crate::transfer_manager::TransferManager;
use crate::transfer_models::*;
use crate::discovery::DiscoveryService;
use crate::log_repo::LogRepository;

/// 应用状态
pub struct AppState {
    pub discovery: DiscoveryService,
    pub transfer: TransferManager,
    pub log_repo: LogRepository,
    pub device_name: std::sync::Mutex<String>,
    pub save_path: std::sync::Mutex<String>,
}

impl AppState {
    pub fn new() -> Self {
        let settings: AppSettings = AppSettings::default();
        Self {
            discovery: DiscoveryService::new(),
            transfer: TransferManager::new(),
            log_repo: LogRepository::new(),
            device_name: std::sync::Mutex::new(settings.device_name),
            save_path: std::sync::Mutex::new(settings.save_path),
        }
    }
}

// ========== 发现服务命令 ==========

#[tauri::command]
fn start_discovery(state: State<AppState>) -> Result<(), String> {
    let name = state.device_name.lock().unwrap().clone();
    let port = state.transfer.server_port.load(std::sync::atomic::Ordering::SeqCst);
    let port = if port > 0 { port } else { crate::protocol::Protocol::TRANSFER_PORT };
    state.discovery.start(name, port);
    Ok(())
}

#[tauri::command]
fn stop_discovery(state: State<AppState>) -> Result<(), String> {
    state.discovery.stop();
    Ok(())
}

#[tauri::command]
fn get_devices(state: State<AppState>) -> Result<Vec<Device>, String> {
    Ok(state.discovery.get_devices())
}

#[tauri::command]
fn add_manual_device(state: State<AppState>, ip: String) -> Result<bool, String> {
    Ok(state.discovery.add_manual_device(ip))
}

#[tauri::command]
fn get_local_ip() -> Result<String, String> {
    Ok(DiscoveryService::primary_ip())
}

// ========== 传输命令 ==========

#[tauri::command]
fn start_server(state: State<AppState>) -> Result<bool, String> {
    Ok(state.transfer.start_server())
}

#[tauri::command]
fn send_files(
    state: State<AppState>,
    ip: String,
    port: u16,
    peer_name: String,
    files: Vec<ResolvedFile>,
) -> Result<(), String> {
    state.transfer.send_files(&ip, port, &peer_name, files);
    Ok(())
}

#[tauri::command]
fn get_transfer_progress(state: State<AppState>) -> Result<TransferProgress, String> {
    Ok(state.transfer.get_progress())
}

#[tauri::command]
fn get_incoming(state: State<AppState>) -> Result<Option<IncomingRequest>, String> {
    Ok(state.transfer.get_incoming())
}

#[tauri::command]
fn respond_incoming(state: State<AppState>, accept: bool, trust: bool, ip: String) -> Result<(), String> {
    state.transfer.respond_incoming(accept, trust, &ip);
    Ok(())
}

#[tauri::command]
fn cancel_transfer(state: State<AppState>) -> Result<(), String> {
    state.transfer.cancel();
    Ok(())
}

#[tauri::command]
fn pause_transfer(state: State<AppState>) -> Result<(), String> {
    state.transfer.pause();
    Ok(())
}

#[tauri::command]
fn resume_transfer(state: State<AppState>) -> Result<(), String> {
    state.transfer.resume();
    Ok(())
}

// ========== 日志命令 ==========

#[tauri::command]
fn get_logs(state: State<AppState>) -> Result<Vec<TransferLog>, String> {
    Ok(state.transfer.get_logs())
}

#[tauri::command]
fn delete_log(state: State<AppState>, index: usize) -> Result<(), String> {
    state.transfer.delete_log(index);
    Ok(())
}

#[tauri::command]
fn clear_logs(state: State<AppState>) -> Result<(), String> {
    state.transfer.clear_logs();
    Ok(())
}

// ========== 设置命令 ==========

#[tauri::command]
fn get_settings(state: State<AppState>) -> Result<AppSettings, String> {
    Ok(AppSettings {
        device_name: state.device_name.lock().unwrap().clone(),
        save_path: state.save_path.lock().unwrap().clone(),
        whitelist: Vec::new(),
    })
}

#[tauri::command]
fn update_settings(state: State<AppState>, settings: AppSettings) -> Result<(), String> {
    state.transfer.set_save_path(&settings.save_path);
    *state.device_name.lock().unwrap() = settings.device_name;
    *state.save_path.lock().unwrap() = settings.save_path;
    Ok(())
}

// ========== 文件选择命令 ==========

#[tauri::command]
fn pick_files() -> Result<Vec<ResolvedFile>, String> {
    let files = rfd::FileDialog::new()
        .add_filter("所有文件", &["*"])
        .pick_files();

    let mut resolved = Vec::new();
    if let Some(paths) = files {
        for path in paths {
            if let Ok(meta) = std::fs::metadata(&path) {
                if let Some(name) = path.file_name() {
                    resolved.push(ResolvedFile {
                        name: name.to_string_lossy().to_string(),
                        size: meta.len(),
                        path: path.to_string_lossy().to_string(),
                    });
                }
            }
        }
    }
    Ok(resolved)
}

/// 注册所有 Tauri 命令
pub fn register_commands<R: tauri::Runtime>(builder: tauri::Builder<R>) -> tauri::Builder<R> {
    builder
        .manage(AppState::new())
        .invoke_handler(tauri::generate_handler![
            start_discovery,
            stop_discovery,
            get_devices,
            add_manual_device,
            get_local_ip,
            start_server,
            send_files,
            get_transfer_progress,
            get_incoming,
            respond_incoming,
            cancel_transfer,
            pause_transfer,
            resume_transfer,
            get_logs,
            delete_log,
            clear_logs,
            get_settings,
            update_settings,
            pick_files,
        ])
}