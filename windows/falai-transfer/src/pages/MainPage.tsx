import { useState, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { Device, TransferProgress, IncomingRequest, ResolvedFile } from "../types";
import { formatBytes } from "../types";

interface Props {
  devices: Device[];
  onRefresh: () => void;
  incoming: IncomingRequest | null;
  progress: TransferProgress | null;
}

export function MainPage({ devices, onRefresh, incoming, progress }: Props) {
  const [selectedDevice, setSelectedDevice] = useState<Device | null>(null);
  const [selectedFiles, setSelectedFiles] = useState<ResolvedFile[]>([]);
  const [manualIp, setManualIp] = useState("");
  const [sending, setSending] = useState(false);

  const handlePickFiles = useCallback(async () => {
    try {
      const files = await invoke<ResolvedFile[]>("pick_files");
      if (files.length > 0) {
        setSelectedFiles(files);
      }
    } catch (e) {
      console.error("pick_files failed:", e);
    }
  }, []);

  const handleSend = useCallback(async () => {
    if (!selectedDevice || selectedFiles.length === 0) return;
    setSending(true);
    try {
      await invoke("send_files", {
        ip: selectedDevice.ip,
        port: selectedDevice.tcp_port,
        peerName: selectedDevice.name,
        files: selectedFiles.map((f) => ({
          name: f.name,
          size: f.size,
          path: f.path,
        })),
      });
      setSelectedFiles([]);
    } catch (e) {
      console.error("send_files failed:", e);
    }
    setSending(false);
  }, [selectedDevice, selectedFiles]);

  const handleAddManual = useCallback(async () => {
    if (!manualIp.trim()) return;
    try {
      await invoke("add_manual_device", { ip: manualIp.trim() });
      setManualIp("");
      onRefresh();
    } catch (e) {
      console.error("add_manual_device failed:", e);
    }
  }, [manualIp, onRefresh]);

  const handleRespond = useCallback(
    async (accept: boolean) => {
      if (!incoming) return;
      try {
        await invoke("respond_incoming", {
          accept,
          trust: false,
          ip: incoming.from_ip,
        });
      } catch (e) {
        console.error("respond_incoming failed:", e);
      }
    },
    [incoming]
  );

  // 使用发现的设备（后端已过滤本机）
  const visibleDevices = devices;

  return (
    <div>
      <div className="page-header">
        <h2 className="page-title">设备列表</h2>
        <p className="page-subtitle">同一局域网内的设备将自动发现</p>
      </div>

      {/* 传入请求弹窗 */}
      {incoming && (
        <div className="incoming-overlay" onClick={() => handleRespond(false)}>
          <div className="incoming-dialog" onClick={(e) => e.stopPropagation()}>
            <h3>📥 接收文件</h3>
            <p>
              <strong>{incoming.from_name}</strong> 想发送{" "}
              <strong>{incoming.file_count}</strong> 个文件（
              {formatBytes(incoming.total_bytes)}）
            </p>
            <div className="incoming-actions">
              <button
                className="btn btn-outline"
                onClick={() => handleRespond(false)}
              >
                拒绝
              </button>
              <button
                className="btn btn-primary"
                onClick={() => handleRespond(true)}
              >
                接受
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 设备列表 */}
      {visibleDevices.length === 0 ? (
        <div className="empty-state">
          <div className="empty-state-icon">📡</div>
          <div className="empty-state-text">
            扫描中... 请确保其他设备已打开「发来」
          </div>
        </div>
      ) : (
        <div className="device-grid">
          {visibleDevices.map((device) => (
            <div
              key={device.ip}
              className={`device-card ${
                selectedDevice?.ip === device.ip ? "selected" : ""
              }`}
              onClick={() => {
                setSelectedDevice(device);
                if (selectedFiles.length > 0) {
                  handleSend();
                }
              }}
            >
              <div className="device-name">
                {device.os === "android" ? "📱 " : device.os === "harmony" ? "📱 " : "💻 "}
                {device.name}
              </div>
              <div className="device-info">{device.ip}</div>
              <span className="device-os">{device.os}</span>
            </div>
          ))}
        </div>
      )}

      {/* 选中设备后的操作 */}
      {selectedDevice && (
        <div className="card" style={{ marginTop: 16 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 12 }}>
            <strong>已选择: {selectedDevice.name}</strong>
            <button
              className="btn btn-sm btn-outline"
              onClick={() => setSelectedDevice(null)}
            >
              取消
            </button>
          </div>

          {/* 已选文件 */}
          {selectedFiles.length > 0 && (
            <div className="file-list" style={{ marginBottom: 12 }}>
              {selectedFiles.map((f, i) => (
                <div key={i} className="file-item">
                  <span className="file-name">📄 {f.name}</span>
                  <span className="file-size">{formatBytes(f.size)}</span>
                </div>
              ))}
            </div>
          )}

          <div style={{ display: "flex", gap: 8 }}>
            <button className="btn btn-outline" onClick={handlePickFiles}>
              📁 选择文件
            </button>
            <button
              className="btn btn-primary"
              onClick={handleSend}
              disabled={selectedFiles.length === 0 || sending || !!progress?.active}
            >
              {sending ? "发送中..." : "📤 发送"}
            </button>
          </div>
        </div>
      )}

      {/* 手动添加 */}
      <div className="card" style={{ marginTop: 16 }}>
        <div className="form-label">手动添加设备</div>
        <div className="manual-add">
          <input
            className="form-input"
            placeholder="输入 IP 地址"
            value={manualIp}
            onChange={(e) => setManualIp(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && handleAddManual()}
          />
          <button
            className="btn btn-primary btn-sm"
            onClick={handleAddManual}
            disabled={!manualIp.trim()}
          >
            添加
          </button>
        </div>
      </div>
    </div>
  );
}