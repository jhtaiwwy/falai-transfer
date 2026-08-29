import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { TransferLog } from "../types";
import { formatBytes, formatTime, formatDuration } from "../types";

export function LogPage() {
  const [logs, setLogs] = useState<TransferLog[]>([]);

  const loadLogs = useCallback(async () => {
    try {
      const list = await invoke<TransferLog[]>("get_logs");
      setLogs(list);
    } catch (e) {
      console.error("get_logs failed:", e);
    }
  }, []);

  const handleDelete = useCallback(
    async (index: number) => {
      try {
        await invoke("delete_log", { index });
        loadLogs();
      } catch (e) {
        console.error("delete_log failed:", e);
      }
    },
    [loadLogs]
  );

  const handleClear = useCallback(async () => {
    try {
      await invoke("clear_logs");
      loadLogs();
    } catch (e) {
      console.error("clear_logs failed:", e);
    }
  }, [loadLogs]);

  useEffect(() => {
    loadLogs();
  }, [loadLogs]);

  return (
    <div>
      <div className="page-header" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <div>
          <h2 className="page-title">传输日志</h2>
          <p className="page-subtitle">最近的传输记录</p>
        </div>
        {logs.length > 0 && (
          <button className="btn btn-sm btn-outline" onClick={handleClear}>
            🗑 清空
          </button>
        )}
      </div>

      {logs.length === 0 ? (
        <div className="empty-state">
          <div className="empty-state-icon">📋</div>
          <div className="empty-state-text">暂无传输记录</div>
        </div>
      ) : (
        <div className="card" style={{ padding: 0, overflow: "hidden" }}>
          <table className="log-table">
            <thead>
              <tr>
                <th>时间</th>
                <th>方向</th>
                <th>对方</th>
                <th>文件</th>
                <th>大小</th>
                <th>耗时</th>
                <th>结果</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {logs.map((log, i) => (
                <tr key={i}>
                  <td style={{ whiteSpace: "nowrap" }}>
                    {formatTime(log.time_millis)}
                  </td>
                  <td>{log.outgoing ? "📤 发送" : "📥 接收"}</td>
                  <td>{log.peer_name}</td>
                  <td style={{ maxWidth: 150, overflow: "hidden", textOverflow: "ellipsis" }}>
                    {log.file_summary}
                  </td>
                  <td>{formatBytes(log.size_bytes)}</td>
                  <td>{formatDuration(log.duration_ms)}</td>
                  <td>
                    <span
                      className={`status-tag ${log.success ? "success" : "fail"}`}
                    >
                      {log.success ? "成功" : log.result_text}
                    </span>
                  </td>
                  <td>
                    <button
                      className="btn btn-sm btn-outline"
                      onClick={() => handleDelete(i)}
                      style={{ padding: "2px 6px", fontSize: 11 }}
                    >
                      ✕
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}