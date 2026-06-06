#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/telemt-cascade-panel"
APP_USER="telecascade"
APP_PORT="8080"
SERVICE_NAME="telemt-cascade-panel"
PANEL_SECRET="$(openssl rand -hex 24)"
PUBLIC_IP="$(curl -4fsS https://api.ipify.org || hostname -I | awk '{print $1}')"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl gnupg openssl python3 python3-venv python3-pip sqlite3 jq ufw

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-plugin
fi

id -u "${APP_USER}" >/dev/null 2>&1 || useradd --system --home "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
install -d -m 0750 -o "${APP_USER}" -g "${APP_USER}" "${APP_DIR}"
install -d -m 0750 -o "${APP_USER}" -g "${APP_USER}" "${APP_DIR}/data"
install -d -m 0750 -o "${APP_USER}" -g "${APP_USER}" "${APP_DIR}/runtime"

cat > "${APP_DIR}/app.py" <<'PYAPP'
from __future__ import annotations

import json
import os
import secrets
import sqlite3
import subprocess
import time
import urllib.parse
from pathlib import Path
from typing import Any, Literal

from fastapi import Depends, FastAPI, Form, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse, PlainTextResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials

APP_DIR = Path("/opt/telemt-cascade-panel")
DATA_DIR = APP_DIR / "data"
RUNTIME_DIR = APP_DIR / "runtime"
DB_PATH = DATA_DIR / "panel.sqlite3"

PUBLIC_IP = os.getenv("PUBLIC_IP", "127.0.0.1")
PANEL_SECRET = os.getenv("PANEL_SECRET", "")
TELEMT_IMAGE = os.getenv("TELEMT_IMAGE", "ghcr.io/telemt/telemt:3.4.14")
SING_BOX_IMAGE = os.getenv("SING_BOX_IMAGE", "ghcr.io/sagernet/sing-box:latest")

app = FastAPI(title="TeleMT Cascade Test Panel")
security = HTTPBasic()


def get_db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)

    with get_db() as conn:
        conn.executescript("""
        CREATE TABLE IF NOT EXISTS routes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          kind TEXT NOT NULL CHECK(kind IN ('vless','socks','http')),
          raw_config TEXT NOT NULL,
          is_active INTEGER NOT NULL DEFAULT 0,
          last_status TEXT NOT NULL DEFAULT 'unknown',
          last_error TEXT,
          created_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS access_keys (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          secret TEXT NOT NULL UNIQUE,
          enabled INTEGER NOT NULL DEFAULT 1,
          created_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """)
        if conn.execute("SELECT COUNT(*) AS c FROM access_keys").fetchone()["c"] == 0:
            conn.execute(
                "INSERT INTO access_keys(name, secret, enabled, created_at) VALUES(?,?,1,?)",
                ("default", secrets.token_hex(16), int(time.time())),
            )
        conn.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('listen_port','443')")
        conn.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('fake_tls_domain','vk.com')")
        conn.execute("INSERT OR IGNORE INTO settings(key,value) VALUES('public_host',?)", (PUBLIC_IP,))


@app.on_event("startup")
def startup() -> None:
    init_db()


def require_auth(credentials: HTTPBasicCredentials = Depends(security)) -> str:
    if not (
        secrets.compare_digest(credentials.username, "admin")
        and secrets.compare_digest(credentials.password, PANEL_SECRET)
    ):
        raise HTTPException(status_code=401, headers={"WWW-Authenticate": "Basic"})
    return credentials.username


def run(cmd: list[str], timeout: int = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=APP_DIR, text=True, capture_output=True, timeout=timeout)


def setting(key: str, default: str = "") -> str:
    with get_db() as conn:
        row = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return row["value"] if row else default


def set_setting(key: str, value: str) -> None:
    with get_db() as conn:
        conn.execute(
            "INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value),
        )


def safe_toml_key(name: str) -> str:
    key = "".join(ch if ch.isalnum() or ch in "_-" else "_" for ch in name.strip()) or "user"
    return f'"{key}"'


def mtproto_link(secret: str) -> str:
    host = setting("public_host", PUBLIC_IP)
    port = setting("listen_port", "443")
    return f"https://t.me/proxy?server={urllib.parse.quote(host)}&port={port}&secret={secret}"


