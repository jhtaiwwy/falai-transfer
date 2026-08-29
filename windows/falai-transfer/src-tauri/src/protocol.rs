use std::io::{self, Read, Write};

/// 通信协议常量与帧读写工具
pub struct Protocol;

impl Protocol {
    // 应用标识
    pub const APP_ID: &'static str = "FT";
    // 协议版本
    pub const VERSION: u32 = 1;
    // UDP 广播发现端口
    pub const DISCOVERY_PORT: u16 = 47800;
    // TCP 文件传输起始端口
    pub const TRANSFER_PORT: u16 = 47801;
    // 端口尝试数量（47801~47811）
    pub const PORT_TRY_COUNT: u32 = 11;
    // 广播间隔 2 秒
    pub const BROADCAST_INTERVAL_MS: u64 = 2000;
    // 6 秒无心跳判离线
    pub const OFFLINE_TIMEOUT_MS: u64 = 6000;
    // 32KB 流式传输块
    pub const BUFFER_SIZE: usize = 32 * 1024;
    // 请求头超时 30 秒
    pub const HEADER_TIMEOUT_MS: u64 = 30_000;
    // 数据传输超时 5 分钟
    pub const DATA_TIMEOUT_MS: u64 = 300_000;
    // 客户端等确认超时 120 秒
    pub const ACCEPT_TIMEOUT_MS: u64 = 120_000;

    // 响应状态
    pub const RESP_ACCEPT: &'static str = "ACCEPT";
    pub const RESP_REJECT: &'static str = "REJECT";
    pub const RESP_ACK: &'static str = "ACK";
    pub const RESP_DONE: &'static str = "DONE";

    /// 写入帧：[4字节大端长度][payload]
    pub fn write_frame<W: Write>(writer: &mut W, payload: &[u8]) -> io::Result<()> {
        let len = payload.len() as u32;
        writer.write_all(&len.to_be_bytes())?;
        writer.write_all(payload)?;
        writer.flush()?;
        Ok(())
    }

    /// 写入 JSON 帧
    pub fn write_json<W: Write>(writer: &mut W, value: &serde_json::Value) -> io::Result<()> {
        let json = serde_json::to_string(value)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        Self::write_frame(writer, json.as_bytes())
    }

    /// 读取帧：[4字节大端长度][payload]
    pub fn read_frame<R: Read>(reader: &mut R, max_len: u32) -> io::Result<Vec<u8>> {
        let mut len_buf = [0u8; 4];
        reader.read_exact(&mut len_buf)?;
        let len = u32::from_be_bytes(len_buf);
        if len == 0 || len > max_len {
            return Err(io::Error::new(io::ErrorKind::InvalidData, format!("非法帧长度: {len}")));
        }
        let mut buf = vec![0u8; len as usize];
        reader.read_exact(&mut buf)?;
        Ok(buf)
    }

    /// 读取 JSON 帧
    pub fn read_json<R: Read>(reader: &mut R) -> io::Result<serde_json::Value> {
        let data = Self::read_frame(reader, 4 * 1024 * 1024)?;
        Ok(serde_json::from_slice(&data)?)
    }

    /// 读取文本帧
    pub fn read_text<R: Read>(reader: &mut R) -> io::Result<String> {
        let data = Self::read_frame(reader, 4 * 1024 * 1024)?;
        Ok(String::from_utf8_lossy(&data).to_string())
    }
}