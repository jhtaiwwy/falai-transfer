import { useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { TransferProgress } from "../types";
import { formatBytes, formatSpeed, formatEta } from "../types";

interface Props {
  progress: TransferProgress | null;
  onRefresh: () => void;
}

export function TransferPage({ progress, onRefresh }: Props) {
  const handlePause = useCallback(async () => {
    try {
      await invoke("pause_transfer");
    } catch (e) {
      console.error("pause_transfer failed:", e);
    }
  }, []);

  const handleResume = useCallback(async () => {
    try {
      await invoke("resume_transfer");
    } catch (e) {
      console.error("resume_transfer failed:", e);
    }
  }, []);

  const handleCancel = useCallback(async () => {
    try {
      await invoke("cancel_transfer");
    } catch (e) {
      console.error("cancel_transfer failed:", e);
    }
  }, []);

  // 没有活跃传输
  if (!progress || !progress.show) {
    return (
      <div>
        <div className="page-header">
          <h2 className="page-title">传输</h2>
          <p className="page-subtitle">查看和管理文件传输</p>
        </div>
        <div className="empty-state">
          <div className="empty-state-icon">📤</div>
          <div className="empty-state-text">没有进行中的传输</div>
        </div>
      </div>
    );
  }

  const pct =
    progress.total_bytes > 0
      ? Math.round((progress.transferred_bytes / progress.total_bytes) * 100)
      : 0;

  const statusClass =
    progress.status === "Transferring"
      ? "transferring"
      : progress.status === "Done"
        ? "done"
        : progress.status === "Failed" || progress.status === "Canceled" || progress.status === "Rejected"
          ? "failed"
          : progress.status === "Paused"
            ? "paused"
            : "";

  const statusText =
    progress.status === "Transferring"
      ? "传输中"
      : progress.status === "Done"
        ? "已完成"
        : progress.status === "Failed"
          ? "失败"
          : progress.status === "Canceled"
            ? "已取消"
            : progress.status === "Rejected"
              ? "已拒绝"
              : progress.status === "Paused"
                ? "已暂停"
                : "等待中";

  return (
    <div>
      <div className="page-header">
        <h2 className="page-title">传输</h2>
        <p className="page-subtitle">
          {progress.direction === "Send" ? "发送" : "接收"}给 {progress.peer_name}
        </p>
      </div>

      <div className="transfer-panel">
        <div className="transfer-info">
          <div>
            <strong>
              {progress.direction === "Send" ? "📤 发送" : "📥 接收"}到{" "}
              {progress.peer_name}
            </strong>
          </div>
          <span className={`transfer-status ${statusClass}`}>{statusText}</span>
        </div>

        <div style={{ marginBottom: 8 }}>
          <div style={{ fontSize: 13, color: "var(--text-secondary)", marginBottom: 4 }}>
            {progress.current_file || "准备中..."}
            {progress.file_count > 1 &&
              ` (${progress.file_index}/${progress.file_count})`}
          </div>
          <div className="progress-bar">
            <div
              className={`progress-fill ${progress.status === "Done" ? "done" : ""}`}
              style={{ width: `${pct}%` }}
            />
          </div>
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              fontSize: 12,
              color: "var(--text-secondary)",
            }}
          >
            <span>
              {formatBytes(progress.transferred_bytes)} /{" "}
              {formatBytes(progress.total_bytes)}
            </span>
            <span>{pct}%</span>
          </div>
        </div>

        {progress.status === "Transferring" && (
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              fontSize: 12,
              color: "var(--text-secondary)",
            }}
          >
            <span>{formatSpeed(progress.speed_bps)}</span>
            <span>{formatEta(progress.eta_seconds)}</span>
          </div>
        )}

        {progress.error && (
          <div
            style={{
              marginTop: 8,
              padding: 8,
              background: "rgba(239, 68, 68, 0.1)",
              borderRadius: 6,
              fontSize: 12,
              color: "var(--error)",
            }}
          >
            ❌ {progress.error}
          </div>
        )}

        {/* 操作按钮 */}
        <div style={{ display: "flex", gap: 8, marginTop: 16 }}>
          {progress.status === "Transferring" && (
            <button className="btn btn-outline" onClick={handlePause}>
              ⏸ 暂停
            </button>
          )}
          {progress.status === "Paused" && (
            <button className="btn btn-primary" onClick={handleResume}>
              ▶ 继续
            </button>
          )}
          {(progress.status === "Transferring" ||
            progress.status === "Paused") && (
            <button className="btn btn-danger" onClick={handleCancel}>
              ✕ 取消
            </button>
          )}
          {(progress.status === "Done" ||
            progress.status === "Failed" ||
            progress.status === "Canceled") && (
            <button className="btn btn-outline" onClick={onRefresh}>
              刷新
            </button>
          )}
        </div>
      </div>
    </div>
  );
}