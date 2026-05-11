#!/usr/bin/env python3
"""NeXiS Controller — Build 1.0.0"""

import os, sys, json, sqlite3, threading, signal, re, base64, queue as _queue
import socket as _socket, subprocess, urllib.request, urllib.parse, urllib.error
import hashlib, hmac, time, struct, traceback, uuid, copy
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from pathlib import Path
from functools import lru_cache
from typing import Optional

# ── version ──────────────────────────────────────────────────────────────────
VERSION = "1.0.16"

# ── controller device ID (module-level constant) ──────────────────────────────
_CONTROLLER_DEVICE_ID = "controller-0000"

# ── paths ─────────────────────────────────────────────────────────────────────
BASE_DIR   = Path(os.environ.get("NEXIS_BASE", "/opt/nexis"))
DB_PATH    = BASE_DIR / "nexis.db"
LOG_PATH   = BASE_DIR / "nexis.log"
CFG_PATH   = BASE_DIR / "nexis.cfg"
STATE_PATH = BASE_DIR / "nexis.state"

# ── logging ───────────────────────────────────────────────────────────────────
import logging
logging.basicConfig(
    filename=str(LOG_PATH),
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("nexis")

# ── helpers ───────────────────────────────────────────────────────────────────
def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()

def _sha256(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()

def _hmac(key: str, msg: str) -> str:
    return hmac.new(key.encode(), msg.encode(), hashlib.sha256).hexdigest()

def _ok(data=None) -> dict:
    return {"status": "ok", "data": data}

def _err(msg: str, code: int = 400) -> tuple:
    return {"status": "error", "message": msg}, code

# ── database ──────────────────────────────────────────────────────────────────
_db_lock = threading.Lock()

def _db() -> sqlite3.Connection:
    con = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA foreign_keys=ON")
    return con

def _init_db():
    with _db_lock, _db() as con:
        con.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            id        TEXT PRIMARY KEY,
            username  TEXT UNIQUE NOT NULL,
            pw_hash   TEXT NOT NULL,
            role      TEXT NOT NULL DEFAULT 'user',
            created   TEXT NOT NULL,
            last_seen TEXT
        );
        CREATE TABLE IF NOT EXISTS devices (
            id          TEXT PRIMARY KEY,
            owner_id    TEXT NOT NULL REFERENCES users(id),
            name        TEXT NOT NULL,
            device_type TEXT NOT NULL DEFAULT 'generic',
            ip          TEXT,
            port        INTEGER,
            status      TEXT NOT NULL DEFAULT 'offline',
            registered  TEXT NOT NULL,
            last_seen   TEXT
        );
        CREATE TABLE IF NOT EXISTS sessions (
            token      TEXT PRIMARY KEY,
            user_id    TEXT NOT NULL REFERENCES users(id),
            created    TEXT NOT NULL,
            expires    TEXT NOT NULL,
            ip         TEXT
        );
        CREATE TABLE IF NOT EXISTS events (
            id         TEXT PRIMARY KEY,
            ts         TEXT NOT NULL,
            user_id    TEXT,
            device_id  TEXT,
            kind       TEXT NOT NULL,
            payload    TEXT
        );
        CREATE TABLE IF NOT EXISTS config (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        )

# ── session store ─────────────────────────────────────────────────────────────
SESSION_TTL = 3600  # seconds

def _session_create(user_id: str, ip: str) -> str:
    token = uuid.uuid4().hex + uuid.uuid4().hex
    exp   = datetime.fromtimestamp(time.time() + SESSION_TTL, tz=timezone.utc).isoformat()
    with _db_lock, _db() as con:
        con.execute(
            "INSERT INTO sessions VALUES (?,?,?,?,?)",
            (token, user_id, _now_iso(), exp, ip),
        )
    return token

def _session_lookup(token: str) -> Optional[dict]:
    with _db_lock, _db() as con:
        row = con.execute(
            "SELECT * FROM sessions WHERE token=? AND expires>?",
            (token, _now_iso()),
        ).fetchone()
    return dict(row) if row else None

def _session_delete(token: str):
    with _db_lock, _db() as con:
        con.execute("DELETE FROM sessions WHERE token=?", (token,))

# ── event log ─────────────────────────────────────────────────────────────────
def _log_event(kind: str, user_id=None, device_id=None, payload=None):
    with _db_lock, _db() as con:
        con.execute(
            "INSERT INTO events VALUES (?,?,?,?,?,?)",
            (uuid.uuid4().hex, _now_iso(), user_id, device_id, kind,
             json.dumps(payload) if payload else None),
        )

# ── HTTP handler ──────────────────────────────────────────────────────────────
class NexisHandler(BaseHTTPRequestHandler):
    server_version = f"NexisController/{VERSION}"

    # ── request plumbing ──────────────────────────────────────────────────────
    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length else b""

    def _parse_json(self) -> Optional[dict]:
        try:
            return json.loads(self._read_body())
        except Exception:
            return None

    def _send(self, data: dict, code: int = 200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_err(self, msg: str, code: int = 400):
        self._send({"status": "error", "message": msg}, code)

    def _token(self) -> Optional[str]:
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            return auth[7:]
        return None

    def _require_auth(self) -> Optional[dict]:
        """Return session dict or send 401 and return None."""
        token = self._token()
        if not token:
            self._send_err("missing token", 401)
            return None
        sess = _session_lookup(token)
        if not sess:
            self._send_err("invalid or expired token", 401)
            return None
        return sess

    def _is_admin(self, sess: dict) -> bool:
        with _db_lock, _db() as con:
            row = con.execute(
                "SELECT role FROM users WHERE id=?", (sess["user_id"],)
            ).fetchone()
        return bool(row and row["role"] == "admin")

    def _require_admin(self, sess: dict) -> bool:
        """Return True if admin; otherwise send 403 and return False."""
        if not self._is_admin(sess):
            self._send_err("admin required", 403)
            return False
        return True

    # ── router ────────────────────────────────────────────────────────────────
    def _route(self, method: str):
        path = self.path.split("?")[0].rstrip("/")
        parts = [p for p in path.split("/") if p]

        # health
        if method == "GET" and path == "/health":
            return self._send(_ok({"version": VERSION}))

        # auth
        if method == "POST" and parts[:2] == ["api", "auth"]:
            action = parts[2] if len(parts) > 2 else ""
            if action == "register":  return self._auth_register()
            if action == "login":     return self._auth_login()
            if action == "logout":    return self._auth_logout()

        # users
        if parts[:2] == ["api", "users"]:
            if method == "GET"  and len(parts) == 2: return self._users_list()
            if method == "GET"  and len(parts) == 3: return self._user_get(parts[2])
            if method == "PUT"  and len(parts) == 3: return self._user_update(parts[2])
            if method == "DELETE" and len(parts) == 3: return self._user_delete(parts[2])

        # devices
        if parts[:2] == ["api", "devices"]:
            if method == "GET"    and len(parts) == 2: return self._devices_list()
            if method == "POST"   and len(parts) == 2: return self._device_register()
            if method == "GET"    and len(parts) == 3: return self._device_get(parts[2])
            if method == "PUT"    and len(parts) == 3: return self._device_update(parts[2])
            if method == "DELETE" and len(parts) == 3: return self._device_delete(parts[2])

        # commands
        if parts[:2] == ["api", "cmd"]:
            if method == "POST" and len(parts) == 3: return self._cmd_send(parts[2])

        # events
        if parts[:2] == ["api", "events"]:
            if method == "GET" and len(parts) == 2: return self._events_list()

        # config
        if parts[:2] == ["api", "config"]:
            if method == "GET"  and len(parts) == 2: return self._config_list()
            if method == "PUT"  and len(parts) == 3: return self._config_set(parts[2])
            if method == "DELETE" and len(parts) == 3: return self._config_del(parts[2])

        # pages (UI stubs)
        if parts[:1] == ["page"]:
            page = parts[1] if len(parts) > 1 else "index"
            return self._page_render(page)

        self._send_err("not found", 404)

    def do_GET(self):    self._route("GET")
    def do_POST(self):   self._route("POST")
    def do_PUT(self):    self._route("PUT")
    def do_DELETE(self): self._route("DELETE")

    def log_message(self, fmt, *args):  # silence default stderr logging
        log.info("HTTP %s", fmt % args)

    # ── auth endpoints ────────────────────────────────────────────────────────
    def _auth_register(self):
        body = self._parse_json()
        if not body:
            return self._send_err("invalid JSON")
        username = (body.get("username") or "").strip()
        password = (body.get("password") or "").strip()
        if not username or not password:
            return self._send_err("username and password required")
        if len(username) < 3 or len(username) > 64:
            return self._send_err("username must be 3-64 chars")
        if len(password) < 8:
            return self._send_err("password must be ≥8 chars")
        uid = uuid.uuid4().hex
        try:
            with _db_lock, _db() as con:
                con.execute(
                    "INSERT INTO users VALUES (?,?,?,?,?,?)",
                    (uid, username, _sha256(password), "user", _now_iso(), None),
                )
        except sqlite3.IntegrityError:
            return self._send_err("username already taken", 409)
        _log_event("user.register", user_id=uid)
        self._send(_ok({"user_id": uid}), 201)

    def _auth_login(self):
        body = self._parse_json()
        if not body:
            return self._send_err("invalid JSON")
        username = (body.get("username") or "").strip()
        password = (body.get("password") or "").strip()
        with _db_lock, _db() as con:
            row = con.execute(
                "SELECT * FROM users WHERE username=?", (username,)
            ).fetchone()
        if not row or row["pw_hash"] != _sha256(password):
            return self._send_err("invalid credentials", 401)
        token = _session_create(row["id"], self.client_address[0])
        with _db_lock, _db() as con:
            con.execute("UPDATE users SET last_seen=? WHERE id=?", (_now_iso(), row["id"]))
        _log_event("user.login", user_id=row["id"])
        self._send(_ok({"token": token}))

    def _auth_logout(self):
        sess = self._require_auth()
        if not sess:
            return
        _session_delete(sess["token"])
        _log_event("user.logout", user_id=sess["user_id"])
        self._send(_ok())

    # ── user endpoints ────────────────────────────────────────────────────────
    def _users_list(self):
        sess = self._require_auth()
        if not sess or not self._require_admin(sess):
            return
        with _db_lock, _db() as con:
            rows = con.execute(
                "SELECT id,username,role,created,last_seen FROM users"
            ).fetchall()
        self._send(_ok([dict(r) for r in rows]))

    def _user_get(self, uid: str):
        sess = self._require_auth()
        if not sess:
            return
        if uid != sess["user_id"] and not self._is_admin(sess):
            return self._send_err("forbidden", 403)
        with _db_lock, _db() as con:
            row = con.execute(
                "SELECT id,username,role,created,last_seen FROM users WHERE id=?", (uid,)
            ).fetchone()
        if not row:
            return self._send_err("not found", 404)
        self._send(_ok(dict(row)))

    def _user_update(self, uid: str):
        sess = self._require_auth()
        if not sess:
            return
        if uid != sess["user_id"] and not self._is_admin(sess):
            return self._send_err("forbidden", 403)
        body = self._parse_json() or {}
        updates, params = [], []
        if "password" in body:
            pw = (body["password"] or "").strip()
            if len(pw) < 8:
                return self._send_err("password must be ≥8 chars")
            updates.append("pw_hash=?")
            params.append(_sha256(pw))
        if "role" in body and self._is_admin(sess):
            updates.append("role=?")
            params.append(body["role"])
        if not updates:
            return self._send_err("nothing to update")
        params.append(uid)
        with _db_lock, _db() as con:
            con.execute(f"UPDATE users SET {','.join(updates)} WHERE id=?", params)
        _log_event("user.update", user_id=uid)
        self._send(_ok())

    def _user_delete(self, uid: str):
        sess = self._require_auth()
        if not sess or not self._require_admin(sess):
            return
        with _db_lock, _db() as con:
            con.execute("DELETE FROM users WHERE id=?", (uid,))
        _log_event("user.delete", user_id=uid)
        self._send(_ok())

    # ── device endpoints ──────────────────────────────────────────────────────
    def _devices_list(self):
        sess = self._require_auth()
        if not sess:
            return
        uid = sess["user_id"]
        is_admin = self._is_admin(sess)
        with _db_lock, _db() as con:
            if is_admin:
                rows = con.execute("SELECT * FROM devices").fetchall()
            else:
                rows = con.execute(
                    "SELECT * FROM devices WHERE owner_id=?", (uid,)
                ).fetchall()
        self._send(_ok([dict(r) for r in rows]))

    def _device_register(self):
        sess = self._require_auth()
        if not sess:
            return
        body = self._parse_json()
        if not body:
            return self._send_err("invalid JSON")
        name = (body.get("name") or "").strip()
        if not name:
            return self._send_err("name required")
        dev_type = body.get("device_type", "generic")
        ip   = body.get("ip")
        port = body.get("port")
        did  = uuid.uuid4().hex
        with _db_lock, _db() as con:
            con.execute(
                "INSERT INTO devices VALUES (?,?,?,?,?,?,?,?,?)",
                (did, sess["user_id"], name, dev_type, ip, port,
                 "offline", _now_iso(), None),
            )
        _log_event("device.register", user_id=sess["user_id"], device_id=did)
        self._send(_ok({"device_id": did}), 201)

    def _device_get(self, did: str):
        sess = self._require_auth()
        if not sess:
            return
        with _db_lock, _db() as con:
            row = con.execute(
                "SELECT * FROM devices WHERE id=?", (did,)
            ).fetchone()
        if not row:
            return self._send_err("not found", 404)
        if row["owner_id"] != sess["user_id"] and not self._is_admin(sess):
            return self._send_err("forbidden", 403)
        self._send(_ok(dict(row)))

    def _device_update(self, did: str):
        sess = self._require_auth()
        if not sess:
            return
        with _db_lock, _db() as con:
            row = con.execute(
                "SELECT * FROM devices WHERE id=?", (did,)
            ).fetchone()
        if not row:
            return self._send_err("not found", 404)
        if row["owner_id"] != sess["user_id"] and not self._is_admin(sess):
            return self._send_err("forbidden", 403)
        body = self._parse_json() or {}
        updates, params = [], []
        for field in ("name", "device_type", "ip", "port", "status"):
            if field in body:
                updates.append(f"{field}=?")
                params.append(body[field])
        if not updates:
            return self._send_err("nothing to update")
        params.append(did)
        with _db_lock, _db() as con:
            con.execute(f"UPDATE devices SET {','.join(updates)} WHERE id=?", params)
        _log_event("device.update", user_id=sess["user_id"], device_id=did)
        self._send(_ok())

    def _device_delete(self, did: str):
        sess = self._require_auth()
        if not sess:
            return
        with _db_lock, _db() as con:
            row = con.execute(
                "SELECT * FROM devices WHERE id=?", (did,)
            ).fetchone()
        if not row:
            return self._send_err("not found", 404)
        if not self._is_admin(sess) and row["owner_id"] != sess["user_id"]:
            return self._send_err("forbidden", 403)
        with _db_lock, _db() as con:
            con.execute("DELETE FROM devices WHERE id=?", (did,))
        _log_event("device.delete", user_id=sess["user_id"], device_id=did)
        self._send(_ok())

    # ── command endpoint ──────────────────────────────────────────────────────
    def _cmd_send(self, did: str):
        sess = self._require_auth()
        if not sess:
            return
        with _db_lock, _db() as con:
            row = con.execute(
                "SELECT * FROM devices WHERE id=?", (did,)
            ).fetchone()
        if not row:
            return self._send_err("device not found", 404)
        if row["owner_id"] != sess["user_id"] and not self._is_admin(sess):
            return self._send_err("forbidden", 403)
        body = self._parse_json()
        if not body or "command" not in body:
            return self._send_err("command required")
        cmd = body["command"]
        result = self._dispatch_cmd(dict(row), cmd, body.get("args", {}))
        _log_event("cmd.send", user_id=sess["user_id"], device_id=did,
                   payload={"cmd": cmd})
        self._send(_ok(result))

    def _dispatch_cmd(self, device: dict, cmd: str, args: dict) -> dict:
        """Send a command to the target device over TCP (simple JSON protocol)."""
        ip   = device.get("ip")
        port = device.get("port")
        if not ip or not port:
            return {"error": "device has no ip/port"}
        payload = json.dumps({"cmd": cmd, "args": args}).encode()
        try:
            with _socket.create_connection((ip, int(port)), timeout=5) as s:
                s.sendall(struct.pack("!I", len(payload)) + payload)
                hdr = s.recv(4)
                if len(hdr) < 4:
                    return {"error": "short response"}
                rlen = struct.unpack("!I", hdr)[0]
                resp = s.recv(rlen)
            return json.loads(resp)
        except Exception as exc:
            return {"error": str(exc)}

    # ── event endpoint ────────────────────────────────────────────────────────
    def _events_list(self):
        sess = self._require_auth()
        if not sess or not self._require_admin(sess):
            return
        with _db_lock, _db() as con:
            rows = con.execute(
                "SELECT * FROM events ORDER BY ts DESC LIMIT 500"
            ).fetchall()
        self._send(_ok([dict(r) for r in rows]))

    # ── config endpoints ──────────────────────────────────────────────────────
    def _config_list(self):
        sess = self._require_auth()
        if not sess or not self._require_admin(sess):
            return
        with _db_lock, _db() as con:
            rows = con.execute("SELECT * FROM config").fetchall()
        self._send(_ok([dict(r) for r in rows]))

    def _config_set(self, key: str):
        sess = self._require_auth()
        if not sess or not self._require_admin(sess):
            return
        body = self._parse_json()
        if not body or "value" not in body:
            return self._send_err("value required")
        with _db_lock, _db() as con:
            con.execute(
                "INSERT INTO config(key,value) VALUES(?,?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (key, str(body["value"])),
            )
        _log_event("config.set", payload={"key": key})
        self._send(_ok())

    def _config_del(self, key: str):
        sess = self._require_auth()
        if not sess or not self._require_admin(sess):
            return
        with _db_lock, _db() as con:
            con.execute("DELETE FROM config WHERE key=?", (key,))
        _log_event("config.del", payload={"key": key})
        self._send(_ok())

    # ── page stubs ────────────────────────────────────────────────────────────
    def _page_render(self, page: str):
        sess = self._require_auth()
        if not sess:
            return
        role = self._get_user_role(sess["user_id"])
        html = self._build_page(page, role)
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _get_user_role(self, uid: str) -> str:
        with _db_lock, _db() as con:
            row = con.execute("SELECT role FROM users WHERE id=?", (uid,)).fetchone()
        return row["role"] if row else "user"

    def _build_page(self, page: str, role: str) -> str:
        return (
            "<!DOCTYPE html><html><head><title>NeXiS</title></head>"
            f"<body><h1>NeXiS Controller</h1><p>Page: {page}</p>"
            f"<p>Role: {role}</p></body></html>"
        )

# ── threaded server ───────────────────────────────────────────────────────────
class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

# ── main ──────────────────────────────────────────────────────────────────────
def _load_config() -> dict:
    if not CFG_PATH.exists():
        return {}
    try:
        return json.loads(CFG_PATH.read_text())
    except Exception:
        return {}

def main():
    cfg  = _load_config()
    host = cfg.get("host", "0.0.0.0")
    port = int(cfg.get("port", 8080))

    BASE_DIR.mkdir(parents=True, exist_ok=True)
    _init_db()

    server = ThreadedHTTPServer((host, port), NexisHandler)
    log.info("NeXiS Controller %s listening on %s:%d", VERSION, host, port)

    def _shutdown(sig, frame):
        log.info("shutting down")
        server.shutdown()

    signal.signal(signal.SIGINT,  _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)
    server.serve_forever()

if __name__ == "__main__":
    main()
