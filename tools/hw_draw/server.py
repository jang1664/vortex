#!/usr/bin/env python3
"""
HW Architecture Editor Server
==============================
- Serves the diagram editor UI at http://localhost:8400
- REST API to read/write hw_arch.json
- SSE endpoint so browser auto-refreshes when Claude Code edits the file

Usage:
    python hw_editor/server.py                    # default: ./hw_arch.json
    python hw_editor/server.py path/to/arch.json  # custom path

No external dependencies — stdlib only.
"""

import http.server
import json
import os
import sys
import time
import threading
from pathlib import Path
from urllib.parse import urlparse

# ── Config ──
ARCH_FILE = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("hw_arch.json")
PORT = int(os.environ.get("HW_EDITOR_PORT", 8400))
EDITOR_DIR = Path(__file__).parent
POLL_INTERVAL = 0.5  # seconds

# ── File watcher state ──
_last_mtime = 0.0
_lock = threading.Lock()
_sse_clients: list = []


def get_mtime():
    try:
        return ARCH_FILE.stat().st_mtime
    except FileNotFoundError:
        return 0.0


def read_arch():
    try:
        return ARCH_FILE.read_text(encoding="utf-8")
    except FileNotFoundError:
        return "{}"


def write_arch(data: str):
    global _last_mtime
    ARCH_FILE.write_text(data, encoding="utf-8")
    with _lock:
        _last_mtime = get_mtime()


