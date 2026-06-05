#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

APP_VERSION="1.3.1-clean"
TELEMT_VERSION="3.4.13"
XRAY_VERSION="v26.6.1"
PANEL_PORT="8787"
TLS_DOMAIN="vk.com"
PUBLIC_HOST=""
ADMIN_PASSWORD=""

log() { printf '\n\033[1;36m[%s]\033[0m %s\n' "$1" "$2"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }


clean_previous_installation() {
  log "CLEAN" "Останавливаю и удаляю старую установку"
  systemctl stop mtproxy-panel.service telemt.service xray-cascade.service >/dev/null 2>&1 || true
  systemctl disable mtproxy-panel.service telemt.service xray-cascade.service >/dev/null 2>&1 || true

  rm -f /etc/systemd/system/mtproxy-panel.service
  rm -f /etc/systemd/system/telemt.service
  rm -f /etc/systemd/system/xray-cascade.service
  rm -rf /etc/systemd/system/mtproxy-panel.service.d
  systemctl daemon-reload >/dev/null 2>&1 || true

  rm -rf /opt/mtproxy-panel
  rm -rf /etc/mtproxy-panel
  rm -rf /etc/telemt
  rm -rf /etc/xray-cascade
  rm -rf /var/lib/telemt
  rm -rf /var/lib/xray-cascade

  rm -f /usr/local/bin/telemt
  rm -f /usr/local/bin/xray

  log "CLEAN" "Старая установка удалена"
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите установку командой: sudo bash install.sh"
[[ $# -eq 0 ]] || die "Параметры запуска не требуются. Используйте: sudo bash install.sh"

printf '\n\033[1;36mMTProxy Telemt + REALITY Cascade Panel v%s\033[0m\n' "$APP_VERSION"
printf 'Схема: Telegram -> telemt -> Xray SOCKS5 -> VLESS+REALITY cascade -> Telegram DC\n\n'
printf 'UI после установки: http://IP_СЕРВЕРА:8787 (логин admin, пароль появится в терминале)\n\n'
while true; do
  IFS= read -r -p "Введите домен прокси для tg://proxy ссылок (например proxy.example.ru): " PUBLIC_HOST </dev/tty \
    || die "Не удалось прочитать домен"
  PUBLIC_HOST="${PUBLIC_HOST,,}"
  PUBLIC_HOST="${PUBLIC_HOST%.}"
  if [[ "$PUBLIC_HOST" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
    break
  fi
  printf '\033[1;31mНекорректный домен. Укажите FQDN, например proxy.example.ru.\033[0m\n' >&2
done

# Все изменяемые настройки выполняются из панели после установки.
# Значение используется только как безопасный стартовый SNI до изменения в UI.
TLS_DOMAIN="vk.com"
PANEL_PORT="8787"

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "Базовый installer поддерживает Debian/Ubuntu; обнаружено: ${ID:-unknown}" ;;
  esac
else
  die "Не найден /etc/os-release"
fi
command -v systemctl >/dev/null || die "Требуется systemd"

clean_previous_installation

# Безопасная повторная установка: сохраняем работающие конфиги и убираем старые конфликтующие drop-in unit overrides.
EXISTING_PANEL_SETTINGS=0
[[ -s /etc/mtproxy-panel/settings.json ]] && EXISTING_PANEL_SETTINGS=1
BACKUP_DIR="/var/backups/mtproxy-panel/$(date -u +%Y%m%dT%H%M%SZ)-v${APP_VERSION}"
install -d -m 0700 "$BACKUP_DIR"
for keep in /etc/telemt/telemt.toml /etc/mtproxy-panel/settings.json /etc/xray-cascade/client.json /etc/systemd/system/mtproxy-panel.service; do
  if [[ -e "$keep" ]]; then
    cp -a --parents "$keep" "$BACKUP_DIR/" || true
  fi
done
rm -rf /etc/systemd/system/mtproxy-panel.service.d

log "1/10" "Устанавливаю системные зависимости"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl unzip python3 openssl >/dev/null

case "$(uname -m)" in
  x86_64|amd64)
    TELEMT_ARCH="x86_64"
    XRAY_ARCHIVE="Xray-linux-64.zip"
    ;;
  aarch64|arm64)
    TELEMT_ARCH="aarch64"
    XRAY_ARCHIVE="Xray-linux-arm64-v8a.zip"
    ;;
  *) die "Поддерживаются только x86_64 и aarch64" ;;
esac

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

log "2/10" "Устанавливаю telemt ${TELEMT_VERSION} (pinned)"
curl -fsSL --retry 3 \
  "https://github.com/telemt/telemt/releases/download/${TELEMT_VERSION}/telemt-${TELEMT_ARCH}-linux-gnu.tar.gz" \
  -o "$WORKDIR/telemt.tar.gz"
tar -xzf "$WORKDIR/telemt.tar.gz" -C "$WORKDIR"
[[ -x "$WORKDIR/telemt" ]] || die "В архиве telemt не найден бинарник"
install -m 0755 "$WORKDIR/telemt" /usr/local/bin/telemt

log "3/10" "Устанавливаю Xray-core ${XRAY_VERSION} (pinned)"
curl -fsSL --retry 3 \
  "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${XRAY_ARCHIVE}" \
  -o "$WORKDIR/xray.zip"
unzip -q -o "$WORKDIR/xray.zip" xray -d "$WORKDIR/xray"
[[ -x "$WORKDIR/xray/xray" ]] || die "В архиве Xray не найден бинарник"
install -m 0755 "$WORKDIR/xray/xray" /usr/local/bin/xray

log "4/10" "Создаю системных пользователей и каталоги"
id -u telemt >/dev/null 2>&1 || useradd --system --home-dir /var/lib/telemt --create-home --shell /usr/sbin/nologin telemt
id -u xray-cascade >/dev/null 2>&1 || useradd --system --home-dir /var/lib/xray-cascade --create-home --shell /usr/sbin/nologin xray-cascade
install -d -m 0750 -o telemt -g telemt /etc/telemt /var/lib/telemt /var/lib/telemt/tlsfront
install -d -m 0750 -o root -g root /etc/mtproxy-panel /opt/mtproxy-panel
install -d -m 0750 -o root -g xray-cascade /etc/xray-cascade /var/lib/xray-cascade

[[ -n "$ADMIN_PASSWORD" ]] || ADMIN_PASSWORD="$(openssl rand -hex 12)"
API_AUTH="Bearer $(openssl rand -hex 32)"
BOOTSTRAP_SECRET="$(openssl rand -hex 16)"

log "5/10" "Формирую fail-closed конфигурацию telemt"
if [[ -s /etc/telemt/telemt.toml ]]; then
  log "5/10" "Сохраняю существующих пользователей telemt и обновляю только публичный домен ссылок"
  PANEL_PUBLIC_HOST="$PUBLIC_HOST" python3 - <<'PY'
from pathlib import Path
import os, re
path = Path('/etc/telemt/telemt.toml')
current = path.read_text(encoding='utf-8')
updated, count = re.subn(
    r'(?m)^public_host\s*=\s*"[^"]*"\s*$',
    f'public_host = "{os.environ["PANEL_PUBLIC_HOST"]}"',
    current,
    count=1,
)
if count != 1:
    raise SystemExit('В существующем telemt.toml не найден general.links.public_host')
tmp = path.with_suffix('.tmp.install')
tmp.write_text(updated, encoding='utf-8')
tmp.chmod(0o640)
tmp.replace(path)
PY
else
cat > /etc/telemt/telemt.toml <<EOF
# Managed by MTProxy Telemt + REALITY Cascade Panel v${APP_VERSION}
# Route is fail-closed: only the local SOCKS5 cascade is configured.
[general]
use_middle_proxy = false
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${PUBLIC_HOST}"
public_port = 443

[server]
port = 443

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]
auth_header = "${API_AUTH}"
minimal_runtime_enabled = true
read_only = false

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true
tls_emulation = true
tls_front_dir = "/var/lib/telemt/tlsfront"

[access.users]
bootstrap = "${BOOTSTRAP_SECRET}"

[[upstreams]]
type = "socks5"
address = "127.0.0.1:1080"
weight = 1
enabled = true
EOF
fi
chown telemt:telemt /etc/telemt/telemt.toml
chmod 0640 /etc/telemt/telemt.toml

cat > /etc/systemd/system/telemt.service <<'EOF'
[Unit]
Description=telemt MTProto proxy (cascade-only)
After=network-online.target xray-cascade.service
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/var/lib/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/etc/telemt /var/lib/telemt

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/xray-cascade.service <<'EOF'
[Unit]
Description=Xray VLESS REALITY cascade client for telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xray-cascade
Group=xray-cascade
WorkingDirectory=/var/lib/xray-cascade
ExecStart=/usr/local/bin/xray run -config /etc/xray-cascade/client.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=/etc/xray-cascade
ReadWritePaths=/var/lib/xray-cascade

[Install]
WantedBy=multi-user.target
EOF

log "6/10" "Записываю или мигрирую конфигурацию панели"
PANEL_ADMIN_PASSWORD="$ADMIN_PASSWORD" PANEL_API_AUTH="$API_AUTH" PANEL_PORT="$PANEL_PORT" \
PANEL_PUBLIC_HOST="$PUBLIC_HOST" PANEL_TLS_DOMAIN="$TLS_DOMAIN" \
PANEL_APP_VERSION="$APP_VERSION" PANEL_TELEMT_VERSION="$TELEMT_VERSION" PANEL_XRAY_VERSION="$XRAY_VERSION" \
python3 - <<'PY'
import base64, hashlib, json, os, re, secrets
from pathlib import Path

settings_path = Path('/etc/mtproxy-panel/settings.json')
telemt_path = Path('/etc/telemt/telemt.toml')
existing = {}
if settings_path.exists():
    try:
        existing = json.loads(settings_path.read_text(encoding='utf-8'))
    except Exception:
        existing = {}

telemt_text = telemt_path.read_text(encoding='utf-8') if telemt_path.exists() else ''
auth_match = re.search(r'(?m)^auth_header\s*=\s*"([^"]+)"', telemt_text)
tls_match = re.search(r'(?m)^tls_domain\s*=\s*"([^"]+)"', telemt_text)

config = dict(existing)
config.update({
    'app_version': os.environ['PANEL_APP_VERSION'],
    'telemt_version': os.environ['PANEL_TELEMT_VERSION'],
    'xray_version': os.environ['PANEL_XRAY_VERSION'],
    'listen': f"0.0.0.0:{os.environ['PANEL_PORT']}",
    'public_host': os.environ['PANEL_PUBLIC_HOST'],
    'telemt_api': 'http://127.0.0.1:9091',
})
config.setdefault('telemt_auth_header', auth_match.group(1) if auth_match else os.environ['PANEL_API_AUTH'])
config.setdefault('tls_domain', tls_match.group(1) if tls_match else os.environ['PANEL_TLS_DOMAIN'])
config.setdefault('cascade', None)

if 'password_salt' not in config or 'password_hash' not in config:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac('sha256', os.environ['PANEL_ADMIN_PASSWORD'].encode(), salt, 350_000)
    config['password_salt'] = base64.b64encode(salt).decode()
    config['password_hash'] = base64.b64encode(digest).decode()
config.setdefault('session_secret', secrets.token_urlsafe(48))

tmp = settings_path.with_suffix('.tmp.install')
tmp.write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding='utf-8')
tmp.chmod(0o600)
tmp.replace(settings_path)
PY
chmod 0600 /etc/mtproxy-panel/settings.json