def parse_vless(uri: str) -> dict[str, Any]:
    parsed = urllib.parse.urlparse(uri.strip())
    if parsed.scheme != "vless":
        raise ValueError("VLESS config must start with vless://")

    uuid = parsed.username
    server = parsed.hostname
    port = parsed.port
    if not uuid or not server or not port:
        raise ValueError("VLESS URI must contain uuid, host and port")

    q = urllib.parse.parse_qs(parsed.query)
    flow = q.get("flow", [""])[0]
    security = q.get("security", ["none"])[0]
    sni = q.get("sni", q.get("serverName", [""]))[0]
    fp = q.get("fp", ["chrome"])[0]
    pbk = q.get("pbk", [""])[0]
    sid = q.get("sid", [""])[0]
    spx = q.get("spx", ["/"])[0]
    network = q.get("type", ["tcp"])[0]
    path = q.get("path", [""])[0]
    host = q.get("host", [""])[0]

    outbound: dict[str, Any] = {
        "type": "vless",
        "tag": "cascade",
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "network": network,
    }
    if flow:
        outbound["flow"] = flow

    if security in {"tls", "reality"}:
        outbound["tls"] = {
            "enabled": True,
            "server_name": sni or server,
            "utls": {"enabled": True, "fingerprint": fp},
        }
        if security == "reality":
            outbound["tls"]["reality"] = {
                "enabled": True,
                "public_key": pbk,
                "short_id": sid,
            }
            if spx:
                outbound["tls"]["reality"]["spider_x"] = spx

    if network == "ws":
        outbound["transport"] = {"type": "ws", "path": path or "/", "headers": {}}
        if host:
            outbound["transport"]["headers"]["Host"] = host

    return outbound


def parse_proxy(kind: Literal["socks", "http"], raw: str) -> dict[str, Any]:
    data = json.loads(raw)
    outbound: dict[str, Any] = {
        "type": kind,
        "tag": "cascade",
        "server": data["server"].strip(),
        "server_port": int(data["port"]),
    }
    if data.get("username"):
        outbound["username"] = data["username"]
    if data.get("password"):
        outbound["password"] = data["password"]
    return outbound


def build_singbox_config(route: sqlite3.Row | None) -> dict[str, Any]:
    if route is None:
        outbound = {"type": "direct", "tag": "cascade"}
    elif route["kind"] == "vless":
        outbound = parse_vless(route["raw_config"])
    elif route["kind"] in {"socks", "http"}:
        outbound = parse_proxy(route["kind"], route["raw_config"])
    else:
        raise ValueError("Unknown route kind")

    return {
        "log": {"level": "info"},
        "dns": {"servers": [{"tag": "google", "address": "8.8.8.8"}]},
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "interface_name": "tun0",
                "inet4_address": "172.19.0.1/30",
                "auto_route": True,
                "strict_route": False,
                "stack": "system",
                "sniff": True,
            }
        ],
        "outbounds": [
            outbound,
            {"type": "direct", "tag": "direct"},
            {"type": "block", "tag": "block"},
        ],
        "route": {"auto_detect_interface": True, "final": "cascade"},
    }


def build_telemt_config() -> str:
    with get_db() as conn:
        rows = conn.execute("SELECT name, secret FROM access_keys WHERE enabled=1 ORDER BY id").fetchall()

    users = "\n".join([f"{safe_toml_key(row['name'])} = \"{row['secret']}\"" for row in rows])
    return f"""
[general]
use_middle_proxy = false
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "{setting("public_host", PUBLIC_IP)}"
public_port = {int(setting("listen_port", "443"))}

[server]
port = 443
max_connections = 10000

[server.tls]
enabled = true
domain = "{setting("fake_tls_domain", "vk.com")}"
mask = true
mask_addr = "vk.com:443"

[access]
enabled = true

[access.users]
{users}
""".strip() + "\n"