def file_watcher():
    """Poll for file changes and notify SSE clients."""
    global _last_mtime
    _last_mtime = get_mtime()
    while True:
        time.sleep(POLL_INTERVAL)
        mt = get_mtime()
        with _lock:
            if mt > _last_mtime:
                _last_mtime = mt
                dead = []
                for wfile in _sse_clients:
                    try:
                        wfile.write(f"data: changed\n\n".encode())
                        wfile.flush()
                    except Exception:
                        dead.append(wfile)
                for d in dead:
                    _sse_clients.remove(d)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Quieter logging
        sys.stderr.write(f"[hw-editor] {args[0]}\n")

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, PUT, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json_response(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self._cors()
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path

        # ── API: file info (path) ──
        if path == "/api/info":
            self._json_response(200, {"path": str(ARCH_FILE.resolve())})
            return

        # ── API: read architecture ──
        if path == "/api/arch":
            body = read_arch().encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self._cors()
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)
            return

        # ── SSE: file change notifications ──
        if path == "/api/watch":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self._cors()
            self.end_headers()
            _sse_clients.append(self.wfile)
            # Keep connection open
            try:
                while True:
                    time.sleep(1)
            except Exception:
                pass
            return

        # ── Static files ──
        if path == "/":
            path = "/index.html"
        fpath = EDITOR_DIR / path.lstrip("/")
        if fpath.is_file() and EDITOR_DIR in fpath.resolve().parents or fpath.resolve() == (EDITOR_DIR / "index.html").resolve():
            ext = fpath.suffix
            ctypes = {".html": "text/html", ".js": "application/javascript", ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml"}
            body = fpath.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", ctypes.get(ext, "application/octet-stream"))
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_PUT(self):
        path = urlparse(self.path).path
        if path == "/api/arch":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode()
            try:
                json.loads(body)
                write_arch(body)
                self._json_response(200, {"ok": True, "path": str(ARCH_FILE.resolve())})
            except json.JSONDecodeError as e:
                self._json_response(400, {"error": f"Invalid JSON: {e}"})
        elif path == "/api/saveas":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode()
            try:
                req = json.loads(body)
                new_path = Path(req["path"]).expanduser().resolve()
                content = json.dumps(req["data"], indent=2)
                new_path.write_text(content, encoding="utf-8")
                # Update the active file path
                global ARCH_FILE, _last_mtime
                ARCH_FILE = new_path
                with _lock:
                    _last_mtime = get_mtime()
                self._json_response(200, {"ok": True, "path": str(new_path)})
            except Exception as e:
                self._json_response(400, {"error": str(e)})
        else:
            self.send_response(404)
            self.end_headers()


def generate_markdown(data):
    modules = data.get("modules", {})
    top = data.get("topModule", "")
    lines = ["# Hardware Architecture", "", f"Top module: **{modules.get(top, {}).get('name', top)}**", ""]

    ordered = [top] + [k for k in modules if k != top]
    for mid in ordered:
        m = modules.get(mid)
        if not m:
            continue
        lines.append(f"## Module: {m['name']}")
        lines.append("")

        props = m.get("props", {})
        if props:
            lines.append("Properties: " + ", ".join(f"`{k}`: {v}" for k, v in props.items()))
            lines.append("")

        ports = m.get("ports", [])
        if ports:
            lines.append("### Ports")
            lines.append("")
            lines.append("| Name | Dir | Properties |")
            lines.append("|------|-----|------------|")
            for p in ports:
                pp = ", ".join(f"{k}={v}" for k, v in p.get("props", {}).items()) or "-"
                lines.append(f"| {p['name']} | {p['dir']} | {pp} |")
            lines.append("")

        insts = m.get("instances", [])
        if insts:
            lines.append("### Instances")
            lines.append("")
            lines.append("| Instance | Module | Properties |")
            lines.append("|----------|--------|------------|")
            for inst in insts:
                ref = modules.get(inst["moduleRef"], {}).get("name", inst["moduleRef"])
                ip = ", ".join(f"{k}={v}" for k, v in inst.get("props", {}).items()) or "-"
                lines.append(f"| {inst['name']} | {ref} | {ip} |")
            lines.append("")

        conns = m.get("connections", [])
        if conns:
            lines.append("### Connections")
            lines.append("")
            lines.append("| From | To | Properties |")
            lines.append("|------|----|------------|")
            for c in conns:
                fl = _resolve_ep(m, c["from"], modules)
                tl = _resolve_ep(m, c["to"], modules)
                cp = ", ".join(f"{k}={v}" for k, v in c.get("props", {}).items()) or "-"
                lines.append(f"| {fl} | {tl} | {cp} |")
            lines.append("")

    return "\n".join(lines)


def _resolve_ep(parent_mod, ep, modules):
    if ep["inst"] == "self":
        port = next((p for p in parent_mod["ports"] if p["id"] == ep["port"]), None)
        return f"self.{port['name'] if port else ep['port']}"
    inst = next((i for i in parent_mod["instances"] if i["id"] == ep["inst"]), None)
    if not inst:
        return f"{ep['inst']}.{ep['port']}"
    ref = modules.get(inst["moduleRef"], {})
    port = next((p for p in ref.get("ports", []) if p["id"] == ep["port"]), None)
    return f"{inst['name']}.{port['name'] if port else ep['port']}"


def main():
    if not ARCH_FILE.exists():
        print(f"[hw-editor] {ARCH_FILE} not found, creating with example data...")
        example = {
            "modules": {
                "m_top": {
                    "id": "m_top", "name": "SoC_Top",
                    "props": {"description": "Top-level SoC", "process": "28nm"},
                    "ports": [
                        {"id": "tp1", "name": "uart_pad", "dir": "inout", "props": {"width": 1}},
                        {"id": "tp2", "name": "ext_irq", "dir": "in", "props": {"width": 4}},
                    ],
                    "instances": [], "connections": [],
                }
            },
            "topModule": "m_top",
        }
        write_arch(json.dumps(example, indent=2))

    # Start file watcher thread
    watcher = threading.Thread(target=file_watcher, daemon=True)
    watcher.start()

    server = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[hw-editor] Serving on http://localhost:{PORT}")
    print(f"[hw-editor] Architecture file: {ARCH_FILE.resolve()}")
    print(f"[hw-editor] Claude Code can directly read/write {ARCH_FILE}")
    print(f"[hw-editor] Press Ctrl+C to stop")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[hw-editor] Stopped.")


if __name__ == "__main__":
    main()
