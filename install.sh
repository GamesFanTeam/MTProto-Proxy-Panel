#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="telemt-wdtt-panel"
APP_VERSION="0.1.1"
PANEL_PORT="8787"
TELEMT_PORT="443"
TELEMT_API_LISTEN="127.0.0.1:9091"
TELEMT_TLS_DOMAIN="vk.com"
TELEMT_USER="telemt"
TELEMT_CONFIG_DIR="/etc/telemt"
TELEMT_CONFIG_FILE="/etc/telemt/telemt.toml"
TELEMT_WORKDIR="/opt/telemt"
PANEL_DIR="/opt/telemt-panel"
PANEL_ETC_DIR="/etc/telemt-panel"
PANEL_STATE_DIR="/var/lib/telemt-panel"
PANEL_LOG_DIR="/var/log/telemt-panel"
INSTALL_LOG="/var/log/telemt-wdtt-panel-install.log"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date '+%F %T')" "$*" | tee -a "$INSTALL_LOG"; }
warn() { printf '\033[1;33m[%s] WARNING:\033[0m %s\n' "$(date '+%F %T')" "$*" | tee -a "$INSTALL_LOG"; }
fatal() { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(date '+%F %T')" "$*" | tee -a "$INSTALL_LOG" >&2; exit 1; }

trap 'fatal "Installation failed at line $LINENO. See $INSTALL_LOG"' ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || fatal "Run as root: sudo bash $0"
}

require_ubuntu_2404() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
      warn "This installer is targeted at Ubuntu 24.04. Detected: ${PRETTY_NAME:-unknown}. Continuing anyway."
    fi
  fi
}

random_hex() { openssl rand -hex "$1"; }
random_password() { openssl rand -base64 32 | tr -d '=+/\n' | cut -c1-24; }

get_public_ip() {
  local ip=""
  ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I | awk '{print $1}')"
  fi
  printf '%s' "$ip"
}

install_packages() {
  log "Installing system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    ca-certificates curl wget jq openssl tar gzip xz-utils unzip \
    python3 python3-venv python3-pip \
    iproute2 net-tools lsof ufw git sshpass
}

install_telemt_binary() {
  log "Installing latest telemt binary"
  local arch libc asset tmp
  arch="$(uname -m)"
  libc="gnu"
  if ldd --version 2>&1 | grep -qi musl; then libc="musl"; fi
  asset="https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz"
  tmp="$(mktemp -d)"
  wget -qO- "$asset" | tar -xz -C "$tmp"
  install -m 0755 "$tmp/telemt" /usr/local/bin/telemt
  rm -rf "$tmp"
  /usr/local/bin/telemt --version >/dev/null 2>&1 || true
}

