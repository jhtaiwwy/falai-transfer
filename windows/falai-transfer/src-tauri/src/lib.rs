mod protocol;
mod format;
mod discovery;
mod transfer_models;
mod transfer_manager;
mod file_io;
mod log_repo;
mod commands;

use commands::register_commands;
use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    register_commands(tauri::Builder::default())
        .plugin(tauri_plugin_fs::init())
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }

            let state = app.state::<commands::AppState>();
            state.transfer.start_server();
            let name = state.device_name.lock().unwrap().clone();
            let port = state.transfer.server_port.load(std::sync::atomic::Ordering::SeqCst);
            if port > 0 {
                state.discovery.start(name, port);
            }
            file_io::FileIO::cleanup_stale_temp();

            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { .. } = event {
                let state = window.state::<commands::AppState>();
                state.discovery.stop();
                state.transfer.stop_server();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}