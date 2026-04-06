#!/usr/bin/env python3
"""
HW Architecture Editor Server (multi-file)
============================================
- Serves the diagram editor UI at http://localhost:8400
- Manages multiple open JSON files simultaneously
- REST API for file operations
- SSE endpoint for live-reload on external file changes

Usage:
    python server.py                         # opens with no file
    python server.py file1.json file2.json   # opens multiple files

No external dependencies — stdlib only.
"""

import http.server
import json
import os
import signal
import subprocess
import sys
import time
import threading
from pathlib import Path
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("HW_EDITOR_PORT", 8400))
EDITOR_DIR = Path(__file__).parent
sys.path.insert(0, str(EDITOR_DIR))
POLL_INTERVAL = 0.5

# ── Multi-file state ──
_lock = threading.Lock()
_sse_clients: list = []

# Each open file: { id, path (Path|None), mtime, data_str }
_open_files: dict = {}  # id -> file_entry
_next_id = 1


def _new_file_id():
    global _next_id
    fid = f"f{_next_id}"
    _next_id += 1
    return fid


def open_file(filepath: Path) -> dict:
    """Open a file from disk and register it."""
    filepath = filepath.resolve()
    # Check if already open
    for fid, entry in _open_files.items():
        if entry["path"] and entry["path"] == filepath:
            return entry
    fid = _new_file_id()
    try:
        data_str = filepath.read_text(encoding="utf-8")
    except FileNotFoundError:
        data_str = "{}"
    entry = {
        "id": fid,
        "path": filepath,
        "mtime": _get_mtime(filepath),
        "name": filepath.name,
    }
    _open_files[fid] = entry
    return entry


def create_new_file() -> dict:
    """Create an unsaved new file."""
    fid = _new_file_id()
    entry = {
        "id": fid,
        "path": None,
        "mtime": 0,
        "name": f"untitled-{fid}.json",
    }
    _open_files[fid] = entry
    return entry


def close_file(fid: str):
    _open_files.pop(fid, None)


def _get_mtime(filepath: Path) -> float:
    try:
        return filepath.stat().st_mtime
    except (FileNotFoundError, TypeError):
        return 0.0


def _read_file(fid: str) -> str:
    entry = _open_files.get(fid)
    if not entry or not entry["path"]:
        return "{}"
    try:
        return entry["path"].read_text(encoding="utf-8")
    except FileNotFoundError:
        return "{}"


def _write_simple(filepath: Path, data_str: str):
    """Write the simplified JSON alongside the main file."""
    try:
        from simplify_json import simplify
        raw = json.loads(data_str)
        result = simplify(raw)
        stem = filepath.stem
        simple_path = filepath.with_name(f"{stem}.simple.json")
        simple_path.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    except Exception as e:
        sys.stderr.write(f"[hw-editor] simple.json write failed: {e}\n")


def _write_file(fid: str, data_str: str):
    entry = _open_files.get(fid)
    if not entry or not entry["path"]:
        return
    entry["path"].write_text(data_str, encoding="utf-8")
    _write_simple(entry["path"], data_str)
    with _lock:
        entry["mtime"] = _get_mtime(entry["path"])


def _save_file_as(fid: str, new_path: Path, data_str: str):
    new_path = new_path.resolve()
    new_path.write_text(data_str, encoding="utf-8")
    _write_simple(new_path, data_str)
    entry = _open_files.get(fid)
    if entry:
        entry["path"] = new_path
        entry["name"] = new_path.name
        with _lock:
            entry["mtime"] = _get_mtime(new_path)