create_telemt_config() {
  log "Creating telemt service and FakeTLS config"
  local public_host default_secret
  public_host="$(get_public_ip)"
  default_secret="$(random_hex 16)"

  useradd -d "$TELEMT_WORKDIR" -m -r -U "$TELEMT_USER" 2>/dev/null || true
  mkdir -p "$TELEMT_CONFIG_DIR" "$TELEMT_WORKDIR"

  cat > "$TELEMT_CONFIG_FILE" <<EOF_TELEMT
# Managed by telemt-wdtt-panel ${APP_VERSION}

[general]
use_middle_proxy = false
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${public_host}"
public_port = ${TELEMT_PORT}

[server]
port = ${TELEMT_PORT}

[server.api]
enabled = true
listen = "${TELEMT_API_LISTEN}"
whitelist = ["127.0.0.1/32", "::1/128"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${TELEMT_TLS_DOMAIN}"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
default = "${default_secret}"
EOF_TELEMT

  chown -R "$TELEMT_USER:$TELEMT_USER" "$TELEMT_CONFIG_DIR" "$TELEMT_WORKDIR"
  chmod 0640 "$TELEMT_CONFIG_FILE"

  cat > /etc/systemd/system/telemt.service <<'EOF_SERVICE'
[Unit]
Description=Telemt MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  systemctl daemon-reload
  systemctl enable --now telemt
}

wait_for_telemt() {
  log "Waiting for telemt port ${TELEMT_PORT} and local API"
  local i
  for i in $(seq 1 90); do
    if ss -ltn | awk '{print $4}' | grep -Eq "(:|\])${TELEMT_PORT}$"; then
      if curl -fsS --max-time 2 "http://${TELEMT_API_LISTEN}/v1/users" >/dev/null 2>&1; then
        log "telemt is up"
        return 0
      fi
    fi
    sleep 1
  done
  warn "telemt did not become fully ready within 90 seconds. Panel will still be installed; check: journalctl -u telemt -e"
}

create_panel_app() {
  log "Creating Flask panel"
  mkdir -p "$PANEL_DIR" "$PANEL_ETC_DIR" "$PANEL_STATE_DIR" "$PANEL_LOG_DIR"

  cat > "$PANEL_DIR/app.py" <<'PY_APP'
from __future__ import annotations

import contextlib
import datetime as dt
import html
import json
import os
import re
import secrets
import shlex
import socket
import sqlite3
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import paramiko
import requests
from flask import Flask, flash, redirect, render_template_string, request, session, url_for
from werkzeug.security import check_password_hash

APP_VERSION = "0.1.1"
BASE_DIR = Path("/opt/telemt-panel")
DB_PATH = Path(os.environ.get("PANEL_DB", "/var/lib/telemt-panel/panel.sqlite3"))
TELEMT_CONFIG = Path(os.environ.get("TELEMT_CONFIG", "/etc/telemt/telemt.toml"))
TELEMT_API = os.environ.get("TELEMT_API", "http://127.0.0.1:9091")
PANEL_SECRET_KEY = os.environ.get("PANEL_SECRET_KEY", secrets.token_hex(32))
PANEL_PASSWORD_HASH = os.environ.get("PANEL_PASSWORD_HASH", "")
DEFAULT_TLS_DOMAIN = "vk.com"
DEFAULT_TELEMT_PORT = 443
DEFAULT_CASCADE_DTLS = 56000
DEFAULT_CASCADE_WG = 56001
DEFAULT_CASCADE_TUN = 9000

app = Flask(__name__)
app.secret_key = PANEL_SECRET_KEY
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax")

TELEGRAM_DCS = [
    ("149.154.167.50", 443),
    ("149.154.175.50", 443),
    ("91.108.56.130", 443),
]

SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS accesses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    secret TEXT NOT NULL,
    link_tls TEXT DEFAULT '',
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS cascade (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    host TEXT DEFAULT '',
    public_host TEXT DEFAULT '',
    ssh_port INTEGER DEFAULT 22,
    ssh_user TEXT DEFAULT 'root',
    ssh_password TEXT DEFAULT '',
    main_password TEXT DEFAULT '',
    telegram_admin_id TEXT DEFAULT '',
    telegram_bot_token TEXT DEFAULT '',
    dtls_port INTEGER DEFAULT 56000,
    wg_port INTEGER DEFAULT 56001,
    tun_port INTEGER DEFAULT 9000,
    vk_hashes TEXT DEFAULT '',
    last_deploy_log TEXT DEFAULT '',
    updated_at TEXT DEFAULT ''
);
"""

STATUS_CLASS = {"ok": "ok", "warn": "warn", "bad": "bad", "unknown": "muted"}


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def db() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    conn.execute(
        "INSERT OR IGNORE INTO settings(key, value) VALUES(?, ?)",
        ("public_host", detect_public_ip()),
    )
    conn.execute(
        "INSERT OR IGNORE INTO settings(key, value) VALUES(?, ?)",
        ("tls_domain", DEFAULT_TLS_DOMAIN),
    )
    conn.execute(
        "INSERT OR IGNORE INTO settings(key, value) VALUES(?, ?)",
        ("route_mode", "direct"),
    )
    conn.execute(
        "INSERT OR IGNORE INTO cascade(id, updated_at) VALUES(1, ?)",
        (now_iso(),),
    )
    if conn.execute("SELECT COUNT(*) FROM accesses").fetchone()[0] == 0:
        conn.execute(
            "INSERT INTO accesses(username, secret, created_at) VALUES(?, ?, ?)",
            ("default", secrets.token_hex(16), now_iso()),
        )
    conn.commit()
    return conn


def get_setting(key: str, default: str = "") -> str:
    with db() as conn:
        row = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return str(row["value"]) if row else default


def set_setting(key: str, value: str) -> None:
    with db() as conn:
        conn.execute(
            "INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value),
        )
        conn.commit()


def detect_public_ip() -> str:
    for url in ("https://api.ipify.org", "https://ifconfig.me"):
        try:
            r = requests.get(url, timeout=4)
            if r.ok and r.text.strip():
                return r.text.strip()
        except Exception:
            pass
    try:
        return socket.gethostbyname(socket.gethostname())
    except Exception:
        return "SERVER_IP"


def run(cmd: list[str], timeout: int = 20) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, check=False)
        return p.returncode, p.stdout.strip()
    except Exception as exc:
        return 1, str(exc)


def socket_open(host: str, port: int, timeout: float = 2.0) -> bool:
    with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as s:
        s.settimeout(timeout)
        return s.connect_ex((host, port)) == 0


def service_active(name: str) -> bool:
    code, out = run(["systemctl", "is-active", name], timeout=5)
    return code == 0 and out.strip() == "active"


def status_badge(label: str, state: str, detail: str = "") -> dict[str, str]:
    return {"label": label, "state": state, "detail": detail, "class": STATUS_CLASS.get(state, "muted")}


def telemt_api_json(path: str, timeout: int = 4) -> dict[str, Any] | None:
    try:
        r = requests.get(f"{TELEMT_API}{path}", timeout=timeout)
        if r.ok:
            return r.json()
    except Exception:
        return None
    return None


def get_statuses() -> list[dict[str, str]]:
    statuses: list[dict[str, str]] = []

    ready = telemt_api_json("/v1/health/ready")
    users_api = telemt_api_json("/v1/users")
    telemt_active = service_active("telemt")
    if telemt_active and users_api is not None:
        statuses.append(status_badge("telemt", "ok", "systemd active, API отвечает"))
    elif telemt_active:
        statuses.append(status_badge("telemt", "warn", "systemd active, API пока не отвечает"))
    else:
        statuses.append(status_badge("telemt", "bad", "systemd inactive"))

    if socket_open("127.0.0.1", DEFAULT_TELEMT_PORT):
        statuses.append(status_badge("TCP :443", "ok", "listener открыт"))
    else:
        statuses.append(status_badge("TCP :443", "bad", "listener не найден"))

    telegram_ok = False
    telegram_detail = ""
    for host, port in TELEGRAM_DCS:
        if socket_open(host, port, timeout=2.0):
            telegram_ok = True
            telegram_detail = f"{host}:{port} reachable"
            break
    if telegram_ok:
        statuses.append(status_badge("Telegram DC", "ok", telegram_detail))
    else:
        statuses.append(status_badge("Telegram DC", "bad", "прямой TCP до DC не проходит"))

    if isinstance(ready, dict):
        statuses.append(status_badge("telemt readiness", "ok", "HTTP ready endpoint отвечает"))
    else:
        statuses.append(status_badge("telemt readiness", "warn", "ready endpoint недоступен/не поддерживается"))

    cascade = get_cascade_row()
    if cascade and cascade.get("host"):
        remote_state, detail = remote_service_state(cascade, "wdtt", timeout=7)
        statuses.append(status_badge("Cascade WDTT", remote_state, detail))
    else:
        statuses.append(status_badge("Cascade WDTT", "unknown", "ещё не настроен"))
    return statuses


def valid_username(username: str) -> bool:
    return re.fullmatch(r"[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,31}", username) is not None


def get_accesses() -> list[sqlite3.Row]:
    with db() as conn:
        return list(conn.execute("SELECT * FROM accesses ORDER BY id ASC"))


def write_telemt_config() -> None:
    public_host = get_setting("public_host", detect_public_ip()).strip() or detect_public_ip()
    tls_domain = get_setting("tls_domain", DEFAULT_TLS_DOMAIN).strip() or DEFAULT_TLS_DOMAIN
    accesses = get_accesses()
    access_lines = "\n".join(f'{row["username"]} = "{row["secret"]}"' for row in accesses)
    content = f'''# Managed by telemt-wdtt-panel {APP_VERSION}

[general]
use_middle_proxy = false
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "{public_host}"
public_port = {DEFAULT_TELEMT_PORT}

[server]
port = {DEFAULT_TELEMT_PORT}

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "{tls_domain}"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
{access_lines}
'''
    backup = TELEMT_CONFIG.with_suffix(f".toml.bak-{int(time.time())}")
    if TELEMT_CONFIG.exists():
        backup.write_text(TELEMT_CONFIG.read_text())
    fd, tmp_name = tempfile.mkstemp(prefix="telemt.", suffix=".toml", dir=str(TELEMT_CONFIG.parent))
    with os.fdopen(fd, "w") as f:
        f.write(content)
    os.replace(tmp_name, TELEMT_CONFIG)
    run(["chown", "telemt:telemt", str(TELEMT_CONFIG)], timeout=5)
    run(["chmod", "0640", str(TELEMT_CONFIG)], timeout=5)
    code, out = run(["systemctl", "restart", "telemt"], timeout=20)
    if code != 0:
        raise RuntimeError(out or "systemctl restart telemt failed")
    refresh_telemt_links()


def refresh_telemt_links() -> None:
    time.sleep(1.5)
    data = telemt_api_json("/v1/users", timeout=8)
    if not data:
        return
    users = data.get("data", []) if isinstance(data, dict) else []
    with db() as conn:
        for item in users:
            username = item.get("username")
            links = item.get("links", {}) or {}
            tls_links = links.get("tls") or []
            link = tls_links[0] if tls_links else ""
            if username and link:
                conn.execute("UPDATE accesses SET link_tls=? WHERE username=?", (link, username))
        conn.commit()


def ssh_client(cascade: dict[str, Any], timeout: int = 12) -> paramiko.SSHClient:
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        hostname=str(cascade["host"]),
        port=int(cascade.get("ssh_port") or 22),
        username=str(cascade.get("ssh_user") or "root"),
        password=str(cascade.get("ssh_password") or ""),
        timeout=timeout,
        banner_timeout=timeout,
        auth_timeout=timeout,
        look_for_keys=False,
        allow_agent=False,
    )
    return client


def remote_exec(cascade: dict[str, Any], command: str, timeout: int = 60) -> tuple[int, str]:
    try:
        client = ssh_client(cascade, timeout=min(timeout, 20))
        stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
        code = stdout.channel.recv_exit_status()
        out = stdout.read().decode(errors="replace") + stderr.read().decode(errors="replace")
        client.close()
        return code, out.strip()
    except Exception as exc:
        return 255, str(exc)


def remote_service_state(cascade: dict[str, Any], service: str, timeout: int = 8) -> tuple[str, str]:
    if not cascade or not cascade.get("host"):
        return "unknown", "IP каскадного VPS не задан"
    code, out = remote_exec(cascade, f"systemctl cat {shlex.quote(service)} >/dev/null 2>&1 && systemctl is-active {shlex.quote(service)} || echo not-installed", timeout=timeout)
    if code == 255:
        return "bad", f"SSH: {out}"
    active = out.splitlines()[-1].strip() if out.strip() else "unknown"
    if active == "active":
        dtls = int(cascade.get("dtls_port") or DEFAULT_CASCADE_DTLS)
        wg = int(cascade.get("wg_port") or DEFAULT_CASCADE_WG)
        pcode, pout = remote_exec(cascade, f"ss -H -lunp | grep -E ':({dtls}|{wg})\\s' || true", timeout=timeout)
        if pcode != 255 and str(dtls) in pout and str(wg) in pout:
            return "ok", f"wdtt active, UDP {dtls}/{wg} слушают"
        return "warn", f"wdtt active, но UDP listeners не подтверждены"
    if active == "not-installed":
        return "bad", "wdtt.service не установлен / сборка не завершилась"
    if active in {"inactive", "failed"}:
        return "bad", f"remote systemd {active}"
    return "unknown", active


def get_cascade_row() -> dict[str, Any]:
    with db() as conn:
        row = conn.execute("SELECT * FROM cascade WHERE id=1").fetchone()
        return dict(row) if row else {}


def save_cascade_form(form: dict[str, str]) -> dict[str, Any]:
    fields = {
        "host": form.get("host", "").strip(),
        "public_host": form.get("host", "").strip(),
        "ssh_port": int(form.get("ssh_port") or 22),
        "ssh_user": form.get("ssh_user", "root").strip() or "root",
        "ssh_password": form.get("ssh_password", ""),
        "main_password": form.get("main_password", "").strip() or secrets.token_urlsafe(18),
        "telegram_admin_id": form.get("telegram_admin_id", "").strip(),
        "telegram_bot_token": form.get("telegram_bot_token", "").strip(),
        "dtls_port": int(form.get("dtls_port") or DEFAULT_CASCADE_DTLS),
        "wg_port": int(form.get("wg_port") or DEFAULT_CASCADE_WG),
        "tun_port": int(form.get("tun_port") or DEFAULT_CASCADE_TUN),
        "vk_hashes": normalize_vk_hashes(form.get("vk_hashes", "")),
        "updated_at": now_iso(),
    }
    if not fields["host"]:
        raise ValueError("Укажи IP каскадного VPS для деплоя")
    if not fields["ssh_password"]:
        # keep old password if user left it blank
        old = get_cascade_row()
        fields["ssh_password"] = old.get("ssh_password", "") if old else ""
    with db() as conn:
        conn.execute(
            """
            UPDATE cascade SET host=?, public_host=?, ssh_port=?, ssh_user=?, ssh_password=?, main_password=?,
                telegram_admin_id=?, telegram_bot_token=?, dtls_port=?, wg_port=?, tun_port=?, vk_hashes=?, updated_at=?
            WHERE id=1
            """,
            (
                fields["host"], fields["public_host"], fields["ssh_port"], fields["ssh_user"], fields["ssh_password"],
                fields["main_password"], fields["telegram_admin_id"], fields["telegram_bot_token"], fields["dtls_port"],
                fields["wg_port"], fields["tun_port"], fields["vk_hashes"], fields["updated_at"],
            ),
        )
        conn.commit()
    return get_cascade_row()


def normalize_vk_hashes(value: str) -> str:
    parts: list[str] = []
    for raw in re.split(r"[,\s]+", value.strip()):
        raw = raw.strip()
        if not raw:
            continue
        raw = raw.split("?")[0].rstrip("/").split("/")[-1]
        parts.append(raw)
    return ",".join(parts[:4])


def wdtt_link(cascade: dict[str, Any]) -> str:
    if not cascade or not cascade.get("public_host") or not cascade.get("main_password") or not cascade.get("vk_hashes"):
        return ""
    return "wdtt://{host}:{dtls}:{wg}:{tun}:{password}:{hashes}".format(
        host=cascade["public_host"],
        dtls=cascade["dtls_port"],
        wg=cascade["wg_port"],
        tun=cascade["tun_port"],
        password=cascade["main_password"],
        hashes=cascade["vk_hashes"],
    )


def remote_deploy_script(cascade: dict[str, Any]) -> str:
    password = shlex.quote(str(cascade["main_password"]))
    admin = shlex.quote(str(cascade.get("telegram_admin_id") or ""))
    token = shlex.quote(str(cascade.get("telegram_bot_token") or ""))
    dtls = int(cascade.get("dtls_port") or DEFAULT_CASCADE_DTLS)
    wg = int(cascade.get("wg_port") or DEFAULT_CASCADE_WG)
    return f"""#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl git golang-go iproute2 iptables nftables
mkdir -p /opt /etc/wdtt /var/log/wdtt
if [[ -d /opt/proxy-turn-vk-android/.git ]]; then
  git -C /opt/proxy-turn-vk-android fetch --all --prune
  git -C /opt/proxy-turn-vk-android reset --hard origin/main
else
  rm -rf /opt/proxy-turn-vk-android
  git clone --depth=1 https://github.com/amurcanov/proxy-turn-vk-android /opt/proxy-turn-vk-android
fi
cd /opt/proxy-turn-vk-android
go env -w GOTOOLCHAIN=auto
go mod tidy
GOFLAGS=-mod=mod go build -trimpath -ldflags='-s -w' -o /usr/local/bin/wdtt-server ./server.go
chmod 0755 /usr/local/bin/wdtt-server
cat > /etc/systemd/system/wdtt.service <<'EOF_WDTT_SERVICE'
[Unit]
Description=WDTT WireGuard over TURN server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/etc/wdtt
ExecStart=/usr/local/bin/wdtt-server -listen 0.0.0.0:{dtls} -wg-port {wg} -config-dir /etc/wdtt -password {password} -admin {admin} -bot-token {token}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF_WDTT_SERVICE
systemctl daemon-reload
if command -v ufw >/dev/null 2>&1; then
  ufw allow {dtls}/udp || true
  ufw allow {wg}/udp || true
fi
systemctl enable --now wdtt
sleep 2
systemctl --no-pager --full status wdtt || true
"""


def deploy_cascade(cascade: dict[str, Any]) -> str:
    script = remote_deploy_script(cascade)
    try:
        client = ssh_client(cascade, timeout=20)
        sftp = client.open_sftp()
        remote_path = "/tmp/telemt-wdtt-deploy.sh"
        with sftp.file(remote_path, "w") as f:
            f.write(script)
        sftp.chmod(remote_path, 0o700)
        sftp.close()
        stdin, stdout, stderr = client.exec_command(f"bash {remote_path}", timeout=900)
        code = stdout.channel.recv_exit_status()
        out = stdout.read().decode(errors="replace") + stderr.read().decode(errors="replace")
        client.close()
        log = f"exit={code}\n{out}"
    except Exception as exc:
        log = f"ERROR: {exc}"
    with db() as conn:
        conn.execute("UPDATE cascade SET last_deploy_log=?, updated_at=? WHERE id=1", (log[-20000:], now_iso()))
        conn.commit()
    return log


def check_cascade(cascade: dict[str, Any]) -> str:
    if not cascade or not cascade.get("host"):
        return "ERROR: IP каскадного VPS не задан"
    dtls = int(cascade.get("dtls_port") or DEFAULT_CASCADE_DTLS)
    wg = int(cascade.get("wg_port") or DEFAULT_CASCADE_WG)
    cmd = f"""
set +e
echo '=== host ==='
hostname -f 2>/dev/null || hostname
echo '=== wdtt service file ==='
systemctl cat wdtt 2>&1
echo '=== wdtt active ==='
systemctl is-active wdtt 2>&1
echo '=== wdtt status ==='
systemctl --no-pager --full status wdtt 2>&1 | tail -80
echo '=== udp listeners expected {dtls}/{wg} ==='
ss -lunp 2>&1 | grep -E ':({dtls}|{wg})\\s' || true
echo '=== last logs ==='
journalctl -u wdtt -n 120 --no-pager 2>&1
echo '=== firewall ==='
ufw status verbose 2>/dev/null || true
"""
    code, out = remote_exec(cascade, cmd, timeout=90)
    log = f"exit={code}\n{out}"
    with db() as conn:
        conn.execute("UPDATE cascade SET last_deploy_log=?, updated_at=? WHERE id=1", (log[-20000:], now_iso()))
        conn.commit()
    return log


def require_login():
    return session.get("auth") is True


@app.before_request
def protect() -> Any:
    if request.endpoint in {"login", "login_post", "static"}:
        return None
    if not require_login():
        return redirect(url_for("login"))
    return None


@app.get("/login")
def login() -> str:
    return render_template_string(LOGIN_HTML)


@app.post("/login")
def login_post():
    password = request.form.get("password", "")
    if PANEL_PASSWORD_HASH and check_password_hash(PANEL_PASSWORD_HASH, password):
        session.clear()
        session["auth"] = True
        return redirect(url_for("index"))
    flash("Неверный пароль", "bad")
    return redirect(url_for("login"))


@app.get("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.get("/")
def index() -> str:
    refresh_telemt_links()
    cascade = get_cascade_row()
    return render_template_string(
        INDEX_HTML,
        version=APP_VERSION,
        statuses=get_statuses(),
        accesses=get_accesses(),
        public_host=get_setting("public_host", detect_public_ip()),
        tls_domain=get_setting("tls_domain", DEFAULT_TLS_DOMAIN),
        route_mode=get_setting("route_mode", "direct"),
        cascade=cascade,
        wdtt_link=wdtt_link(cascade),
    )


@app.post("/settings")
def update_settings():
    public_host = request.form.get("public_host", "").strip()
    tls_domain = request.form.get("tls_domain", "").strip() or DEFAULT_TLS_DOMAIN
    if not public_host:
        flash("Host/IP для ссылок не должен быть пустым", "bad")
        return redirect(url_for("index"))
    set_setting("public_host", public_host)
    set_setting("tls_domain", tls_domain)
    try:
        write_telemt_config()
        flash("Настройки telemt применены", "ok")
    except Exception as exc:
        flash(f"Ошибка применения настроек: {exc}", "bad")
    return redirect(url_for("index"))


@app.post("/access/create")
def create_access():
    username = request.form.get("username", "").strip()
    if not valid_username(username):
        flash("Username: только латиница/цифры/._-, до 32 символов", "bad")
        return redirect(url_for("index"))
    with db() as conn:
        try:
            conn.execute(
                "INSERT INTO accesses(username, secret, created_at) VALUES(?, ?, ?)",
                (username, secrets.token_hex(16), now_iso()),
            )
            conn.commit()
        except sqlite3.IntegrityError:
            flash("Такой доступ уже есть", "bad")
            return redirect(url_for("index"))
    try:
        write_telemt_config()
        flash(f"Доступ {username} создан", "ok")
    except Exception as exc:
        flash(f"Доступ создан в БД, но telemt не перезапустился: {exc}", "bad")
    return redirect(url_for("index"))


@app.post("/access/<int:access_id>/delete")
def delete_access(access_id: int):
    with db() as conn:
        count = conn.execute("SELECT COUNT(*) FROM accesses").fetchone()[0]
        if count <= 1:
            flash("Нельзя удалить последний доступ", "bad")
            return redirect(url_for("index"))
        conn.execute("DELETE FROM accesses WHERE id=?", (access_id,))
        conn.commit()
    try:
        write_telemt_config()
        flash("Доступ удалён", "ok")
    except Exception as exc:
        flash(f"Доступ удалён из БД, но telemt не перезапустился: {exc}", "bad")
    return redirect(url_for("index"))


@app.post("/telemt/restart")
def restart_telemt():
    code, out = run(["systemctl", "restart", "telemt"], timeout=20)
    flash("telemt перезапущен" if code == 0 else f"Ошибка restart telemt: {out}", "ok" if code == 0 else "bad")
    return redirect(url_for("index"))


@app.post("/cascade/save")
def cascade_save():
    try:
        save_cascade_form(request.form)  # type: ignore[arg-type]
        flash("Настройки cascade сохранены", "ok")
    except Exception as exc:
        flash(str(exc), "bad")
    return redirect(url_for("index"))


@app.post("/cascade/deploy")
def cascade_deploy():
    try:
        cascade = save_cascade_form(request.form)  # type: ignore[arg-type]
        log = deploy_cascade(cascade)
        if log.startswith("ERROR") or "exit=0" not in log:
            flash("Деплой завершился с ошибкой, смотри лог ниже", "bad")
        else:
            flash("Cascade задеплоен и запущен", "ok")
    except Exception as exc:
        flash(f"Ошибка деплоя: {exc}", "bad")
    return redirect(url_for("index") + "#cascade")


@app.post("/cascade/action")
def cascade_action():
    action = request.form.get("action", "restart")
    if action not in {"start", "stop", "restart"}:
        action = "restart"
    cascade = get_cascade_row()
    if not cascade or not cascade.get("host"):
        flash("Сначала укажи IP каскадного VPS и сохрани настройки", "bad")
        return redirect(url_for("index") + "#cascade")
    code, out = remote_exec(cascade, f"systemctl {action} wdtt && systemctl is-active wdtt; journalctl -u wdtt -n 40 --no-pager", timeout=45)
    with db() as conn:
        conn.execute("UPDATE cascade SET last_deploy_log=?, updated_at=? WHERE id=1", (f"action={action} exit={code}\n{out}"[-20000:], now_iso()))
        conn.commit()
    flash(f"cascade {action}: {out.splitlines()[0] if out else 'done'}", "ok" if code == 0 else "bad")
    return redirect(url_for("index") + "#cascade")


@app.post("/cascade/check")
def cascade_check():
    cascade = get_cascade_row()
    log = check_cascade(cascade)
    flash("Проверка cascade выполнена, смотри лог ниже", "ok" if not log.startswith("ERROR") else "bad")
    return redirect(url_for("index") + "#cascade")


@app.post("/route/cascade")
def route_cascade():
    mode = request.form.get("mode", "direct")
    if mode not in {"direct", "cascade"}:
        mode = "direct"
    set_setting("route_mode", mode)
    if mode == "cascade":
        flash("Режим cascade сохранён как future hook. Для реального заворота telemt нужен Linux WDTT-client/маршрутизация на front-сервере.", "warn")
    else:
        flash("Режим direct сохранён", "ok")
    return redirect(url_for("index"))


LOGIN_HTML = """
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Telemt Panel Login</title><style>{{ css }}</style></head><body class="login-body">
<div class="login-card"><h1>Telemt Panel</h1><p>Вход в панель управления</p>
{% with messages = get_flashed_messages(with_categories=true) %}{% for cat,msg in messages %}<div class="flash {{cat}}">{{msg}}</div>{% endfor %}{% endwith %}
<form method="post"><input type="password" name="password" placeholder="Пароль панели" autofocus required><button>Войти</button></form></div>
</body></html>
""".replace("{{ css }}", """
:root{--bg:#0b1020;--card:#121a30;--text:#e9eefc;--muted:#94a3b8;--accent:#5eead4;--bad:#fb7185;--warn:#fbbf24;--ok:#34d399;--border:#26324d}*{box-sizing:border-box}body{margin:0;font-family:Inter,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:linear-gradient(135deg,#0b1020,#111827);color:var(--text)}.login-body{min-height:100vh;display:grid;place-items:center}.login-card{width:min(420px,92vw);background:rgba(18,26,48,.9);border:1px solid var(--border);border-radius:24px;padding:32px;box-shadow:0 24px 80px rgba(0,0,0,.35)}h1{margin:0 0 8px;font-size:32px}p{color:var(--muted)}input,textarea,select{width:100%;border:1px solid var(--border);background:#0f172a;color:var(--text);border-radius:12px;padding:12px 14px;margin:6px 0 12px}button,.btn{border:0;border-radius:12px;background:var(--accent);color:#042f2e;padding:11px 15px;font-weight:700;cursor:pointer;text-decoration:none}.flash{padding:12px;border-radius:12px;margin:12px 0}.flash.bad{background:rgba(251,113,133,.12);color:var(--bad)}.flash.ok{background:rgba(52,211,153,.12);color:var(--ok)}.flash.warn{background:rgba(251,191,36,.12);color:var(--warn)}
""")

INDEX_HTML = """
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Telemt WDTT Panel</title>
<style>
:root{--bg:#080d18;--card:#111827;--card2:#0f172a;--text:#e5e7eb;--muted:#94a3b8;--accent:#5eead4;--bad:#fb7185;--warn:#fbbf24;--ok:#34d399;--border:#26324d}*{box-sizing:border-box}body{margin:0;font-family:Inter,system-ui,-apple-system,Segoe UI,Roboto,Arial;background:radial-gradient(circle at top left,#1e293b 0,#080d18 40%);color:var(--text)}a{color:var(--accent)}.wrap{max-width:1180px;margin:0 auto;padding:24px}.top{display:flex;gap:16px;align-items:center;justify-content:space-between;margin-bottom:22px}.brand h1{font-size:30px;margin:0}.brand p{margin:5px 0 0;color:var(--muted)}.grid{display:grid;grid-template-columns:repeat(12,1fr);gap:16px}.card{background:linear-gradient(180deg,rgba(17,24,39,.94),rgba(15,23,42,.94));border:1px solid var(--border);border-radius:20px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.25)}.span4{grid-column:span 4}.span6{grid-column:span 6}.span8{grid-column:span 8}.span12{grid-column:span 12}@media(max-width:900px){.span4,.span6,.span8{grid-column:span 12}.top{align-items:flex-start;flex-direction:column}}h2{margin:0 0 14px;font-size:20px}.status{display:flex;align-items:flex-start;justify-content:space-between;gap:10px;padding:12px;border:1px solid var(--border);border-radius:14px;background:rgba(15,23,42,.8);margin:8px 0}.pill{font-size:12px;font-weight:800;border-radius:999px;padding:5px 9px;text-transform:uppercase}.pill.ok{background:rgba(52,211,153,.15);color:var(--ok)}.pill.bad{background:rgba(251,113,133,.15);color:var(--bad)}.pill.warn{background:rgba(251,191,36,.15);color:var(--warn)}.pill.muted{background:rgba(148,163,184,.15);color:var(--muted)}.detail{color:var(--muted);font-size:13px;margin-top:4px;word-break:break-word}input,textarea,select{width:100%;border:1px solid var(--border);background:#0b1220;color:var(--text);border-radius:12px;padding:11px 12px;margin:5px 0 11px}textarea{min-height:90px}.row{display:grid;grid-template-columns:1fr 1fr;gap:12px}@media(max-width:700px){.row{grid-template-columns:1fr}}button,.btn{display:inline-block;border:0;border-radius:12px;background:var(--accent);color:#042f2e;padding:10px 14px;font-weight:800;cursor:pointer;text-decoration:none;margin:3px 3px 3px 0}.btn.secondary,button.secondary{background:#1f2937;color:var(--text);border:1px solid var(--border)}button.danger{background:var(--bad);color:#fff}.flash{padding:12px;border-radius:12px;margin:8px 0 16px;border:1px solid var(--border)}.flash.ok{background:rgba(52,211,153,.11);color:var(--ok)}.flash.bad{background:rgba(251,113,133,.11);color:var(--bad)}.flash.warn{background:rgba(251,191,36,.11);color:var(--warn)}table{width:100%;border-collapse:collapse}th,td{padding:10px;border-bottom:1px solid var(--border);text-align:left;vertical-align:top}th{color:var(--muted);font-weight:700}.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;word-break:break-all}.muted{color:var(--muted)}.copy{background:#0b1220;border:1px dashed var(--border);border-radius:12px;padding:10px;margin:8px 0;word-break:break-all}.footer{color:var(--muted);font-size:12px;margin-top:18px}
</style></head><body><div class="wrap">
<div class="top"><div class="brand"><h1>Telemt + WDTT Panel</h1><p>FakeTLS ee / SNI {{ tls_domain }} / panel v{{ version }}</p></div><a class="btn secondary" href="{{ url_for('logout') }}">Выйти</a></div>
{% with messages = get_flashed_messages(with_categories=true) %}{% for cat,msg in messages %}<div class="flash {{cat}}">{{msg}}</div>{% endfor %}{% endwith %}
<div class="grid">
<section class="card span4"><h2>Статусы</h2>{% for s in statuses %}<div class="status"><div><b>{{s.label}}</b><div class="detail">{{s.detail}}</div></div><span class="pill {{s.class}}">{{s.state}}</span></div>{% endfor %}</section>
<section class="card span8"><h2>Настройки telemt</h2><form method="post" action="{{ url_for('update_settings') }}"><div class="row"><div><label>Host/IP для tg-ссылок</label><input name="public_host" value="{{ public_host }}" required></div><div><label>FakeTLS SNI</label><input name="tls_domain" value="{{ tls_domain }}" required></div></div><button>Сохранить и перезапустить telemt</button></form><form method="post" action="{{ url_for('restart_telemt') }}"><button class="secondary">Только restart telemt</button></form></section>
<section class="card span12"><h2>MTProto proxy-доступы</h2><form method="post" action="{{ url_for('create_access') }}" class="row"><div><label>Имя доступа</label><input name="username" placeholder="user1" required></div><div style="align-self:end"><button>Создать доступ</button></div></form><table><thead><tr><th>ID</th><th>Username</th><th>Secret</th><th>FakeTLS link</th><th></th></tr></thead><tbody>{% for a in accesses %}<tr><td>{{a.id}}</td><td>{{a.username}}</td><td class="mono">{{a.secret}}</td><td>{% if a.link_tls %}<div class="copy mono">{{a.link_tls}}</div>{% else %}<span class="muted">link появится после ответа telemt API</span>{% endif %}</td><td><form method="post" action="{{ url_for('delete_access', access_id=a.id) }}" onsubmit="return confirm('Удалить доступ?')"><button class="danger">Удалить</button></form></td></tr>{% endfor %}</tbody></table></section>
<section class="card span12" id="cascade"><h2>Удалённый Cascade / WDTT deploy</h2><p class="muted">Укажи <b>IP второго VPS</b>. Панель подключится к нему по SSH, соберёт <code>wdtt-server</code>, создаст <code>wdtt.service</code>, откроет UDP-порты и покажет статус. Отдельного поля для public host больше нет: WDTT-ссылка автоматически использует этот же IP.</p><form method="post" action="{{ url_for('cascade_deploy') }}"><div class="row"><div><label>IP каскадного VPS для деплоя</label><input name="host" value="{{ cascade.host or '' }}" placeholder="например 123.45.67.89" required></div><div><label>SSH port</label><input type="number" name="ssh_port" value="{{ cascade.ssh_port or 22 }}"></div></div><div class="row"><div><label>SSH user</label><input name="ssh_user" value="{{ cascade.ssh_user or 'root' }}"></div><div><label>SSH password</label><input type="password" name="ssh_password" placeholder="оставь пустым, чтобы сохранить текущий"></div></div><div class="row"><div><label>Main tunnel password</label><input name="main_password" value="{{ cascade.main_password or '' }}" placeholder="если пусто — сгенерируется"></div><div><label>VK hash / join links, до 4 через запятую</label><input name="vk_hashes" value="{{ cascade.vk_hashes or '' }}" placeholder="vk.com/call/join/xxxxx"></div></div><div class="row"><div><label>Telegram admin_id, опционально</label><input name="telegram_admin_id" value="{{ cascade.telegram_admin_id or '' }}"></div><div><label>Telegram bot_token, опционально</label><input name="telegram_bot_token" value="{{ cascade.telegram_bot_token or '' }}"></div></div><div class="row"><div><label>DTLS UDP port</label><input type="number" name="dtls_port" value="{{ cascade.dtls_port or 56000 }}"></div><div><label>WG UDP port</label><input type="number" name="wg_port" value="{{ cascade.wg_port or 56001 }}"></div></div><label>Android/local TUN UDP port</label><input type="number" name="tun_port" value="{{ cascade.tun_port or 9000 }}"><button>Установить / переустановить cascade</button><button formaction="{{ url_for('cascade_save') }}" class="secondary">Только сохранить</button></form>{% if wdtt_link %}<h3>WDTT ссылка</h3><div class="copy mono">{{ wdtt_link }}</div>{% endif %}<form method="post" action="{{ url_for('cascade_check') }}"><button class="secondary">Проверить cascade</button></form><form method="post" action="{{ url_for('cascade_action') }}"><button name="action" value="start" class="secondary">Запустить cascade</button><button name="action" value="restart" class="secondary">Restart cascade</button><button name="action" value="stop" class="danger">Stop cascade</button></form>{% if cascade.last_deploy_log %}<h3>Последний deploy/check log</h3><textarea readonly class="mono" style="min-height:300px">{{ cascade.last_deploy_log }}</textarea>{% endif %}</section>
<section class="card span12"><h2>Маршрут telemt</h2><p class="muted">Сейчас telemt установлен в direct-режиме. Для настоящего маршрута <code>telemt → WDTT cascade → Telegram</code> нужен Linux WDTT-client на front-сервере и policy routing только для процесса telemt. В этой версии это сохранено как future hook, чтобы не делать фальшивую кнопку.</p><form method="post" action="{{ url_for('route_cascade') }}"><select name="mode"><option value="direct" {% if route_mode == 'direct' %}selected{% endif %}>direct</option><option value="cascade" {% if route_mode == 'cascade' %}selected{% endif %}>cascade hook</option></select><button>Сохранить режим</button></form></section>
</div><div class="footer">Config: /etc/telemt/telemt.toml · DB: /var/lib/telemt-panel/panel.sqlite3 · Logs: journalctl -u telemt-panel -f</div></div></body></html>
"""

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8787)
PY_APP
}

setup_panel_python() {
  log "Installing panel Python environment"
  python3 -m venv "$PANEL_DIR/venv"
  "$PANEL_DIR/venv/bin/pip" install --upgrade pip wheel >/dev/null
  "$PANEL_DIR/venv/bin/pip" install flask gunicorn requests paramiko werkzeug >/dev/null
  "$PANEL_DIR/venv/bin/python" -m py_compile "$PANEL_DIR/app.py"
}

create_panel_service() {
  log "Creating panel service"
  local panel_password secret_key password_hash public_ip
  if [[ -s "$PANEL_STATE_DIR/panel-password.txt" ]]; then
    panel_password="$(tr -d '\r\n' < "$PANEL_STATE_DIR/panel-password.txt")"
    log "Preserving existing panel password"
  else
    panel_password="$(random_password)"
  fi
  secret_key="$(random_hex 32)"
  password_hash="$($PANEL_DIR/venv/bin/python - <<PY
from werkzeug.security import generate_password_hash
print(generate_password_hash('${panel_password}'))
PY
)"
  public_ip="$(get_public_ip)"

  cat > "$PANEL_ETC_DIR/panel.env" <<EOF_ENV
PANEL_SECRET_KEY="${secret_key}"
PANEL_PASSWORD_HASH="${password_hash}"
PANEL_DB=${PANEL_STATE_DIR}/panel.sqlite3
TELEMT_CONFIG=${TELEMT_CONFIG_FILE}
TELEMT_API=http://${TELEMT_API_LISTEN}
EOF_ENV
  chmod 0600 "$PANEL_ETC_DIR/panel.env"

  cat > /etc/systemd/system/telemt-panel.service <<EOF_PANEL_SERVICE
[Unit]
Description=Telemt WDTT Flask Panel
After=network-online.target telemt.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${PANEL_DIR}
EnvironmentFile=${PANEL_ETC_DIR}/panel.env
ExecStart=${PANEL_DIR}/venv/bin/gunicorn -w 2 --timeout 900 -b 0.0.0.0:${PANEL_PORT} app:app
Restart=on-failure
RestartSec=3
UMask=0077

[Install]
WantedBy=multi-user.target
EOF_PANEL_SERVICE

  systemctl daemon-reload
  systemctl enable --now telemt-panel

  cat > "$PANEL_STATE_DIR/install-info.txt" <<EOF_INFO
Panel URL: http://${public_ip}:${PANEL_PORT}
Panel password: ${panel_password}
Telemt SNI: ${TELEMT_TLS_DOMAIN}
Telemt port: ${TELEMT_PORT}
Created: $(date -Is)
EOF_INFO
  chmod 0600 "$PANEL_STATE_DIR/install-info.txt"

  echo "$panel_password" > "$PANEL_STATE_DIR/panel-password.txt"
  chmod 0600 "$PANEL_STATE_DIR/panel-password.txt"
}

open_firewall() {
  log "Opening firewall ports"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${TELEMT_PORT}/tcp" || true
    ufw allow "${PANEL_PORT}/tcp" || true
  fi
}

print_summary() {
  local public_ip password first_link
  public_ip="$(get_public_ip)"
  password="$(cat "$PANEL_STATE_DIR/panel-password.txt")"
  first_link="$(curl -fsS --max-time 4 "http://${TELEMT_API_LISTEN}/v1/users" 2>/dev/null | jq -r '.data[0].links.tls[0] // empty' || true)"

  cat <<EOF_SUMMARY

============================================================
 ${APP_NAME} ${APP_VERSION} installed
============================================================

Panel URL:       http://${public_ip}:${PANEL_PORT}
Panel password:  ${password}

telemt:
  port:          ${TELEMT_PORT}/tcp
  FakeTLS SNI:   ${TELEMT_TLS_DOMAIN}
  config:        ${TELEMT_CONFIG_FILE}
  service:       systemctl status telemt

Panel:
  service:       systemctl status telemt-panel
  logs:          journalctl -u telemt-panel -f

EOF_SUMMARY

  if [[ -n "$first_link" ]]; then
    cat <<EOF_LINK
Default MTProto FakeTLS link:
${first_link}

EOF_LINK
  else
    warn "Could not fetch default telemt link yet. Open the panel or run: curl -s http://${TELEMT_API_LISTEN}/v1/users | jq"
  fi
}

migrate_existing_state() {
  log "Migrating existing panel state"
  "$PANEL_DIR/venv/bin/python" - <<'PY_MIGRATE' || true
from pathlib import Path
import sqlite3
path = Path('/var/lib/telemt-panel/panel.sqlite3')
if path.exists():
    with sqlite3.connect(path) as conn:
        try:
            conn.execute("UPDATE cascade SET public_host = host WHERE id = 1 AND COALESCE(host, '') != ''")
            conn.commit()
        except sqlite3.Error:
            pass
PY_MIGRATE
}

update_existing_panel() {
  log "Existing installation detected: updating Flask panel only"
  install_packages
  create_panel_app
  setup_panel_python
  create_panel_service
  migrate_existing_state
  systemctl restart telemt-panel
  print_summary
}

full_install() {
  install_packages
  install_telemt_binary
  create_telemt_config
  open_firewall
  wait_for_telemt
  create_panel_app
  setup_panel_python
  create_panel_service
  migrate_existing_state
  print_summary
}

main() {
  mkdir -p "$(dirname "$INSTALL_LOG")"
  touch "$INSTALL_LOG"
  require_root
  require_ubuntu_2404
  if [[ "${1:-}" == "--force-full" ]]; then
    full_install
  elif [[ -f "$PANEL_DIR/app.py" && -f /etc/systemd/system/telemt-panel.service ]]; then
    update_existing_panel
  else
    full_install
  fi
}

main "$@"
