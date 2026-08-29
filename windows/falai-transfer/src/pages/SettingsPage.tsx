import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { AppSettings } from "../types";

export function SettingsPage() {
  const [settings, setSettings] = useState<AppSettings>({
    device_name: "",
    save_path: "",
    whitelist: [],
  });
  const [saved, setSaved] = useState(false);

  const loadSettings = useCallback(async () => {
    try {
      const s = await invoke<AppSettings>("get_settings");
      setSettings(s);
    } catch (e) {
      console.error("get_settings failed:", e);
    }
  }, []);

  const handleSave = useCallback(async () => {
    try {
      await invoke("update_settings", { settings });
      setSaved(true);
      setTimeout(() => setSaved(false), 2000);
    } catch (e) {
      console.error("update_settings failed:", e);
    }
  }, [settings]);

  useEffect(() => {
    loadSettings();
  }, [loadSettings]);

  return (
    <div>
      <div className="page-header">
        <h2 className="page-title">设置</h2>
        <p className="page-subtitle">配置应用参数</p>
      </div>

      <div className="card settings-form">
        <div className="form-group">
          <label className="form-label">设备名称</label>
          <input
            className="form-input"
            value={settings.device_name}
            onChange={(e) =>
              setSettings({ ...settings, device_name: e.target.value })
            }
            placeholder="输入设备名称"
          />
        </div>

        <div className="form-group">
          <label className="form-label">文件保存路径</label>
          <input
            className="form-input"
            value={settings.save_path}
            onChange={(e) =>
              setSettings({ ...settings, save_path: e.target.value })
            }
            placeholder="C:\Users\...\Downloads\发来"
          />
        </div>

        <div className="form-group">
          <label className="form-label">白名单</label>
          <p style={{ fontSize: 12, color: "var(--text-secondary)", marginBottom: 8 }}>
            白名单设备发送文件时将自动接收，无需确认
          </p>
          {settings.whitelist.length === 0 ? (
            <p style={{ fontSize: 12, color: "var(--text-secondary)" }}>
              暂无白名单设备
            </p>
          ) : (
            <div>
              {settings.whitelist.map((ip, i) => (
                <div
                  key={i}
                  style={{
                    display: "flex",
                    justifyContent: "space-between",
                    alignItems: "center",
                    padding: "4px 0",
                    fontSize: 13,
                  }}
                >
                  <span>{ip}</span>
                  <button
                    className="btn btn-sm btn-outline"
                    onClick={() => {
                      const newList = settings.whitelist.filter((_, j) => j !== i);
                      setSettings({ ...settings, whitelist: newList });
                    }}
                    style={{ padding: "2px 6px", fontSize: 11 }}
                  >
                    ✕
                  </button>
                </div>
              ))}
            </div>
          )}
        </div>

        <button className="btn btn-primary" onClick={handleSave}>
          {saved ? "✅ 已保存" : "💾 保存设置"}
        </button>
      </div>
    </div>
  );
}