def write_runtime() -> None:
    with get_db() as conn:
        route = conn.execute("SELECT * FROM routes WHERE is_active=1 LIMIT 1").fetchone()

    (RUNTIME_DIR / "sing-box.json").write_text(
        json.dumps(build_singbox_config(route), indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    (RUNTIME_DIR / "telemt.toml").write_text(build_telemt_config(), encoding="utf-8")

    compose = f"""
services:
  egress:
    image: {SING_BOX_IMAGE}
    container_name: telemt-cascade-egress
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - {RUNTIME_DIR}/sing-box.json:/etc/sing-box/config.json:ro
    command: ["run", "-c", "/etc/sing-box/config.json"]
    ports:
      - "{int(setting("listen_port", "443"))}:443/tcp"

  telemt:
    image: {TELEMT_IMAGE}
    container_name: telemt-cascade
    restart: unless-stopped
    network_mode: "service:egress"
    depends_on:
      - egress
    working_dir: /run/telemt
    tmpfs:
      - /run/telemt:rw,mode=1777,size=4m
    volumes:
      - {RUNTIME_DIR}/telemt.toml:/etc/telemt/config.toml:ro
    environment:
      - RUST_LOG=info
    command: ["/etc/telemt/config.toml"]
""".strip() + "\n"
    (APP_DIR / "docker-compose.yml").write_text(compose, encoding="utf-8")


def docker_up() -> tuple[bool, str]:
    write_runtime()
    r = run(["docker", "compose", "up", "-d"], timeout=180)
    return r.returncode == 0, (r.stdout + r.stderr)[-5000:]


def docker_down() -> tuple[bool, str]:
    r = run(["docker", "compose", "down"], timeout=120)
    return r.returncode == 0, (r.stdout + r.stderr)[-5000:]


def check_runtime() -> tuple[bool, str]:
    ps = run(["docker", "ps", "--filter", "name=telemt-cascade", "--format", "{{.Names}} {{.Status}}"], timeout=20)
    if "telemt-cascade-egress" not in ps.stdout:
        return False, "egress container is not running"
    if "telemt-cascade" not in ps.stdout:
        return False, "telemt container is not running"

    logs = run(["docker", "logs", "--tail", "160", "telemt-cascade"], timeout=20)
    text = (logs.stdout + logs.stderr).lower()
    if "panic" in text:
        return False, (logs.stdout + logs.stderr)[-1500:]
    return True, "containers are running; verify final MTProto link inside Telegram client"


def html_page(body: str) -> HTMLResponse:
    return HTMLResponse(f"""
<!doctype html><html lang="ru"><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>TeleMT Cascade Panel</title>
<style>
body{{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#0b1020;color:#e7eaf3;margin:0}}
main{{max-width:1100px;margin:32px auto;padding:0 18px}}
.card{{background:#121a33;border:1px solid #263153;border-radius:16px;padding:18px;margin:16px 0;box-shadow:0 10px 30px #0004}}
input,textarea,select{{width:100%;box-sizing:border-box;background:#0b1020;color:#e7eaf3;border:1px solid #33406a;border-radius:10px;padding:10px;margin:6px 0 12px}}
textarea{{min-height:110px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}}
button{{background:#5d7cff;color:white;border:0;border-radius:10px;padding:10px 14px;cursor:pointer;margin:2px}}
.badge{{display:inline-block;padding:4px 8px;border-radius:999px;background:#263153;margin-right:6px}}
.ok{{background:#14532d}} .bad{{background:#7f1d1d}} .muted{{color:#9ba6c7}}
table{{width:100%;border-collapse:collapse}} td,th{{border-bottom:1px solid #263153;padding:8px;text-align:left;vertical-align:top}}
code{{word-break:break-all}}
</style></head><body><main>
<h1>TeleMT Cascade Test Panel</h1>
{body}
</main></body></html>
""")


@app.get("/", response_class=HTMLResponse)
def index(_: str = Depends(require_auth)) -> HTMLResponse:
    with get_db() as conn:
        routes = conn.execute("SELECT * FROM routes ORDER BY id DESC").fetchall()
        keys = conn.execute("SELECT * FROM access_keys ORDER BY id DESC").fetchall()

    active = next((r for r in routes if r["is_active"]), None)
    ps = run(["docker", "ps", "--filter", "name=telemt-cascade", "--format", "{{.Names}} {{.Status}}"], timeout=20)
    running = "telemt-cascade" in ps.stdout

    routes_rows = "".join(
        f"<tr><td>{r['id']}</td><td>{r['name']}</td><td>{r['kind']}</td>"
        f"<td>{'<span class=badge>active</span>' if r['is_active'] else ''}{r['last_status']}</td>"
        f"<td><form method=post action=/routes/{r['id']}/activate><button>Активировать</button></form></td></tr>"
        for r in routes
    ) or "<tr><td colspan=5 class=muted>Маршрутов пока нет</td></tr>"

    key_rows = "".join(
        f"<tr><td>{k['name']}</td><td><code>{mtproto_link(k['secret'])}</code></td><td>{'enabled' if k['enabled'] else 'disabled'}</td></tr>"
        for k in keys
    )

    body = f"""
<div class="card">
  <div class="badge {'ok' if running else 'bad'}">TeleMT: {'running' if running else 'stopped'}</div>
  <div class="badge {'ok' if active else 'bad'}">Cascade: {active['name'] if active else 'direct / not configured'}</div>
  <p class="muted">Public: <code>{setting('public_host', PUBLIC_IP)}:{setting('listen_port','443')}</code>, Fake TLS SNI: <code>{setting('fake_tls_domain','vk.com')}</code></p>
  <form method="post" action="/start" style="display:inline"><button>Старт / применить</button></form>
  <form method="post" action="/stop" style="display:inline"><button>Стоп</button></form>
  <form method="post" action="/check" style="display:inline"><button>Проверить</button></form>
</div>

<div class="card">
<h2>Настройки входа</h2>
<form method="post" action="/settings">
<label>Public host/IP для ссылки</label><input name="public_host" value="{setting('public_host', PUBLIC_IP)}"/>
<label>Внешний порт TeleMT</label><input name="listen_port" value="{setting('listen_port','443')}"/>
<label>Fake TLS domain / SNI</label><input name="fake_tls_domain" value="{setting('fake_tls_domain','vk.com')}"/>
<button>Сохранить</button>
</form>
</div>

<div class="card">
<h2>Добавить VLESS route</h2>
<form method="post" action="/routes/vless">
<label>Название</label><input name="name" placeholder="EU VLESS #1"/>
<label>VLESS URI</label><textarea name="vless_uri" placeholder="vless://uuid@host:443?security=reality&..."></textarea>
<button>Добавить</button>
</form>
</div>

<div class="card">
<h2>Добавить HTTP/SOCKS proxy route</h2>
<form method="post" action="/routes/proxy">
<label>Название</label><input name="name" placeholder="Backup SOCKS"/>
<label>Тип</label><select name="kind"><option value="socks">SOCKS5</option><option value="http">HTTP</option></select>
<label>IP / host</label><input name="server"/>
<label>Порт</label><input name="port"/>
<label>Логин</label><input name="username"/>
<label>Пароль</label><input name="password" type="password"/>
<button>Добавить</button>
</form>
</div>

<div class="card">
<h2>Маршруты</h2>
<table><tr><th>ID</th><th>Название</th><th>Тип</th><th>Статус</th><th></th></tr>{routes_rows}</table>
</div>

<div class="card">
<h2>MTProto доступы</h2>
<form method="post" action="/keys">
<label>Название ключа</label><input name="name" placeholder="client-1"/>
<button>Создать ключ</button>
</form>
<table><tr><th>Название</th><th>Ссылка</th><th>Статус</th></tr>{key_rows}</table>
</div>
"""
    return html_page(body)


@app.post("/settings")
def save_settings(public_host: str = Form(...), listen_port: int = Form(...), fake_tls_domain: str = Form(...), _: str = Depends(require_auth)):
    if listen_port < 1 or listen_port > 65535:
        raise HTTPException(400, "Bad port")
    set_setting("public_host", public_host.strip())
    set_setting("listen_port", str(listen_port))
    set_setting("fake_tls_domain", fake_tls_domain.strip() or "vk.com")
    return RedirectResponse("/", status_code=303)


@app.post("/routes/vless")
def add_vless(name: str = Form(...), vless_uri: str = Form(...), _: str = Depends(require_auth)):
    try:
        parse_vless(vless_uri)
    except Exception as e:
        raise HTTPException(400, str(e))
    with get_db() as conn:
        conn.execute("INSERT INTO routes(name, kind, raw_config, created_at) VALUES(?,?,?,?)", (name.strip() or "VLESS", "vless", vless_uri.strip(), int(time.time())))
    return RedirectResponse("/", status_code=303)


@app.post("/routes/proxy")
def add_proxy_route(
    name: str = Form(...),
    kind: Literal["socks", "http"] = Form(...),
    server: str = Form(...),
    port: int = Form(...),
    username: str = Form(""),
    password: str = Form(""),
    _: str = Depends(require_auth),
):
    raw = json.dumps({"server": server.strip(), "port": port, "username": username.strip(), "password": password})
    parse_proxy(kind, raw)
    with get_db() as conn:
        conn.execute("INSERT INTO routes(name, kind, raw_config, created_at) VALUES(?,?,?,?)", (name.strip() or kind.upper(), kind, raw, int(time.time())))
    return RedirectResponse("/", status_code=303)


@app.post("/routes/{route_id}/activate")
def activate_route(route_id: int, _: str = Depends(require_auth)):
    with get_db() as conn:
        if not conn.execute("SELECT id FROM routes WHERE id=?", (route_id,)).fetchone():
            raise HTTPException(404, "Route not found")
        conn.execute("UPDATE routes SET is_active=0")
        conn.execute("UPDATE routes SET is_active=1 WHERE id=?", (route_id,))
    return RedirectResponse("/", status_code=303)


@app.post("/keys")
def create_key(name: str = Form(...), _: str = Depends(require_auth)):
    with get_db() as conn:
        conn.execute("INSERT INTO access_keys(name, secret, enabled, created_at) VALUES(?,?,1,?)", (name.strip() or "client", secrets.token_hex(16), int(time.time())))
    return RedirectResponse("/", status_code=303)


@app.post("/start")
def start(_: str = Depends(require_auth)):
    ok, out = docker_up()
    if not ok:
        return PlainTextResponse(out, status_code=500)
    return RedirectResponse("/", status_code=303)


@app.post("/stop")
def stop(_: str = Depends(require_auth)):
    docker_down()
    return RedirectResponse("/", status_code=303)


@app.post("/check")
def check(_: str = Depends(require_auth)):
    ok, msg = check_runtime()
    with get_db() as conn:
        conn.execute("UPDATE routes SET last_status=?, last_error=? WHERE is_active=1", ("ok" if ok else "error", None if ok else msg))
    return PlainTextResponse(("OK: " if ok else "ERROR: ") + msg)


@app.get("/api/status")
def api_status(_: str = Depends(require_auth)):
    with get_db() as conn:
        active = conn.execute("SELECT id,name,kind,last_status,last_error FROM routes WHERE is_active=1").fetchone()
        keys = conn.execute("SELECT name,secret,enabled FROM access_keys ORDER BY id").fetchall()

    ps = run(["docker", "ps", "--filter", "name=telemt-cascade", "--format", "{{.Names}} {{.Status}}"], timeout=20)
    return {
        "public_host": setting("public_host", PUBLIC_IP),
        "listen_port": int(setting("listen_port", "443")),
        "fake_tls_domain": setting("fake_tls_domain", "vk.com"),
        "running": "telemt-cascade" in ps.stdout,
        "active_route": dict(active) if active else None,
        "links": [{"name": k["name"], "enabled": bool(k["enabled"]), "link": mtproto_link(k["secret"])} for k in keys],
    }


@app.get("/api/runtime")
def api_runtime(_: str = Depends(require_auth)):
    write_runtime()
    return {
        "compose": (APP_DIR / "docker-compose.yml").read_text(),
        "sing_box": json.loads((RUNTIME_DIR / "sing-box.json").read_text()),
        "telemt": (RUNTIME_DIR / "telemt.toml").read_text(),
    }
PYAPP

cat > "${APP_DIR}/requirements.txt" <<'REQ'
fastapi==0.115.6
uvicorn[standard]==0.34.0
python-multipart==0.0.20
REQ

python3 -m venv "${APP_DIR}/venv"
"${APP_DIR}/venv/bin/pip" install --upgrade pip wheel
"${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements.txt"

cat > "${APP_DIR}/panel.env" <<ENV
PANEL_SECRET=${PANEL_SECRET}
PUBLIC_IP=${PUBLIC_IP}
TELEMT_IMAGE=ghcr.io/telemt/telemt:3.4.14
SING_BOX_IMAGE=ghcr.io/sagernet/sing-box:latest
ENV

chmod 0600 "${APP_DIR}/panel.env"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<UNIT
[Unit]
Description=TeleMT Cascade Test Panel
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/panel.env
ExecStart=${APP_DIR}/venv/bin/uvicorn app:app --host 0.0.0.0 --port ${APP_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

ufw allow "${APP_PORT}/tcp" >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true

echo
echo "============================================================"
echo " TeleMT Cascade Test Panel installed"
echo "============================================================"
echo " Panel:    http://${PUBLIC_IP}:${APP_PORT}"
echo " Login:    admin"
echo " Password: ${PANEL_SECRET}"
echo
echo " API status:"
echo " curl -u admin:${PANEL_SECRET} http://${PUBLIC_IP}:${APP_PORT}/api/status"
echo
echo " Next:"
echo " 1) Open panel"
echo " 2) Add VLESS or SOCKS/HTTP route"
echo " 3) Activate route"
echo " 4) Press Start / apply"
echo " 5) Copy generated Telegram proxy link"
echo "============================================================"
