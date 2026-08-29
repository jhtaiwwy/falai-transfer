import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import "./App.css";
import { MainPage } from "./pages/MainPage";
import { TransferPage } from "./pages/TransferPage";
import { LogPage } from "./pages/LogPage";
import { SettingsPage } from "./pages/SettingsPage";
import type { Device, TransferProgress, IncomingRequest } from "./types";

type Page = "devices" | "transfer" | "logs" | "settings";

function App() {
  const [currentPage, setCurrentPage] = useState<Page>("devices");
  const [devices, setDevices] = useState<Device[]>([]);
  const [progress, setProgress] = useState<TransferProgress | null>(null);
  const [incoming, setIncoming] = useState<IncomingRequest | null>(null);

  const refreshDevices = useCallback(async () => {
    try {
      const list = await invoke<Device[]>("get_devices");
      setDevices(list);
    } catch (e) {
      console.error("get_devices failed:", e);
    }
  }, []);

  const refreshProgress = useCallback(async () => {
    try {
      const p = await invoke<TransferProgress>("get_transfer_progress");
      setProgress(p);
    } catch (e) {
      console.error("get_transfer_progress failed:", e);
    }
  }, []);

  const refreshIncoming = useCallback(async () => {
    try {
      const req = await invoke<IncomingRequest | null>("get_incoming");
      setIncoming(req);
    } catch (e) {
      console.error("get_incoming failed:", e);
    }
  }, []);

  useEffect(() => {
    const init = async () => {
      try {
        await invoke("start_discovery");
        await invoke("start_server");
      } catch (e) {
        console.error("init failed:", e);
      }
    };
    init();
  }, []);

  useEffect(() => {
    refreshDevices();
    const devInterval = setInterval(refreshDevices, 3000);
    const progInterval = setInterval(refreshProgress, 500);
    const incInterval = setInterval(refreshIncoming, 1000);
    return () => {
      clearInterval(devInterval);
      clearInterval(progInterval);
      clearInterval(incInterval);
    };
  }, [refreshDevices, refreshProgress, refreshIncoming]);

  return (
    <div className="app-container">
      <aside className="sidebar">
        <div className="sidebar-header">
          <h1 className="app-title">发来</h1>
          <p className="app-subtitle">文件互传</p>
        </div>
        <nav className="sidebar-nav">
          <button
            className={`nav-item ${currentPage === "devices" ? "active" : ""}`}
            onClick={() => setCurrentPage("devices")}
          >
            <span className="nav-icon">📡</span>
            <span className="nav-label">设备</span>
          </button>
          <button
            className={`nav-item ${currentPage === "transfer" ? "active" : ""}`}
            onClick={() => setCurrentPage("transfer")}
          >
            <span className="nav-icon">📤</span>
            <span className="nav-label">传输</span>
            {progress?.show && <span className="badge">●</span>}
          </button>
          <button
            className={`nav-item ${currentPage === "logs" ? "active" : ""}`}
            onClick={() => setCurrentPage("logs")}
          >
            <span className="nav-icon">📋</span>
            <span className="nav-label">日志</span>
          </button>
          <button
            className={`nav-item ${currentPage === "settings" ? "active" : ""}`}
            onClick={() => setCurrentPage("settings")}
          >
            <span className="nav-icon">⚙️</span>
            <span className="nav-label">设置</span>
          </button>
        </nav>
        <div className="sidebar-footer">
          <span className="local-ip">
            {devices.length > 0 ? "已连接" : "等待设备..."}
          </span>
        </div>
      </aside>
      <main className="main-content">
        {currentPage === "devices" && (
          <MainPage
            devices={devices}
            onRefresh={refreshDevices}
            incoming={incoming}
            progress={progress}
          />
        )}
        {currentPage === "transfer" && (
          <TransferPage progress={progress} onRefresh={refreshProgress} />
        )}
        {currentPage === "logs" && <LogPage />}
        {currentPage === "settings" && <SettingsPage />}
      </main>
    </div>
  );
}

export default App;