log "7/10" "Устанавливаю минимальную localhost-панель"
cat > /opt/mtproxy-panel/app.py <<'PYAPP'
#!/usr/bin/env python3
"""Minimal admin panel for telemt + local Xray REALITY cascade.
The panel binds to a public testing port and is protected by administrator authentication.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import html
import ipaddress
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

SETTINGS_PATH = Path('/etc/mtproxy-panel/settings.json')
XRAY_CONFIG_PATH = Path('/etc/xray-cascade/client.json')
XRAY_CONFIG_BACKUP = Path('/etc/xray-cascade/client.json.bak')
SESSIONS: dict[str, dict[str, Any]] = {}
SESSION_TTL = 12 * 60 * 60
USERNAME_RE = re.compile(r'^[A-Za-z0-9_.-]{1,64}$')
SID_RE = re.compile(r'^[0-9a-fA-F]{0,16}$')
ALLOWED_FP = {'chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq', 'random'}
SYSTEMCTL_TIMEOUT = 4.0
API_READ_TIMEOUT = 0.8
API_WRITE_TIMEOUT = 3.0
MAX_FORM_BYTES = 64 * 1024
OPERATION_LOCK = threading.Lock()
OPERATION_STATE: dict[str, Any] = {'running': False, 'label': '', 'message': '', 'error': '', 'updated_at': 0.0}


def operation_snapshot() -> dict[str, Any]:
    with OPERATION_LOCK:
        return dict(OPERATION_STATE)


def start_operation(label: str, action: Any, *args: Any) -> str:
    with OPERATION_LOCK:
        if OPERATION_STATE['running']:
            raise ValueError(f"Уже выполняется операция: {OPERATION_STATE['label']}. Подождите несколько секунд и обновите страницу.")
        OPERATION_STATE.update({'running': True, 'label': label, 'message': '', 'error': '', 'updated_at': time.time()})

    def runner() -> None:
        try:
            result = action(*args)
            with OPERATION_LOCK:
                OPERATION_STATE.update({'running': False, 'message': result, 'error': '', 'updated_at': time.time()})
        except Exception as exc:
            with OPERATION_LOCK:
                OPERATION_STATE.update({'running': False, 'message': '', 'error': str(exc), 'updated_at': time.time()})

    threading.Thread(target=runner, name=f'panel-op-{label}', daemon=True).start()
    return f'Операция «{label}» запущена в фоне. Статус обновится автоматически.'


def load_settings() -> dict[str, Any]:
    with SETTINGS_PATH.open('r', encoding='utf-8') as fh:
        return json.load(fh)


def save_settings(settings: dict[str, Any]) -> None:
    tmp = SETTINGS_PATH.with_suffix('.tmp')
    with tmp.open('w', encoding='utf-8') as fh:
        json.dump(settings, fh, ensure_ascii=False, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, SETTINGS_PATH)


def esc(value: Any) -> str:
    return html.escape(str(value), quote=True)


def systemctl(*args: str, timeout: float = SYSTEMCTL_TIMEOUT) -> subprocess.CompletedProcess[str]:
    command = ['systemctl', *args]
    try:
        return subprocess.run(command, text=True, capture_output=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(command, 124, '', f'systemctl timeout after {timeout:.1f}s')


def is_active(service: str) -> bool:
    return systemctl('is-active', '--quiet', service, timeout=1.0).returncode == 0


def infer_cascade_summary() -> dict[str, str] | None:
    if not XRAY_CONFIG_PATH.exists():
        return None
    try:
        config = json.loads(XRAY_CONFIG_PATH.read_text(encoding='utf-8'))
        outbound = next(item for item in config.get('outbounds', []) if item.get('tag') in {'vless-egress', 'reality-egress'})
        stream = outbound.get('streamSettings', {})
        security = stream.get('security', 'none')
        network = stream.get('network', 'raw')
        settings = outbound.get('settings', {})

        address = settings.get('address')
        port = settings.get('port')
        flow = settings.get('flow', 'none')
        if not address:
            vnext = (settings.get('vnext') or [{}])[0]
            address = vnext.get('address')
            port = vnext.get('port')
            users = vnext.get('users') or [{}]
            flow = users[0].get('flow', 'none') if users else 'none'

        sni = '-'
        fingerprint = '-'
        if security == 'reality':
            reality = stream.get('realitySettings', {})
            sni = reality.get('serverName', '-')
            fingerprint = reality.get('fingerprint', '-')
        elif security == 'tls':
            tls = stream.get('tlsSettings', {})
            sni = tls.get('serverName', '-')
            fingerprint = tls.get('fingerprint', '-')

        if not address or not port:
            return None
        return {
            'endpoint': f'{address}:{port}',
            'sni': sni,
            'fingerprint': fingerprint,
            'flow': flow or 'none',
            'security': security,
            'network': network,
            'recovered': True,
        }
    except Exception:
        return None


def tcp_probe(host: str, port: int, timeout: float = 0.4) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False


def telemt_request(path: str, method: str = 'GET', payload: dict[str, Any] | None = None, timeout: float | None = None) -> tuple[int, dict[str, Any]]:
    settings = load_settings()
    body = None if payload is None else json.dumps(payload).encode('utf-8')
    request_timeout = timeout if timeout is not None else (API_READ_TIMEOUT if method == 'GET' else API_WRITE_TIMEOUT)
    request = urllib.request.Request(
        settings['telemt_api'] + path,
        data=body,
        method=method,
        headers={
            'Authorization': settings['telemt_auth_header'],
            'Content-Type': 'application/json',
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=request_timeout) as response:
            return response.status, json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as exc:
        try:
            data = json.loads(exc.read().decode('utf-8'))
        except Exception:
            data = {'error': {'message': str(exc)}}
        return exc.code, data
    except Exception as exc:
        return 0, {'error': {'message': str(exc)}}


def value_bool(value: str | None) -> bool:
    return str(value or '').strip().lower() in {'1', 'true', 'yes', 'on'}


def split_csv(value: str | None) -> list[str]:
    return [item.strip() for item in str(value or '').split(',') if item.strip()]


def parse_vless_reality_uri(uri: str) -> tuple[dict[str, Any], dict[str, str]]:
    """Parse common VLESS share links into an Xray outbound.

    Supported VLESS variants:
    - security=reality / tls / none
    - type=tcp/raw/ws/grpc/httpupgrade/xhttp/http/h2
    - common query keys produced by v2rayN, Hiddify, Nekoray, sing-box converters.
    """
    parsed = urllib.parse.urlparse(uri.strip())
    if parsed.scheme.lower() != 'vless':
        raise ValueError('Нужна ссылка, начинающаяся с vless://')
    if not parsed.username or not parsed.hostname or not parsed.port:
        raise ValueError('В VLESS-ссылке отсутствуют UUID, адрес или порт')
    try:
        ipaddress.ip_address(parsed.hostname)
    except ValueError:
        if not re.fullmatch(r'[A-Za-z0-9.-]+', parsed.hostname):
            raise ValueError('Некорректный адрес egress-сервера')

    query = {key: values[-1] for key, values in urllib.parse.parse_qs(parsed.query, keep_blank_values=True).items()}
    security = (query.get('security') or query.get('tls') or 'none').lower()
    if security in {'', 'false', '0'}:
        security = 'none'
    if security not in {'none', 'tls', 'reality'}:
        raise ValueError(f'VLESS security={security} пока не поддерживается. Поддерживаются: reality, tls, none.')

    network = (query.get('type') or query.get('network') or 'tcp').lower()
    if network in {'tcp', 'raw'}:
        network = 'raw'
    elif network == 'h2':
        network = 'http'
    supported_networks = {'raw', 'ws', 'grpc', 'httpupgrade', 'xhttp', 'http'}
    if network not in supported_networks:
        raise ValueError(f'VLESS type={network} пока не поддерживается. Поддерживаются: tcp/raw/ws/grpc/httpupgrade/xhttp/http/h2.')

    sni = query.get('sni') or query.get('serverName') or query.get('servername') or query.get('peer') or ''
    host_header = query.get('host') or query.get('Host') or ''
    public_key = query.get('pbk') or query.get('publicKey') or query.get('password') or ''
    short_id = query.get('sid') or query.get('shortId') or ''
    fingerprint = (query.get('fp') or query.get('fingerprint') or 'chrome').lower()
    flow = query.get('flow') or ''
    spider_x = query.get('spx') or query.get('spiderX') or '/'
    path = query.get('path') or '/'
    alpn = split_csv(query.get('alpn'))

    if security == 'reality':
        if not sni or not public_key:
            raise ValueError('Для VLESS REALITY обязательны параметры sni и pbk/publicKey')
        if not SID_RE.fullmatch(short_id) or len(short_id) % 2:
            raise ValueError('sid/shortId должен быть hex-строкой чётной длины до 16 символов')
    if security == 'tls' and not sni:
        sni = host_header or parsed.hostname

    if fingerprint and fingerprint not in ALLOWED_FP:
        if security == 'reality':
            raise ValueError('Неподдерживаемый fp; используйте браузерный fingerprint, например chrome')
        fingerprint = 'chrome'

    user = {
        'id': urllib.parse.unquote(parsed.username),
        'encryption': query.get('encryption') or 'none',
    }
    if flow:
        user['flow'] = flow

    stream_settings: dict[str, Any] = {'network': network}
    if security != 'none':
        stream_settings['security'] = security

    if security == 'reality':
        stream_settings['realitySettings'] = {
            'serverName': sni,
            'fingerprint': fingerprint,
            'password': public_key,
            'shortId': short_id,
            'spiderX': spider_x,
        }
    elif security == 'tls':
        tls_settings: dict[str, Any] = {
            'serverName': sni,
            'allowInsecure': value_bool(query.get('allowInsecure') or query.get('allowinsecure')),
        }
        if fingerprint:
            tls_settings['fingerprint'] = fingerprint
        if alpn:
            tls_settings['alpn'] = alpn
        stream_settings['tlsSettings'] = tls_settings

    if network == 'ws':
        ws_settings: dict[str, Any] = {'path': path}
        if host_header:
            ws_settings['headers'] = {'Host': host_header}
        stream_settings['wsSettings'] = ws_settings
    elif network == 'grpc':
        stream_settings['grpcSettings'] = {
            'serviceName': query.get('serviceName') or query.get('service_name') or '',
            'multiMode': (query.get('mode') or '').lower() == 'multi' or value_bool(query.get('multiMode')),
        }
    elif network == 'httpupgrade':
        settings: dict[str, Any] = {'path': path}
        if host_header:
            settings['host'] = host_header
        stream_settings['httpupgradeSettings'] = settings
    elif network == 'xhttp':
        settings: dict[str, Any] = {'path': path, 'mode': query.get('mode') or 'auto'}
        if host_header:
            settings['host'] = host_header
        stream_settings['xhttpSettings'] = settings
    elif network == 'http':
        settings: dict[str, Any] = {'path': path}
        if host_header:
            settings['host'] = [host_header]
        stream_settings['httpSettings'] = settings

    config = {
        'log': {'loglevel': 'warning'},
        'inbounds': [{
            'tag': 'telemt-socks',
            'listen': '127.0.0.1',
            'port': 1080,
            'protocol': 'socks',
            'settings': {'auth': 'noauth', 'udp': False},
        }],
        'outbounds': [{
            'tag': 'vless-egress',
            'protocol': 'vless',
            'settings': {'vnext': [{
                'address': parsed.hostname,
                'port': parsed.port,
                'users': [user],
            }]},
            'streamSettings': stream_settings,
        }],
        'routing': {
            'domainStrategy': 'AsIs',
            'rules': [{'inboundTag': ['telemt-socks'], 'outboundTag': 'vless-egress'}],
        },
    }
    summary = {
        'endpoint': f'{parsed.hostname}:{parsed.port}',
        'sni': sni or '-',
        'fingerprint': fingerprint or '-',
        'flow': flow or 'none',
        'security': security,
        'network': network,
    }
    return config, summary


def apply_cascade(vless_uri: str) -> str:
    config, summary = parse_vless_reality_uri(vless_uri)
    XRAY_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix='client.', suffix='.json', dir=str(XRAY_CONFIG_PATH.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            json.dump(config, fh, ensure_ascii=False, indent=2)
        os.chmod(tmp_name, 0o640)
        subprocess.run(['chown', 'root:xray-cascade', tmp_name], check=True, timeout=5)
        test = subprocess.run(['/usr/local/bin/xray', 'run', '-test', '-config', tmp_name], text=True, capture_output=True, timeout=10)
        if test.returncode != 0:
            raise ValueError('Xray отклонил конфигурацию: ' + (test.stderr.strip() or test.stdout.strip())[-500:])
        if XRAY_CONFIG_PATH.exists():
            shutil.copy2(XRAY_CONFIG_PATH, XRAY_CONFIG_BACKUP)
        os.replace(tmp_name, XRAY_CONFIG_PATH)

        xray_result = systemctl('restart', 'xray-cascade.service')
        if xray_result.returncode != 0:
            raise RuntimeError('Не удалось запустить Xray: ' + xray_result.stderr[-400:])
        telemt_result = systemctl('restart', 'telemt.service')
        if telemt_result.returncode != 0:
            raise RuntimeError('Не удалось запустить telemt: ' + telemt_result.stderr[-400:])

        settings = load_settings()
        settings['cascade'] = summary
        save_settings(settings)
        return f"VLESS-каскад применён: {summary['endpoint']} / {summary['security']} / {summary['network']} / SNI {summary['sni']}. Проверка readiness может занять до минуты."
    except Exception:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        if XRAY_CONFIG_BACKUP.exists():
            shutil.copy2(XRAY_CONFIG_BACKUP, XRAY_CONFIG_PATH)
            systemctl('restart', 'xray-cascade.service')
        raise


def disable_cascade() -> str:
    systemctl('stop', 'telemt.service')
    systemctl('stop', 'xray-cascade.service')
    if XRAY_CONFIG_PATH.exists():
        disabled_path = XRAY_CONFIG_PATH.with_suffix('.json.disabled')
        if disabled_path.exists():
            disabled_path.unlink()
        XRAY_CONFIG_PATH.replace(disabled_path)
    settings = load_settings()
    settings['cascade'] = None
    save_settings(settings)
    return 'Каскад выключен. telemt остановлен fail-closed: клиентские ссылки не будут подключаться до нового каскада.'


TLS_DOMAIN_RE = re.compile(r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$')


def apply_tls_domain(value: str) -> str:
    domain = value.strip().lower().rstrip('.')
    if not TLS_DOMAIN_RE.fullmatch(domain):
        raise ValueError('Некорректный SNI-домен. Пример: vk.com')
    config_path = Path('/etc/telemt/telemt.toml')
    current = config_path.read_text(encoding='utf-8')
    updated, count = re.subn(r'(?m)^tls_domain\s*=\s*"[^"]*"\s*$', f'tls_domain = "{domain}"', current, count=1)
    if count != 1:
        raise RuntimeError('Не найден параметр tls_domain в telemt.toml')
    tmp = config_path.with_suffix('.tmp')
    tmp.write_text(updated, encoding='utf-8')
    os.chmod(tmp, 0o640)
    shutil.chown(tmp, user='telemt', group='telemt')
    os.replace(tmp, config_path)
    settings = load_settings()
    settings['tls_domain'] = domain
    save_settings(settings)
    if is_active('telemt.service'):
        result = systemctl('restart', 'telemt.service')
        if result.returncode != 0:
            raise RuntimeError('SNI сохранён, но telemt не перезапустился: ' + result.stderr[-400:])
    return f'Fake TLS SNI сохранён: {domain}. Новые tg://proxy ссылки будут строиться с этим доменом.'


def apply_admin_password(current: str, new_password: str, confirmation: str) -> str:
    if not check_password(current):
        raise ValueError('Текущий пароль указан неверно')
    if len(new_password) < 12:
        raise ValueError('Новый пароль должен содержать не менее 12 символов')
    if new_password != confirmation:
        raise ValueError('Подтверждение нового пароля не совпадает')
    if '\n' in new_password or '\r' in new_password:
        raise ValueError('Пароль не должен содержать переносы строк')
    settings = load_settings()
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac('sha256', new_password.encode(), salt, 350_000)
    settings['password_salt'] = base64.b64encode(salt).decode()
    settings['password_hash'] = base64.b64encode(digest).decode()
    save_settings(settings)
    return 'Пароль администратора успешно изменён.'


def check_password(password: str) -> bool:
    settings = load_settings()
    salt = base64.b64decode(settings['password_salt'])
    expected = base64.b64decode(settings['password_hash'])
    actual = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 350_000)
    return hmac.compare_digest(actual, expected)


def create_session() -> tuple[str, str]:
    token = secrets.token_urlsafe(32)
    csrf = secrets.token_urlsafe(24)
    SESSIONS[token] = {'expires': time.time() + SESSION_TTL, 'csrf': csrf}
    return token, csrf


def session_from_cookie(cookie_header: str | None) -> tuple[str | None, dict[str, Any] | None]:
    if not cookie_header:
        return None, None
    cookie = SimpleCookie(); cookie.load(cookie_header)
    value = cookie.get('panel_session')
    token = value.value if value else None
    session = SESSIONS.get(token or '')
    if not session or session['expires'] < time.time():
        if token:
            SESSIONS.pop(token, None)
        return None, None
    session['expires'] = time.time() + SESSION_TTL
    return token, session


def render_layout(content: str, title: str = 'MTProxy Panel') -> bytes:
    style = '''
    :root{color-scheme:dark;--bg:#0c1220;--card:#131d31;--line:#283650;--text:#eaf1ff;--muted:#97a8c7;--ok:#30d685;--bad:#ff6172;--blue:#5ba7ff}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px system-ui,-apple-system,Segoe UI,sans-serif}
    main{max-width:1100px;margin:32px auto;padding:0 18px}.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:20px}
    h1{font-size:25px;margin:0}h2{font-size:18px;margin:0 0 13px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(325px,1fr));gap:16px}
    .card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:17px;margin-bottom:16px}.muted{color:var(--muted)}
    .ok{color:var(--ok);font-weight:650}.bad{color:var(--bad);font-weight:650}.pill{border:1px solid var(--line);border-radius:999px;padding:5px 10px;display:inline-block;margin-right:6px}
    input,textarea{width:100%;background:#09111f;color:var(--text);border:1px solid var(--line);padding:10px 11px;border-radius:9px;margin:6px 0 12px;font:inherit}
    textarea{min-height:92px;resize:vertical}button{background:var(--blue);color:#07101e;border:0;border-radius:9px;padding:10px 14px;font-weight:700;cursor:pointer}
    button.danger{background:#ff6172}button.secondary{background:#25334e;color:var(--text)}form.inline{display:inline}.flash{padding:12px;border-radius:10px;background:#102743;border:1px solid #284872;margin-bottom:16px}
    .error{background:#381923;border-color:#65303b}.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.user{padding:12px 0;border-top:1px solid var(--line)}
    code{background:#07101e;padding:3px 5px;border-radius:5px;word-break:break-all}a{color:#8bc2ff}label{font-size:13px;color:var(--muted)}
    .copyline{display:flex;gap:8px;align-items:center;margin:8px 0}.copyline input{margin:0;font-size:13px}.hint{font-size:13px;line-height:1.45}.warn{color:#ffd27a;font-weight:650}
    '''
    script = '''
    <script>
    async function copyById(id) {
      const el = document.getElementById(id);
      if (!el) return;
      try {
        await navigator.clipboard.writeText(el.value || el.textContent || '');
      } catch (e) {
        el.focus();
        el.select && el.select();
        document.execCommand('copy');
      }
    }
    </script>
    '''
    return f'''<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(title)}</title><style>{style}</style>{script}</head><body><main>{content}</main></body></html>'''.encode('utf-8')


class Handler(BaseHTTPRequestHandler):
    server_version = 'MTProxyPanel/1.3.1'

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f'panel {self.address_string()} - {fmt % args}')

    def read_form(self) -> dict[str, str]:
        length = int(self.headers.get('Content-Length', '0'))
        if length < 0 or length > MAX_FORM_BYTES:
            raise ValueError('Слишком большой запрос')
        data = self.rfile.read(length).decode('utf-8', errors='replace')
        return {k: v[-1] for k, v in urllib.parse.parse_qs(data).items()}

    def send_html(self, body: bytes, status: int = 200, cookie: str | None = None) -> None:
        self.send_response(status)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Content-Security-Policy', "default-src 'self' 'unsafe-inline'")
        self.send_header('Cache-Control', 'no-store')
        if cookie:
            self.send_header('Set-Cookie', cookie)
        self.end_headers(); self.wfile.write(body)

    def redirect(self, path: str, cookie: str | None = None) -> None:
        # PRG: every POST returns 303 -> GET, so browser refresh never asks to resend form data.
        self.send_response(303); self.send_header('Location', path)
        if cookie:
            self.send_header('Set-Cookie', cookie)
        self.end_headers()

    def authenticated(self) -> tuple[str | None, dict[str, Any] | None]:
        return session_from_cookie(self.headers.get('Cookie'))

    def require_auth(self) -> tuple[str, dict[str, Any]] | None:
        token, session = self.authenticated()
        if not token or not session:
            self.redirect('/login'); return None
        return token, session

    def check_csrf(self, form: dict[str, str], session: dict[str, Any]) -> bool:
        return hmac.compare_digest(form.get('csrf', ''), session['csrf'])

    def do_GET(self) -> None:
        if self.path == '/login':
            self.login_page(); return
        if self.path != '/':
            self.send_error(404); return
        auth = self.require_auth()
        if auth:
            self.dashboard(auth[1])

    def do_POST(self) -> None:
        if self.path == '/login':
            form = self.read_form()
            if check_password(form.get('password', '')):
                token, _ = create_session()
                self.redirect('/', f'panel_session={token}; HttpOnly; SameSite=Strict; Path=/; Max-Age={SESSION_TTL}')
            else:
                self.redirect('/login')
            return
        auth = self.require_auth()
        if not auth:
            return
        token, session = auth
        form = self.read_form()
        if not self.check_csrf(form, session):
            with OPERATION_LOCK:
                OPERATION_STATE.update({'running': False, 'message': '', 'error': 'CSRF-проверка не пройдена', 'updated_at': time.time()})
            self.redirect('/'); return
        try:
            if self.path == '/logout':
                SESSIONS.pop(token, None)
                self.redirect('/login', 'panel_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0'); return
            if self.path == '/cascade/apply':
                start_operation('Применение VLESS-каскада', apply_cascade, form.get('vless_uri', ''))
                self.redirect('/'); return
            if self.path == '/cascade/disable':
                start_operation('Остановка каскада', disable_cascade)
                self.redirect('/'); return
            if self.path == '/settings/tls-domain':
                start_operation('Смена Fake TLS SNI', apply_tls_domain, form.get('tls_domain', ''))
                self.redirect('/'); return
            if self.path == '/settings/password':
                with OPERATION_LOCK:
                    OPERATION_STATE.update({'running': False, 'message': apply_admin_password(
                        form.get('current_password', ''),
                        form.get('new_password', ''),
                        form.get('confirm_password', ''),
                    ), 'error': '', 'updated_at': time.time()})
                self.redirect('/'); return
            if self.path == '/users/create':
                username = form.get('username', '').strip()
                if not USERNAME_RE.fullmatch(username):
                    raise ValueError('Имя: 1–64 символа A-Z, a-z, 0-9, _, . или -')
                if not is_active('telemt.service'):
                    raise ValueError('Сначала примените рабочий VLESS+REALITY каскад и запустите telemt')
                status, response = telemt_request('/v1/users', 'POST', {'username': username}, timeout=API_WRITE_TIMEOUT)
                problem = response.get('error', response) if isinstance(response, dict) else response
                if status not in (201, 202):
                    if isinstance(problem, dict) and problem.get('code') == 'user_exists':
                        with OPERATION_LOCK:
                            OPERATION_STATE.update({'running': False, 'message': f'Доступ {username} уже существует. Используйте ссылку ниже или обновите secret.', 'error': '', 'updated_at': time.time()})
                        self.redirect('/'); return
                    raise ValueError('telemt не создал пользователя: ' + str(problem))
                with OPERATION_LOCK:
                    OPERATION_STATE.update({'running': False, 'message': f'Доступ {username} создан. Ссылка появилась в списке ниже.', 'error': '', 'updated_at': time.time()})
                self.redirect('/'); return
            if self.path == '/users/delete':
                username = form.get('username', '')
                if username == 'bootstrap':
                    raise ValueError('Системного пользователя bootstrap удалять нельзя')
                status, response = telemt_request('/v1/users/' + urllib.parse.quote(username), 'DELETE', timeout=API_WRITE_TIMEOUT)
                if status not in (200, 202):
                    raise ValueError('telemt не удалил пользователя: ' + str(response.get('error', response)))
                with OPERATION_LOCK:
                    OPERATION_STATE.update({'running': False, 'message': f'Доступ {username} удалён.', 'error': '', 'updated_at': time.time()})
                self.redirect('/'); return
            if self.path == '/users/rotate':
                username = form.get('username', '')
                status, response = telemt_request('/v1/users/' + urllib.parse.quote(username) + '/rotate-secret', 'POST', {}, timeout=API_WRITE_TIMEOUT)
                if status not in (200, 202):
                    raise ValueError('telemt не обновил secret: ' + str(response.get('error', response)))
                with OPERATION_LOCK:
                    OPERATION_STATE.update({'running': False, 'message': f'Secret пользователя {username} обновлён; старая ссылка больше не действует.', 'error': '', 'updated_at': time.time()})
                self.redirect('/'); return
            self.send_error(404)
        except Exception as exc:
            with OPERATION_LOCK:
                OPERATION_STATE.update({'running': False, 'message': '', 'error': str(exc), 'updated_at': time.time()})
            self.redirect('/')

    def login_page(self, error: str | None = None) -> None:
        flash = f'<div class="flash error">{esc(error)}</div>' if error else ''
        content = f'''<div style="max-width:420px;margin:90px auto"><div class="card"><h1>MTProxy Panel</h1><p class="muted">telemt + REALITY cascade</p>{flash}<form method="post" action="/login"><label>Пароль администратора</label><input type="password" name="password" autofocus required><button type="submit">Войти</button></form></div></div>'''
        self.send_html(render_layout(content, 'Вход — MTProxy Panel'))

    def dashboard(self, session: dict[str, Any], message: str | None = None, error: str | None = None) -> None:
        settings = load_settings()
        recovered = not bool(settings.get('cascade'))
        cascade = settings.get('cascade') or infer_cascade_summary()
        telemt_up = is_active('telemt.service')
        xray_up = is_active('xray-cascade.service')
        ready_status, ready = telemt_request('/v1/health/ready', timeout=API_READ_TIMEOUT) if telemt_up and cascade and xray_up else (0, {})
        ready_data = ready.get('data', {}) if isinstance(ready, dict) else {}
        ready_ok = bool(cascade) and xray_up and ready_status == 200 and ready_data.get('ready') is True
        users: list[dict[str, Any]] = []
        if telemt_up:
            _, response = telemt_request('/v1/users', timeout=API_READ_TIMEOUT)
            users = response.get('data', []) if isinstance(response, dict) else []
        csrf = esc(session['csrf'])
        operation = operation_snapshot()
        flash = ''
        if operation.get('running'):
            flash = f'<div class="flash">Выполняется: {esc(operation["label"])}. Страница обновится автоматически.</div>'
        elif operation.get('error') and not error:
            flash = f'<div class="flash error">{esc(operation["error"])}</div>'
        elif operation.get('message') and not message:
            flash = f'<div class="flash">{esc(operation["message"])}</div>'
        if message:
            flash = f'<div class="flash">{esc(message)}</div>'
        if error:
            flash = f'<div class="flash error">{esc(error)}</div>'
        recovered_note = ' (восстановлено из Xray config)' if cascade and recovered else ''
        ingress_local_ok = tcp_probe('127.0.0.1', 443)
        cascade_text = 'не настроен' if not cascade else f"{esc(cascade['endpoint'])} / {esc(cascade.get('security', '-'))} / {esc(cascade.get('network', '-'))} / SNI {esc(cascade.get('sni', '-'))} / fp {esc(cascade.get('fingerprint', '-'))}{recovered_note}"
        status = f'''<div class="card"><h2>Состояние маршрута</h2><div class="row"><span class="pill">Xray cascade: <span class="{'ok' if xray_up else 'bad'}">{'ACTIVE' if xray_up else 'OFF'}</span></span><span class="pill">telemt: <span class="{'ok' if telemt_up else 'bad'}">{'ACTIVE' if telemt_up else 'OFF'}</span></span><span class="pill">Local :443: <span class="{'ok' if ingress_local_ok else 'bad'}">{'LISTEN' if ingress_local_ok else 'CLOSED'}</span></span><span class="pill">Server → Telegram: <span class="{'ok' if ready_ok else 'bad'}">{'READY' if ready_ok else 'NOT READY'}</span></span><span class="pill">Client → Proxy: <span class="warn">UNKNOWN</span></span></div><p class="muted">Каскад: {cascade_text}</p><p class="hint muted"><b>Важно:</b> зелёный <code>Server → Telegram</code> доказывает только серверный маршрут telemt → VLESS → Telegram DC. Он не доказывает, что Telegram-клиент из РФ может пройти входной участок <code>клиент → {esc(settings['public_host'])}:443 / Fake TLS</code>. Если в Telegram нет соединения при зелёных статусах, проверяйте внешний TCP 443, актуальный secret после смены SNI и блокировку Fake TLS/SNI оператором.</p></div>'''
        cascade_badge = '<p class="bad">VLESS ключ не добавлен</p>' if not cascade else f'''<p class="ok">VLESS ключ добавлен</p><p class="hint muted"><b>Активный ключ:</b><br>endpoint: <code>{esc(cascade.get('endpoint', '-'))}</code><br>security/type: <code>{esc(cascade.get('security', '-'))}/{esc(cascade.get('network', '-'))}</code><br>SNI: <code>{esc(cascade.get('sni', '-'))}</code><br>flow: <code>{esc(cascade.get('flow', 'none'))}</code></p>'''
        cascade_form = f'''<div class="card"><h2>VLESS каскад</h2>{cascade_badge}<p class="muted">Вставьте клиентскую VLESS-ссылку EGRESS-сервера. Поддерживаются common-варианты: REALITY/TLS/none и raw/tcp/ws/grpc/httpupgrade/xhttp/http. Она преобразуется в локальный Xray outbound; telemt направляет MTProto-трафик через SOCKS5.</p><form method="post" action="/cascade/apply"><input type="hidden" name="csrf" value="{csrf}"><label>VLESS URL</label><textarea name="vless_uri" placeholder="vless://UUID@host:443?security=reality&type=tcp&sni=...&fp=chrome&pbk=...&sid=... или vless://UUID@host:443?security=tls&type=ws&host=...&path=/..." required></textarea><button type="submit">Применить VLESS каскад</button></form><form method="post" action="/cascade/disable" style="margin-top:12px"><input type="hidden" name="csrf" value="{csrf}"><button class="danger" type="submit">Остановить каскад</button></form></div>'''
        settings_card = f'''<div class="card"><h2>Настройки Proxy</h2><p class="muted">Домен в ссылках задан при установке: <code>{esc(settings['public_host'])}</code>. Здесь меняются параметры, которые не должны спрашиваться в installer.</p><form method="post" action="/settings/tls-domain"><input type="hidden" name="csrf" value="{csrf}"><label>Fake TLS SNI для tg://proxy ссылок</label><input name="tls_domain" value="{esc(settings['tls_domain'])}" placeholder="vk.com" required><button type="submit">Сохранить SNI</button></form><hr style="border:0;border-top:1px solid var(--line);margin:18px 0"><form method="post" action="/settings/password"><input type="hidden" name="csrf" value="{csrf}"><label>Текущий пароль администратора</label><input type="password" name="current_password" required><label>Новый пароль администратора</label><input type="password" name="new_password" minlength="12" required><label>Подтверждение нового пароля</label><input type="password" name="confirm_password" minlength="12" required><button type="submit">Сменить пароль</button></form></div>'''
        user_rows = ''
        link_index = 0
        for user in users:
            username = user.get('username', '')
            if username == 'bootstrap':
                continue
            tls_links = (user.get('links') or {}).get('tls') or []
            if tls_links:
                link_parts = []
                for link in tls_links:
                    link_index += 1
                    element_id = f'proxy_link_{link_index}'
                    link_parts.append(f'''<div class="copyline"><input id="{element_id}" readonly value="{esc(link)}"><button class="secondary" type="button" onclick="copyById('{element_id}')">Копировать</button></div>''')
                link_html = ''.join(link_parts)
            else:
                link_html = '<span class="muted">ссылка ещё не построена</span>'
            user_rows += f'''<div class="user"><div class="row"><b>{esc(username)}</b><form class="inline" method="post" action="/users/rotate"><input type="hidden" name="csrf" value="{csrf}"><input type="hidden" name="username" value="{esc(username)}"><button class="secondary" type="submit">Новый secret</button></form><form class="inline" method="post" action="/users/delete"><input type="hidden" name="csrf" value="{csrf}"><input type="hidden" name="username" value="{esc(username)}"><button class="danger" type="submit">Удалить</button></form></div>{link_html}<p class="hint muted">После смены Fake TLS SNI обязательно нажмите «Новый secret» и копируйте новую ссылку.</p></div>'''
        if not user_rows:
            user_rows = '<p class="muted">Клиентских доступов пока нет.</p>'
        users_card = f'''<div class="card"><h2>Доступы Telegram Proxy</h2><form method="post" action="/users/create"><input type="hidden" name="csrf" value="{csrf}"><label>Имя нового доступа</label><div class="row"><input style="flex:1;margin:6px 0" name="username" placeholder="client_001" pattern="[A-Za-z0-9_.-]{{1,64}}" required><button type="submit">Создать ссылку</button></div></form>{user_rows}</div>'''
        check_cmd = f'nc -vz {settings["public_host"]} 443'
        diag_card = f'''<div class="card"><h2>Диагностика, если Telegram не подключается</h2><p class="hint muted">Проверку входа нужно делать <b>не с этого VPS</b>, а с телефона/домашнего ПК из той сети, где не работает Telegram. Серверный READY этого не проверяет.</p><div class="copyline"><input id="diag_cmd" readonly value="{esc(check_cmd)}"><button class="secondary" type="button" onclick="copyById('diag_cmd')">Копировать команду</button></div><p class="hint muted">Если TCP 443 доступен, но Telegram не подключается — основной подозреваемый: Fake TLS fingerprint/SNI. Попробуйте SNI <code>max.ru</code>, затем нажмите «Новый secret» у доступа и скопируйте новую ссылку.</p></div>'''
        top = f'''<div class="top"><div><h1>MTProxy Panel</h1><div class="muted">telemt {esc(settings['telemt_version'])} · Xray {esc(settings['xray_version'])} · Fake TLS SNI {esc(settings['tls_domain'])}</div></div><form method="post" action="/logout"><input type="hidden" name="csrf" value="{csrf}"><button class="secondary" type="submit">Выйти</button></form></div>'''
        auto_refresh = '<script>setTimeout(()=>location.reload(), 1500)</script>' if operation.get('running') else ''
        content = top + flash + status + '<div class="grid">' + settings_card + cascade_form + users_card + diag_card + '</div>' + auto_refresh
        self.send_html(render_layout(content))


class PanelHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


def main() -> None:
    settings = load_settings()
    host, port = settings['listen'].rsplit(':', 1)
    server = PanelHTTPServer((host, int(port)), Handler)
    print(f"MTProxy Panel listening on {settings['listen']}", flush=True)
    server.serve_forever(poll_interval=0.25)


if __name__ == '__main__':
    main()
PYAPP
chmod 0750 /opt/mtproxy-panel/app.py

cat > /etc/systemd/system/mtproxy-panel.service <<EOF
[Unit]
Description=MTProxy telemt REALITY admin panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/mtproxy-panel
ExecStart=/usr/bin/python3 /opt/mtproxy-panel/app.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=/opt/mtproxy-panel
ReadWritePaths=/etc/mtproxy-panel /etc/telemt /etc/xray-cascade /var/lib/xray-cascade

[Install]
WantedBy=multi-user.target
EOF

# Verify the embedded Python application before enabling anything.
python3 -m py_compile /opt/mtproxy-panel/app.py

log "8/10" "Применяю systemd-конфигурацию и очищаю конфликтующие overrides"
rm -rf /etc/systemd/system/mtproxy-panel.service.d
systemctl daemon-reload
systemctl enable mtproxy-panel.service xray-cascade.service telemt.service >/dev/null 2>&1 || true
systemctl restart mtproxy-panel.service
systemctl is-active --quiet mtproxy-panel.service || die "Панель не запустилась; проверьте journalctl -u mtproxy-panel"

if [[ -s /etc/xray-cascade/client.json ]]; then
  systemctl restart xray-cascade.service || true
  systemctl restart telemt.service || true
else
  systemctl stop telemt.service xray-cascade.service >/dev/null 2>&1 || true
fi

# Для тестовой публичной панели открываем порт в UFW только если UFW уже установлен и активен.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
  ufw allow "${PANEL_PORT}/tcp" comment "MTProxy test admin panel" >/dev/null
fi

log "9/10" "Проверяю установленные версии"
/usr/local/bin/telemt --version 2>/dev/null || true
/usr/local/bin/xray version | head -n 1 || true

log "10/10" "Готово: установлен MTProxy ingress; дальнейшая настройка выполняется в UI"
cat <<EOF

Установлено:
  Panel:  v${APP_VERSION}, 0.0.0.0:${PANEL_PORT}
  telemt: ${TELEMT_VERSION} (pinned; пока остановлен до настройки каскада)
  Xray:   ${XRAY_VERSION} (pinned; пока остановлен до настройки каскада)

Адрес в tg://proxy ссылках: ${PUBLIC_HOST}:443
Стартовый Fake TLS SNI:    ${TLS_DOMAIN} (изменяется в UI)

Доступ к панели для проверки:
  открыть в браузере: http://IP_СЕРВЕРА:${PANEL_PORT}
  если используете cloud firewall/security group — откройте TCP ${PANEL_PORT} вручную.
  ВАЖНО: это HTTP-доступ для тестирования; не оставляйте порт публичным для production.

Пароль панели:
$(if [[ "$EXISTING_PANEL_SETTINGS" -eq 1 ]]; then
    printf '  Сохранён из предыдущей установки (используйте текущий пароль).'
  else
    printf '  %s' "$ADMIN_PASSWORD"
  fi)

Первый запуск:
  1) Откройте панель по адресу http://IP_СЕРВЕРА:${PANEL_PORT}.
  2) В UI задайте Fake TLS SNI и смените временный пароль администратора.
  3) Вставьте VLESS-ссылку зарубежного EGRESS VPS.
  4) Дождитесь статуса Telegram upstream: READY.
  5) Создавайте клиентские доступы; панель выдаст tg://proxy ссылки.

Схема маршрута:
  Telegram -> telemt:443 -> 127.0.0.1:1080/Xray -> VLESS -> EGRESS VPS -> Telegram DC

Проверка логов:
  journalctl -u mtproxy-panel -u xray-cascade -u telemt -f
EOF
