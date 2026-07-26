#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PC 端协议模拟对端 —— 用于安卓版自测（对应方案.md 第 4 节 v1.1 协议）。

用法：
  python pc_peer.py recv            # 广播自己 + 收文件到 ./recv_out（自动接受，支持断点续传）
  python pc_peer.py send <IP> <文件> [更多文件...]   # 向指定设备发文件（自动续传）

协议：UDP 47800 广播发现；TCP 47801 传输。
请求头带 transferId；响应帧为 JSON {status, offsets}；
单文件元信息带 offset，从断点处续传；接收方先写 .part 临时文件，收满后落盘。
"""
import hashlib
import json
import os
import socket
import struct
import sys
import threading
import time

APP_ID = "FT"
DISCOVERY_PORT = 47800
TRANSFER_PORT = 47801
NAME = "PC-测试机"


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("255.255.255.255", 1))
        return s.getsockname()[0]
    finally:
        s.close()


def broadcast_loop(stop):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    payload = json.dumps({"app": APP_ID, "name": NAME, "os": "pc",
                          "tcpPort": TRANSFER_PORT, "version": 1}).encode()
    while not stop.is_set():
        try:
            sock.sendto(payload, ("255.255.255.255", DISCOVERY_PORT))
        except OSError:
            pass
        time.sleep(2)


def listen_loop(stop):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", DISCOVERY_PORT))
    sock.settimeout(1)
    me = local_ip()
    seen = {}
    while not stop.is_set():
        try:
            data, (ip, _) = sock.recvfrom(4096)
        except socket.timeout:
            continue
        if ip == me:
            continue
        try:
            info = json.loads(data.decode())
        except ValueError:
            continue
        if info.get("app") != APP_ID:
            continue
        if ip not in seen:
            print(f"[发现] {info.get('name')} ({info.get('os')}) {ip}:{info.get('tcpPort')}")
        seen[ip] = time.time()


def read_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("连接中断")
        buf += chunk
    return buf


def read_frame(conn):
    (length,) = struct.unpack(">I", read_exact(conn, 4))
    return read_exact(conn, length)


def write_frame(conn, payload):
    if isinstance(payload, str):
        payload = payload.encode()
    conn.sendall(struct.pack(">I", len(payload)) + payload)


def fmt_size(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


# ---------- 接收 ----------

def compute_offsets(inc_dir, tid, files):
    """会话元信息一致时取 .part 长度，否则清空旧会话"""
    offsets = [0] * len(files)
    meta_path = os.path.join(inc_dir, f"{tid}.json")
    try:
        if os.path.exists(meta_path):
            with open(meta_path, encoding="utf-8") as f:
                saved = json.load(f)["files"]
            if len(saved) == len(files) and all(
                    saved[i]["name"] == files[i]["name"] and saved[i]["size"] == files[i]["size"]
                    for i in range(len(files))):
                for i in range(len(files)):
                    part = os.path.join(inc_dir, f"{tid}_{i}.part")
                    if os.path.exists(part):
                        offsets[i] = min(os.path.getsize(part), files[i]["size"])
                return offsets
    except Exception:
        pass
    for fn in os.listdir(inc_dir):
        if fn.startswith(f"{tid}_") or fn == f"{tid}.json":
            try:
                os.remove(os.path.join(inc_dir, fn))
            except OSError:
                pass
    return offsets


def recv_session(conn, addr, outdir, inc_dir):
    header = json.loads(read_frame(conn).decode())
    if header.get("app") != APP_ID:
        return
    files = [{"name": os.path.basename(f["name"]), "size": f["size"]}
             for f in header["files"]]
    total = header["total"]
    tid = "".join(c for c in header.get("transferId", "legacy") if c.isalnum() or c in "-_") or "x"
    print(f"[请求] {header.get('from')} 想发 {len(files)} 个文件（共 {fmt_size(total)}），自动接受")

    offsets = compute_offsets(inc_dir, tid, files)
    with open(os.path.join(inc_dir, f"{tid}.json"), "w", encoding="utf-8") as f:
        json.dump({"files": files}, f)
    write_frame(conn, json.dumps({"status": "ACCEPT", "offsets": offsets}))
    if any(offsets):
        print(f"[续传] 已接收 {fmt_size(sum(offsets))}，从断点继续")

    received = sum(offsets)
    start = time.time()
    for i, fi in enumerate(files):
        meta = json.loads(read_frame(conn).decode())
        name, size = fi["name"], fi["size"]
        offset = min(meta.get("offset", 0), size)
        part = os.path.join(inc_dir, f"{tid}_{i}.part")
        if offset < size:
            with open(part, "r+b" if os.path.exists(part) else "wb") as f:
                f.seek(offset)
                f.truncate(offset)
                remaining = size - offset
                while remaining > 0:
                    chunk = conn.recv(min(65536, remaining))
                    if not chunk:
                        raise ConnectionError("连接中断")
                    f.write(chunk)
                    remaining -= len(chunk)
                    received += len(chunk)
                    done = received / total * 100 if total else 100
                    speed = (received - sum(offsets)) / max(time.time() - start, 0.001)
                    print(f"\r[接收] {name}  总进度 {done:.1f}%  {fmt_size(speed)}/s", end="", flush=True)
        target = os.path.join(outdir, name)
        os.replace(part, target)
        write_frame(conn, "ACK")
        print(f"\n[完成] {name} -> {target}")
    write_frame(conn, "DONE")
    try:
        os.remove(os.path.join(inc_dir, f"{tid}.json"))
    except OSError:
        pass
    print("[全部完成]")


def mode_recv():
    base = os.path.dirname(os.path.abspath(__file__))
    outdir = os.path.join(base, "recv_out")
    inc_dir = os.path.join(base, ".incoming")
    os.makedirs(outdir, exist_ok=True)
    os.makedirs(inc_dir, exist_ok=True)
    stop = threading.Event()
    threading.Thread(target=broadcast_loop, args=(stop,), daemon=True).start()
    threading.Thread(target=listen_loop, args=(stop,), daemon=True).start()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("", TRANSFER_PORT))
    srv.listen(4)
    print(f"[就绪] 本机 {local_ip()}，等待手机发来文件，保存到 {outdir}")
    try:
        while True:
            conn, addr = srv.accept()
            threading.Thread(target=lambda: recv_session(conn, addr, outdir, inc_dir), daemon=True).start()
    except KeyboardInterrupt:
        stop.set()


# ---------- 发送 ----------

def mode_send(ip, paths):
    stop = threading.Event()
    threading.Thread(target=broadcast_loop, args=(stop,), daemon=True).start()
    files = [(os.path.basename(p), os.path.getsize(p), p) for p in paths]
    total = sum(s for _, s, _ in files)
    # 与安卓端一致：同一批文件发同一设备 → 相同 transferId → 自动续传
    raw = ip + "|".join(f"{n}:{s}" for n, s, _ in files)
    tid = "t" + hashlib.md5(raw.encode()).hexdigest()[:16]

    conn = socket.create_connection((ip, TRANSFER_PORT), timeout=8)
    write_frame(conn, json.dumps({
        "app": APP_ID, "version": 1, "transferId": tid, "from": NAME, "total": total,
        "files": [{"name": n, "size": s} for n, s, _ in files],
    }))
    conn.settimeout(120)
    resp = json.loads(read_frame(conn).decode())
    if resp.get("status") != "ACCEPT":
        print(f"[失败] 对方拒绝: {resp}")
        return
    conn.settimeout(None)
    offsets = (resp.get("offsets") or [0] * len(files))[:len(files)]
    if any(offsets):
        print(f"[续传] 跳过已接收的 {fmt_size(sum(offsets))}")
    print("[已接受] 开始传输")
    sent = sum(offsets)
    start = time.time()
    for i, (name, size, path) in enumerate(files):
        offset = min(offsets[i], size)
        write_frame(conn, json.dumps({"name": name, "size": size, "offset": offset}))
        if offset < size:
            with open(path, "rb") as f:
                f.seek(offset)
                while True:
                    chunk = f.read(65536)
                    if not chunk:
                        break
                    conn.sendall(chunk)
                    sent += len(chunk)
                    done = sent / total * 100 if total else 100
                    speed = (sent - sum(offsets)) / max(time.time() - start, 0.001)
                    print(f"\r[发送] {name}  总进度 {done:.1f}%  {fmt_size(speed)}/s", end="", flush=True)
        assert read_frame(conn).decode() == "ACK"
        print(f"\n[完成] {name}")
    read_frame(conn)  # DONE
    print("[全部完成]")
    stop.set()


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "recv":
        mode_recv()
    elif len(sys.argv) >= 4 and sys.argv[1] == "send":
        mode_send(sys.argv[2], sys.argv[3:])
    else:
        print(__doc__)