def file_watcher():
    """Poll all open files for external changes."""
    while True:
        time.sleep(POLL_INTERVAL)
        changed_ids = []
        with _lock:
            for fid, entry in _open_files.items():
                if not entry["path"]:
                    continue
                mt = _get_mtime(entry["path"])
                if mt > entry["mtime"]:
                    entry["mtime"] = mt
                    changed_ids.append(fid)
        if changed_ids:
            msg = json.dumps({"changed": changed_ids})
            dead = []
            for wfile in _sse_clients[:]:
                try:
                    wfile.write(f"data: {msg}\n\n".encode())
                    wfile.flush()
                except Exception:
                    dead.append(wfile)
            for d in dead:
                try:
                    _sse_clients.remove(d)
                except ValueError:
                    pass


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write(f"[hw-editor] {args[0]}\n")

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, PUT, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json_response(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self._cors()
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length).decode()

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path

        # ── API: browse directories/files for autocomplete ──
        if path == "/api/browse":
            qs = parse_qs(urlparse(self.path).query)
            prefix = qs.get("q", [""])[0]
            try:
                p = Path(prefix).expanduser()
                if prefix.endswith("/") and p.is_dir():
                    parent = p
                    partial = ""
                else:
                    parent = p.parent
                    partial = p.name.lower()
                if not parent.is_dir():
                    self._json_response(200, {"items": [], "dir": ""})
                    return
                items = []
                for child in sorted(parent.iterdir()):
                    if child.name.startswith("."):
                        continue
                    if partial and not child.name.lower().startswith(partial):
                        continue
                    items.append({
                        "name": child.name,
                        "path": str(child),
                        "isDir": child.is_dir(),
                        "isJson": child.suffix == ".json",
                    })
                    if len(items) >= 30:
                        break
                # Sort: dirs first, then files
                items.sort(key=lambda x: (not x["isDir"], x["name"]))
                self._json_response(200, {"items": items, "dir": str(parent)})
            except Exception as e:
                self._json_response(200, {"items": [], "dir": "", "error": str(e)})
            return

        # ── List open files ──
        if path == "/api/files":
            files = []
            for fid, entry in _open_files.items():
                files.append({
                    "id": fid,
                    "name": entry["name"],
                    "path": str(entry["path"]) if entry["path"] else None,
                })
            self._json_response(200, {"files": files})
            return

        # ── Read a specific file ──
        if path.startswith("/api/file/") and path.count("/") == 3:
            fid = path.split("/")[3]
            if fid not in _open_files:
                self._json_response(404, {"error": "File not found"})
                return
            body = _read_file(fid).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self._cors()
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)
            return

        # ── Simplified JSON for a specific file ──
        if path.startswith("/api/simple/"):
            fid = path.split("/")[3]
            if fid not in _open_files:
                self._json_response(404, {"error": "File not found"})
                return
            try:
                from simplify_json import simplify
                raw = json.loads(_read_file(fid))
                result = simplify(raw)
                body = json.dumps(result, indent=2, ensure_ascii=False).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self._cors()
                self.send_header("Content-Length", len(body))
                self.end_headers()
                self.wfile.write(body)
            except Exception as e:
                self._json_response(500, {"error": str(e)})
            return

        # ── SSE: file change notifications ──
        if path == "/api/watch":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self._cors()
            self.end_headers()
            _sse_clients.append(self.wfile)
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
        if fpath.is_file() and (EDITOR_DIR in fpath.resolve().parents or fpath.resolve() == EDITOR_DIR.resolve()):
            ext = fpath.suffix
            ctypes = {".html": "text/html", ".js": "application/javascript",
                      ".css": "text/css", ".json": "application/json", ".svg": "image/svg+xml"}
            body = fpath.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", ctypes.get(ext, "application/octet-stream"))
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        path = urlparse(self.path).path

        # ── Open a file by server path ──
        if path == "/api/files/open":
            body = self._read_body()
            try:
                req = json.loads(body)
                filepath = Path(req["path"]).expanduser().resolve()
                if not filepath.exists():
                    self._json_response(404, {"error": f"File not found: {filepath}"})
                    return
                entry = open_file(filepath)
                self._json_response(200, {
                    "id": entry["id"], "name": entry["name"],
                    "path": str(entry["path"]),
                })
            except Exception as e:
                self._json_response(400, {"error": str(e)})
            return

        # ── Create new (unsaved) file ──
        if path == "/api/files/new":
            entry = create_new_file()
            self._json_response(200, {
                "id": entry["id"], "name": entry["name"], "path": None,
            })
            return

        self.send_response(404)
        self.end_headers()

    def do_PUT(self):
        path = urlparse(self.path).path

        # ── Save a specific file ──
        if path.startswith("/api/file/") and path.count("/") == 3:
            fid = path.split("/")[3]
            if fid not in _open_files:
                self._json_response(404, {"error": "File not found"})
                return
            body = self._read_body()
            try:
                json.loads(body)  # validate JSON
                _write_file(fid, body)
                entry = _open_files[fid]
                self._json_response(200, {
                    "ok": True,
                    "path": str(entry["path"]) if entry["path"] else None,
                })
            except json.JSONDecodeError as e:
                self._json_response(400, {"error": f"Invalid JSON: {e}"})
            return

        # ── Save As ──
        if path.startswith("/api/saveas/"):
            fid = path.split("/")[3]
            if fid not in _open_files:
                self._json_response(404, {"error": "File not found"})
                return
            body = self._read_body()
            try:
                req = json.loads(body)
                new_path = Path(req["path"]).expanduser().resolve()
                content = json.dumps(req["data"], indent=2)
                _save_file_as(fid, new_path, content)
                entry = _open_files[fid]
                self._json_response(200, {
                    "ok": True, "path": str(new_path), "name": entry["name"],
                })
            except Exception as e:
                self._json_response(400, {"error": str(e)})
            return

        self.send_response(404)
        self.end_headers()

    def do_DELETE(self):
        path = urlparse(self.path).path

        # ── Close a file ──
        if path.startswith("/api/file/") and path.count("/") == 3:
            fid = path.split("/")[3]
            close_file(fid)
            self._json_response(200, {"ok": True})
            return

        self.send_response(404)
        self.end_headers()


def main():
    # Open files passed as CLI arguments
    for arg in sys.argv[1:]:
        p = Path(arg)
        if not p.exists():
            print(f"[hw-editor] Creating {p}...")
            p.write_text("{}", encoding="utf-8")
        entry = open_file(p)
        print(f"[hw-editor] Opened: {entry['path']} (id={entry['id']})")

    if not _open_files:
        # No args — create a default new file
        entry = create_new_file()
        print(f"[hw-editor] New untitled file (id={entry['id']})")

    # Start file watcher
    threading.Thread(target=file_watcher, daemon=True).start()

    # Kill leftover processes on this port
    try:
        result = subprocess.run(["lsof", "-ti", f":{PORT}"], capture_output=True, text=True)
        for pid_str in result.stdout.strip().split("\n"):
            if pid_str and int(pid_str) != os.getpid():
                print(f"[hw-editor] Killing leftover process {pid_str} on port {PORT}")
                os.kill(int(pid_str), signal.SIGTERM)
        time.sleep(0.3)
    except Exception:
        pass

    class Server(http.server.ThreadingHTTPServer):
        allow_reuse_address = True
        daemon_threads = True

    server = Server(("0.0.0.0", PORT), Handler)
    print(f"[hw-editor] Serving on http://localhost:{PORT}")
    print(f"[hw-editor] Press Ctrl+C to stop")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()
        print("\n[hw-editor] Stopped.")


if __name__ == "__main__":
    main()
