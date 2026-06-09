#!/usr/bin/env bash
set -Eeuo pipefail

APP_VERSION="0.1.2"
APP_NAME="telemt-xray-doublehop-panel"
APP_DIR="/opt/telemt-doublehop-panel"
APP_ETC="/etc/telemt-panel"
APP_STATE="/var/lib/telemt-panel"
PANEL_SERVICE="telemt-panel.service"
TELEMT_CONFIG="/etc/telemt/telemt.toml"
TELEMT_BIN="/usr/local/bin/telemt"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"
LOG_FILE="/var/log/telemt-doublehop-install.log"

ROLE=""
EDGE_HOST=""
EGRESS_HOST=""
EDGE_PORT="443"
XRAY_PORT="443"
XRAY_LOCAL_PORT="2443"
TELEMT_LOCAL_PORT="9443"
TELEMT_API_LISTEN="127.0.0.1:9091"
TELEMT_SNI="vk.com"
REALITY_SNI="www.microsoft.com"
REALITY_DEST=""
UUID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
PANEL_BIND="127.0.0.1"
PANEL_PORT="9444"
PANEL_PASSWORD=""
DEFAULT_USER="main"
NO_FIREWALL="0"

usage() {
  cat <<USAGE
${APP_NAME} v${APP_VERSION}

Использование:
  # Интерактивная установка, удобно для запуска с GitHub:
  sudo bash $0

  # Нейнтерактивный режим:
  sudo bash $0 --role egress --edge-host EDGE_PUBLIC_IP_OR_DOMAIN [options]
  sudo bash $0 --role edge --egress-host EGRESS_PUBLIC_IP_OR_DOMAIN --uuid UUID --reality-public-key KEY --short-id HEX [options]
  sudo bash $0 --role single --edge-host THIS_PUBLIC_IP_OR_DOMAIN [options]

Роли:
  egress  Выходной VPS: Xray REALITY server + Telemt + веб-панель. Telemt слушает только localhost.
  edge    Входной VPS: HAProxy public :443 + Xray client, который ведёт на egress Telemt.
  single  Один VPS без double-hop: Telemt + веб-панель, Telemt слушает публичный :443.

Важные параметры:
  --edge-host VALUE              Публичный host/IP, который будет в Telegram proxy-ссылках.
  --egress-host VALUE            Публичный host/IP egress-сервера с Xray REALITY.
  --edge-port PORT               Публичный MTProxy-порт на edge/single. По умолчанию: 443.
  --xray-port PORT               Порт Xray REALITY server на egress. По умолчанию: 443.
  --telemt-sni DOMAIN            FakeTLS SNI внутри MTProxy secret. По умолчанию: vk.com.
  --reality-sni DOMAIN           REALITY serverName для туннеля edge -> egress. По умолчанию: www.microsoft.com.
  --reality-dest HOST:PORT       REALITY dest. По умолчанию: <reality-sni>:443.
  --uuid UUID                    UUID пользователя VLESS. На egress/single генерируется автоматически.
  --reality-private-key KEY      Приватный ключ Xray REALITY. На egress генерируется автоматически.
  --reality-public-key KEY       Публичный ключ Xray REALITY. Обязателен на edge.
  --short-id HEX                 REALITY shortId. На egress генерируется автоматически.
  --panel-bind IP                IP, на котором слушает веб-панель. По умолчанию: 127.0.0.1.
  --panel-port PORT              Порт веб-панели. По умолчанию: 9444.
  --panel-password PASSWORD      Пароль веб-панели. Генерируется автоматически, если не указан.
  --no-firewall                  Не менять ufw/firewalld.

Примеры запуска с GitHub:
  # Интерактивная установка:
  sudo bash <(curl -fsSL 'https://raw.githubusercontent.com/USER/REPO/BRANCH/telemt-xray-doublehop-panel-v0.1.2.sh')

  # Egress VPS вне РФ:
  sudo bash <(curl -fsSL 'https://raw.githubusercontent.com/USER/REPO/BRANCH/telemt-xray-doublehop-panel-v0.1.2.sh') --role egress --edge-host edge.example.com --egress-host egress.example.com

  # Pipe-режим; всё после "bash -s --" передаётся в installer:
  curl -fsSL 'https://raw.githubusercontent.com/USER/REPO/BRANCH/telemt-xray-doublehop-panel-v0.1.2.sh' | sudo bash -s -- --role egress --edge-host edge.example.com --egress-host egress.example.com

  # Edge VPS, доступный пользователям из РФ. Используй значения, которые напечатал egress-installer:
  sudo bash <(curl -fsSL 'https://raw.githubusercontent.com/USER/REPO/BRANCH/telemt-xray-doublehop-panel-v0.1.2.sh') --role edge --egress-host egress.example.com --uuid <uuid> --reality-public-key <key> --short-id <hex>

  # Открыть локальную панель через SSH-туннель:
  ssh -L 9444:127.0.0.1:9444 root@EGRESS_PUBLIC_IP
  затем открой http://127.0.0.1:9444/
USAGE
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '[%s] ПРЕДУПРЕЖДЕНИЕ: %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
fatal() { printf '[%s] ОШИБКА: %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }

on_error() {
  local exit_code=$?
  warn "Установка завершилась с ошибкой, код ${exit_code}. Подробности смотри в ${LOG_FILE}."
  exit "$exit_code"
}
trap on_error ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || fatal "Запусти от root: sudo bash $0 ..."
}

has_tty() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

prompt_value() {
  local __var="$1" label="$2" default="${3:-}" value=""
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$label" "$default" > /dev/tty
  else
    printf '%s: ' "$label" > /dev/tty
  fi
  IFS= read -r value < /dev/tty || true
  value="${value:-$default}"
  printf -v "$__var" '%s' "$value"
}

prompt_required() {
  local __var="$1" label="$2" default="${3:-}" value=""
  while true; do
    prompt_value value "$label" "$default"
    if [[ -n "$value" ]]; then
      printf -v "$__var" '%s' "$value"
      return 0
    fi
    printf 'Значение обязательно.\n' > /dev/tty
  done
}

interactive_setup() {
  if ! has_tty; then
    usage
    fatal "Аргументы не переданы и интерактивный терминал недоступен. Используй: curl -fsSL URL | sudo bash -s -- --role egress --edge-host EDGE --egress-host EGRESS"
  fi

  usage
  echo
  echo "Аргументы не переданы, запускаю интерактивную установку." > /dev/tty
  echo "Для установки с GitHub это нормальный режим: sudo bash <(curl -fsSL URL)" > /dev/tty
  echo > /dev/tty

  while true; do
    prompt_value ROLE "Роль сервера: egress, edge или single" "egress"
    [[ "$ROLE" =~ ^(egress|edge|single)$ ]] && break
    echo "Роль должна быть одной из: egress, edge, single" > /dev/tty
  done

  case "$ROLE" in
    egress)
      prompt_required EDGE_HOST "Публичный host/IP EDGE-сервера, который будут использовать пользователи Telegram"
      prompt_value EGRESS_HOST "Публичный host/IP EGRESS-сервера для готовой команды установки edge" ""
      prompt_value EDGE_PORT "Публичный MTProxy-порт на edge" "$EDGE_PORT"
      prompt_value XRAY_PORT "Порт Xray REALITY на egress" "$XRAY_PORT"
      prompt_value TELEMT_SNI "Telemt FakeTLS SNI" "$TELEMT_SNI"
      prompt_value REALITY_SNI "Xray REALITY SNI" "$REALITY_SNI"
      ;;
    edge)
      prompt_required EGRESS_HOST "Публичный host/IP EGRESS-сервера, где запущен Xray REALITY"
      prompt_value EDGE_HOST "Публичный host/IP этого EDGE-сервера, можно оставить пустым" ""
      prompt_required UUID "VLESS UUID, который напечатала установка egress"
      prompt_required REALITY_PUBLIC_KEY "Публичный ключ REALITY, который напечатала установка egress"
      prompt_required REALITY_SHORT_ID "REALITY shortId, который напечатала установка egress"
      prompt_value EDGE_PORT "Публичный MTProxy-порт на этом edge" "$EDGE_PORT"
      prompt_value XRAY_PORT "Порт Xray REALITY на egress" "$XRAY_PORT"
      prompt_value TELEMT_LOCAL_PORT "Локальный порт Telemt на egress" "$TELEMT_LOCAL_PORT"
      prompt_value REALITY_SNI "Xray REALITY SNI" "$REALITY_SNI"
      ;;
    single)
      prompt_required EDGE_HOST "Публичный host/IP этого сервера для Telegram proxy-ссылок"
      prompt_value EDGE_PORT "Публичный MTProxy-порт на этом сервере" "$EDGE_PORT"
      prompt_value TELEMT_SNI "Telemt FakeTLS SNI" "$TELEMT_SNI"
      ;;
  esac

  prompt_value PANEL_BIND "IP-адрес, на котором будет слушать веб-панель" "$PANEL_BIND"
  prompt_value PANEL_PORT "Порт веб-панели" "$PANEL_PORT"
}

validate_args() {
  if [[ -z "$ROLE" ]]; then
    usage
    fatal "--role не дошёл до installer. При запуске bash <(curl ...) ставь параметры ПОСЛЕ закрывающей скобки ')', например: sudo bash <(curl -fsSL URL) --role egress --edge-host edge.example.com --egress-host egress.example.com"
  fi

  [[ "$ROLE" =~ ^(egress|edge|single)$ ]] || fatal "--role должен быть egress, edge или single"
  [[ "$EDGE_PORT" =~ ^[0-9]+$ ]] || fatal "--edge-port должен быть числом"
  [[ "$XRAY_PORT" =~ ^[0-9]+$ ]] || fatal "--xray-port должен быть числом"
  [[ "$XRAY_LOCAL_PORT" =~ ^[0-9]+$ ]] || fatal "--xray-local-port должен быть числом"
  [[ "$TELEMT_LOCAL_PORT" =~ ^[0-9]+$ ]] || fatal "--telemt-local-port должен быть числом"
  [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || fatal "--panel-port должен быть числом"

  for port_value in "$EDGE_PORT" "$XRAY_PORT" "$XRAY_LOCAL_PORT" "$TELEMT_LOCAL_PORT" "$PANEL_PORT"; do
    (( port_value >= 1 && port_value <= 65535 )) || fatal "Порт вне допустимого диапазона: ${port_value}"
  done

  if [[ "$ROLE" == "egress" || "$ROLE" == "single" ]]; then
    [[ -n "$EDGE_HOST" ]] || fatal "Для роли ${ROLE} обязателен --edge-host"
  fi
  if [[ "$ROLE" == "edge" ]]; then
    [[ -n "$EGRESS_HOST" ]] || fatal "Для роли edge обязателен --egress-host"
    [[ -n "$UUID" ]] || fatal "Для роли edge обязателен --uuid"
    [[ -n "$REALITY_PUBLIC_KEY" ]] || fatal "Для роли edge обязателен --reality-public-key"
    [[ -n "$REALITY_SHORT_ID" ]] || fatal "Для роли edge обязателен --short-id"
  fi
  if [[ -z "$REALITY_DEST" ]]; then
    REALITY_DEST="${REALITY_SNI}:443"
  fi
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    interactive_setup
    validate_args
    return 0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role) ROLE="${2:-}"; shift 2 ;;
      --edge-host) EDGE_HOST="${2:-}"; shift 2 ;;
      --egress-host) EGRESS_HOST="${2:-}"; shift 2 ;;
      --edge-port) EDGE_PORT="${2:-}"; shift 2 ;;
      --xray-port) XRAY_PORT="${2:-}"; shift 2 ;;
      --xray-local-port) XRAY_LOCAL_PORT="${2:-}"; shift 2 ;;
      --telemt-local-port) TELEMT_LOCAL_PORT="${2:-}"; shift 2 ;;
      --telemt-sni) TELEMT_SNI="${2:-}"; shift 2 ;;
      --reality-sni) REALITY_SNI="${2:-}"; shift 2 ;;
      --reality-dest) REALITY_DEST="${2:-}"; shift 2 ;;
      --uuid) UUID="${2:-}"; shift 2 ;;
      --reality-private-key) REALITY_PRIVATE_KEY="${2:-}"; shift 2 ;;
      --reality-public-key) REALITY_PUBLIC_KEY="${2:-}"; shift 2 ;;
      --short-id) REALITY_SHORT_ID="${2:-}"; shift 2 ;;
      --panel-bind) PANEL_BIND="${2:-}"; shift 2 ;;
      --panel-port) PANEL_PORT="${2:-}"; shift 2 ;;
      --panel-password) PANEL_PASSWORD="${2:-}"; shift 2 ;;
      --default-user) DEFAULT_USER="${2:-}"; shift 2 ;;
      --no-firewall) NO_FIREWALL="1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fatal "Неизвестный аргумент: $1" ;;
    esac
  done

  validate_args
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  log "Устанавливаю необходимые системные пакеты"
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget jq openssl tar gzip unzip coreutils \
    iproute2 lsof netcat-openbsd procps python3 python3-venv \
    haproxy
}

ensure_systemd() {
  command -v systemctl >/dev/null 2>&1 || fatal "Для установки нужен systemd"
  [[ -d /run/systemd/system ]] || fatal "Похоже, systemd не активен на этом сервере"
}

random_hex() { openssl rand -hex "$1"; }
random_password() { openssl rand -base64 24 | tr -d '=+/ ' | cut -c1-24; }
random_secret32() { openssl rand -hex 16; }

ensure_uuid() {
  if [[ -z "$UUID" ]]; then
    if command -v /usr/local/bin/xray >/dev/null 2>&1; then
      UUID="$(/usr/local/bin/xray uuid 2>/dev/null || true)"
    fi
    [[ -n "$UUID" ]] || UUID="$(cat /proc/sys/kernel/random/uuid)"
  fi
}

configure_sysctl() {
  log "Применяю безопасные сетевые sysctl-настройки"
  cat >/etc/sysctl.d/99-telemt-doublehop.conf <<'EOF'
net.core.somaxconn = 65535
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 10240 65535
EOF
  sysctl --system >/dev/null || warn "Не удалось применить sysctl, продолжаю установку"
}

configure_firewall() {
  [[ "$NO_FIREWALL" == "0" ]] || return 0
  local ports=()
  if [[ "$ROLE" == "edge" || "$ROLE" == "single" ]]; then
    ports+=("${EDGE_PORT}/tcp")
  fi
  if [[ "$ROLE" == "egress" ]]; then
    ports+=("${XRAY_PORT}/tcp")
  fi
  if [[ "$PANEL_BIND" != "127.0.0.1" && "$PANEL_BIND" != "::1" ]]; then
    ports+=("${PANEL_PORT}/tcp")
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    for p in "${ports[@]}"; do ufw allow "$p" || true; done
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    for p in "${ports[@]}"; do firewall-cmd --permanent --add-port="$p" || true; done
    firewall-cmd --reload || true
  fi
}

install_xray() {
  if command -v /usr/local/bin/xray >/dev/null 2>&1; then
    log "Xray уже установлен: $(/usr/local/bin/xray version | head -n1 || true)"
    return 0
  fi
  log "Устанавливаю Xray через официальный installer XTLS"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

generate_reality_keys_if_needed() {
  [[ "$ROLE" == "egress" ]] || return 0
  if [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]]; then
    return 0
  fi
  log "Генерирую пару ключей Xray REALITY x25519"
  local out
  out="$(/usr/local/bin/xray x25519)"
  REALITY_PRIVATE_KEY="$(awk -F': ' '/Private key/{print $2}' <<<"$out" | tr -d '[:space:]')"
  REALITY_PUBLIC_KEY="$(awk -F': ' '/Public key/{print $2}' <<<"$out" | tr -d '[:space:]')"
  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || fatal "Не удалось сгенерировать REALITY-ключи"
  [[ -n "$REALITY_SHORT_ID" ]] || REALITY_SHORT_ID="$(random_hex 8)"
}

install_telemt() {
  if [[ -x "$TELEMT_BIN" ]]; then
    log "Telemt уже установлен: $($TELEMT_BIN --version 2>/dev/null || echo unknown)"
    return 0
  fi

  log "Устанавливаю последний релиз Telemt"
  local arch libc tmp
  arch="$(uname -m)"
  libc="gnu"
  if ldd --version 2>&1 | grep -iq musl; then libc="musl"; fi
  tmp="$(mktemp -d)"
  (
    cd "$tmp"
    wget -qO- "https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz" | tar -xz
    install -m 0755 telemt "$TELEMT_BIN"
  )
  rm -rf "$tmp"
}

create_telemt_user() {
  if ! id telemt >/dev/null 2>&1; then
    useradd -d /opt/telemt -m -r -U telemt
  fi
  mkdir -p /etc/telemt /opt/telemt
  chown -R telemt:telemt /etc/telemt /opt/telemt
}

write_telemt_config() {
  local secret listen_addr listen_port proxy_protocol architecture_comment
  secret="$(random_secret32)"

  if [[ "$ROLE" == "single" ]]; then
    listen_addr="0.0.0.0"
    listen_port="${EDGE_PORT}"
    proxy_protocol="false"
    architecture_comment="Архитектура: Telegram client -> этот VPS:${EDGE_PORT} -> Telemt -> Telegram"
  else
    listen_addr="127.0.0.1"
    listen_port="${TELEMT_LOCAL_PORT}"
    proxy_protocol="true"
    architecture_comment="Архитектура: Telegram client -> edge:${EDGE_PORT} -> HAProxy PROXYv2 -> Xray tunnel -> egress Telemt:${TELEMT_LOCAL_PORT} -> Telegram"
  fi

  log "Записываю конфиг Telemt: ${TELEMT_CONFIG}"
  mkdir -p /etc/telemt
  cat >"$TELEMT_CONFIG" <<EOF
# Managed by ${APP_NAME} v${APP_VERSION}
# ${architecture_comment}

[general]
use_middle_proxy = false

[general.links]
show = "*"
public_host = "${EDGE_HOST}"
public_port = ${EDGE_PORT}

[general.modes]
classic = false
secure = false
tls = true

[server]
port = ${listen_port}
listen_addr_ipv4 = "${listen_addr}"
proxy_protocol = ${proxy_protocol}
max_connections = 10000

[server.api]
enabled = true
listen = "${TELEMT_API_LISTEN}"
whitelist = ["127.0.0.1/32", "::1/128"]

[censorship]
tls_domain = "${TELEMT_SNI}"
unknown_sni_action = "mask"

[access.users]
${DEFAULT_USER} = "${secret}"
EOF
  chown telemt:telemt "$TELEMT_CONFIG"
  chmod 0640 "$TELEMT_CONFIG"
}

write_telemt_service() {
  log "Создаю systemd-unit для telemt"
  cat >/etc/systemd/system/telemt.service <<EOF
[Unit]
Description=Telemt MTProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=${TELEMT_BIN} ${TELEMT_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

write_xray_egress_config() {
  log "Создаю конфиг Xray egress REALITY server"
  mkdir -p /usr/local/etc/xray
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "",
            "email": "edge-to-telemt"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["vless-reality-in"],
        "ip": ["127.0.0.1"],
        "port": "${TELEMT_LOCAL_PORT}",
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "inboundTag": ["vless-reality-in"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
  /usr/local/bin/xray -test -config "$XRAY_CONFIG"
}

write_xray_edge_config() {
  log "Создаю конфиг Xray edge client forward"
  mkdir -p /usr/local/etc/xray
  cat >"$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "local-telemt-forward-in",
      "listen": "127.0.0.1",
      "port": ${XRAY_LOCAL_PORT},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": ${TELEMT_LOCAL_PORT},
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "to-egress-reality",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${EGRESS_HOST}",
            "port": ${XRAY_PORT},
            "users": [
              {
                "id": "${UUID}",
                "encryption": "none",
                "flow": "",
                "level": 0
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${REALITY_SNI}",
          "fingerprint": "chrome",
          "publicKey": "${REALITY_PUBLIC_KEY}",
          "shortId": "${REALITY_SHORT_ID}",
          "spiderX": "/"
        }
      },
      "mux": {
        "enabled": false
      }
    }
  ]
}
EOF
  /usr/local/bin/xray -test -config "$XRAY_CONFIG"
}

write_haproxy_config() {
  log "Создаю конфиг HAProxy для edge"
  cat >"$HAPROXY_CONFIG" <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 20000

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    option clitcpka
    option srvtcpka
    timeout connect 5s
    timeout client 2h
    timeout server 2h
    timeout check 5s

frontend mtproto_public_443
    bind *:${EDGE_PORT}
    maxconn 16000
    option tcp-smart-accept
    default_backend xray_local_tunnel

backend xray_local_tunnel
    option tcp-smart-connect
    server xray_local 127.0.0.1:${XRAY_LOCAL_PORT} check inter 5s rise 2 fall 3 send-proxy-v2
EOF
  haproxy -c -f "$HAPROXY_CONFIG"
}

write_panel_env() {
  mkdir -p "$APP_ETC" "$APP_STATE" "$APP_DIR"
  if [[ -z "$PANEL_PASSWORD" ]]; then
    PANEL_PASSWORD="$(random_password)"
  fi
  cat >"$APP_ETC/panel.env" <<EOF
APP_VERSION=${APP_VERSION}
ROLE=${ROLE}
PANEL_BIND=${PANEL_BIND}
PANEL_PORT=${PANEL_PORT}
PANEL_PASSWORD=${PANEL_PASSWORD}
TELEMT_CONFIG=${TELEMT_CONFIG}
TELEMT_API=http://${TELEMT_API_LISTEN}
XRAY_CONFIG=${XRAY_CONFIG}
HAPROXY_CONFIG=${HAPROXY_CONFIG}
EDGE_HOST=${EDGE_HOST}
EDGE_PORT=${EDGE_PORT}
EGRESS_HOST=${EGRESS_HOST}
XRAY_PORT=${XRAY_PORT}
TELEMT_SNI=${TELEMT_SNI}
REALITY_SNI=${REALITY_SNI}
EOF
  chmod 0600 "$APP_ETC/panel.env"
}

write_panel_app() {
  log "Записываю приложение веб-панели"
  mkdir -p "$APP_DIR"
  cat >"$APP_DIR/server.py" <<'PY_EOF'
#!/usr/bin/env python3
from __future__ import annotations

import base64
import html
import hmac
import http.client
import json
import os
import re
import secrets
import shlex
import subprocess
import time
from dataclasses import dataclass
from hashlib import sha256
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

ENV_PATH = Path("/etc/telemt-panel/panel.env")
SESSION_SECRET_PATH = Path("/var/lib/telemt-panel/session.secret")


def load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    if ENV_PATH.exists():
        for raw in ENV_PATH.read_text(encoding="utf-8").splitlines():
            if not raw or raw.strip().startswith("#") or "=" not in raw:
                continue
            key, value = raw.split("=", 1)
            env[key.strip()] = value.strip()
    return env


ENV = load_env()
APP_VERSION = ENV.get("APP_VERSION", "dev")
ROLE = ENV.get("ROLE", "unknown")
PANEL_PASSWORD = ENV.get("PANEL_PASSWORD", "")
PANEL_BIND = ENV.get("PANEL_BIND", "127.0.0.1")
PANEL_PORT = int(ENV.get("PANEL_PORT", "9444"))
TELEMT_CONFIG = Path(ENV.get("TELEMT_CONFIG", "/etc/telemt/telemt.toml"))
TELEMT_API = ENV.get("TELEMT_API", "http://127.0.0.1:9091").rstrip("/")
EDGE_HOST = ENV.get("EDGE_HOST", "")
EDGE_PORT = ENV.get("EDGE_PORT", "443")
EGRESS_HOST = ENV.get("EGRESS_HOST", "")
XRAY_PORT = ENV.get("XRAY_PORT", "443")
TELEMT_SNI = ENV.get("TELEMT_SNI", "vk.com")
REALITY_SNI = ENV.get("REALITY_SNI", "www.microsoft.com")

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_.-]{1,48}$")
HEX32_RE = re.compile(r"^[0-9a-fA-F]{32}$")


def ensure_session_secret() -> bytes:
    SESSION_SECRET_PATH.parent.mkdir(parents=True, exist_ok=True)
    if not SESSION_SECRET_PATH.exists():
        SESSION_SECRET_PATH.write_bytes(secrets.token_bytes(32))
        SESSION_SECRET_PATH.chmod(0o600)
    return SESSION_SECRET_PATH.read_bytes()


SESSION_SECRET = ensure_session_secret()


def run(cmd: list[str], timeout: int = 12) -> tuple[int, str]:
    try:
        completed = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, check=False)
        return completed.returncode, completed.stdout.strip()
    except Exception as exc:  # noqa: BLE001
        return 1, f"{type(exc).__name__}: {exc}"


def service_status(name: str) -> dict[str, str]:
    code, out = run(["systemctl", "is-active", name], timeout=5)
    enabled_code, enabled = run(["systemctl", "is-enabled", name], timeout=5)
    return {
        "name": name,
        "active": out if code == 0 else (out or "inactive"),
        "enabled": enabled if enabled_code == 0 else (enabled or "disabled"),
    }


def http_get_local(url: str, timeout: int = 4) -> tuple[int, str]:
    parsed = urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 80
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    try:
        conn = http.client.HTTPConnection(host, port, timeout=timeout)
        conn.request("GET", path)
        resp = conn.getresponse()
        body = resp.read(1024 * 1024).decode("utf-8", "replace")
        conn.close()
        return resp.status, body
    except Exception as exc:  # noqa: BLE001
        return 0, f"{type(exc).__name__}: {exc}"


@dataclass(frozen=True)
class TelemtUser:
    name: str
    secret: str


def read_telemt_text() -> str:
    if not TELEMT_CONFIG.exists():
        return ""
    return TELEMT_CONFIG.read_text(encoding="utf-8")


def list_config_users() -> list[TelemtUser]:
    text = read_telemt_text()
    users: list[TelemtUser] = []
    in_users = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            in_users = line == "[access.users]"
            continue
        if not in_users or not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        name = key.strip().strip('"')
        secret_value = value.strip().strip('"')
        if name:
            users.append(TelemtUser(name=name, secret=secret_value))
    return users


def write_users(users: list[TelemtUser]) -> None:
    text = read_telemt_text()
    lines = text.splitlines()
    output: list[str] = []
    in_users = False
    found = False
    inserted = False
    new_user_lines = [f'{u.name} = "{u.secret.lower()}"' for u in sorted(users, key=lambda item: item.name)]

    for raw in lines:
        stripped = raw.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_users and not inserted:
                output.extend(new_user_lines)
                inserted = True
            in_users = stripped == "[access.users]"
            if in_users:
                found = True
            output.append(raw)
            continue
        if in_users:
            if stripped.startswith("#") or not stripped:
                output.append(raw)
            # skip old user entries
            continue
        output.append(raw)

    if in_users and not inserted:
        output.extend(new_user_lines)
    if not found:
        if output and output[-1].strip():
            output.append("")
        output.append("[access.users]")
        output.extend(new_user_lines)

    TELEMT_CONFIG.write_text("\n".join(output).rstrip() + "\n", encoding="utf-8")


def set_public_host(host: str, port: str) -> None:
    text = read_telemt_text()
    lines = text.splitlines()
    out: list[str] = []
    in_links = False
    found_links = False
    host_done = False
    port_done = False
    for raw in lines:
        stripped = raw.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_links:
                if not host_done:
                    out.append(f'public_host = "{host}"')
                if not port_done:
                    out.append(f"public_port = {port}")
            in_links = stripped == "[general.links]"
            found_links = found_links or in_links
            out.append(raw)
            continue
        if in_links and stripped.startswith("public_host"):
            out.append(f'public_host = "{host}"')
            host_done = True
        elif in_links and stripped.startswith("public_port"):
            out.append(f"public_port = {port}")
            port_done = True
        else:
            out.append(raw)
    if in_links:
        if not host_done:
            out.append(f'public_host = "{host}"')
        if not port_done:
            out.append(f"public_port = {port}")
    if not found_links:
        out.extend(["", "[general.links]", 'show = "*"', f'public_host = "{host}"', f"public_port = {port}"])
    TELEMT_CONFIG.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")


def json_or_text(value: str) -> Any:
    try:
        return json.loads(value)
    except Exception:  # noqa: BLE001
        return value


def get_links_payload() -> Any:
    status, body = http_get_local(f"{TELEMT_API}/v1/users")
    if status == 200:
        return json_or_text(body)
    return {"error": body, "status": status}


def make_session() -> str:
    expires = str(int(time.time()) + 86400)
    nonce = secrets.token_urlsafe(16)
    payload = f"{expires}.{nonce}"
    sig = hmac.new(SESSION_SECRET, payload.encode(), sha256).hexdigest()
    return f"{payload}.{sig}"


def verify_session(cookie: str | None) -> bool:
    if not cookie:
        return False
    cookies = {}
    for part in cookie.split(";"):
        if "=" in part:
            k, v = part.strip().split("=", 1)
            cookies[k] = v
    token = cookies.get("telemt_session", "")
    try:
        expires, nonce, sig = token.split(".", 2)
        payload = f"{expires}.{nonce}"
        expected = hmac.new(SESSION_SECRET, payload.encode(), sha256).hexdigest()
        return hmac.compare_digest(expected, sig) and int(expires) > int(time.time())
    except Exception:  # noqa: BLE001
        return False


def page(title: str, body: str) -> bytes:
    html_body = f"""<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>
:root {{ color-scheme: dark; --bg:#0c1016; --card:#151b24; --muted:#8fa1b3; --txt:#e8eef6; --ok:#58d68d; --bad:#ff7675; --warn:#ffd166; --line:#263244; --accent:#7cc7ff; }}
* {{ box-sizing:border-box; }} body {{ margin:0; background:linear-gradient(180deg,#0c1016,#0f141c); color:var(--txt); font:14px/1.5 system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif; }}
main {{ max-width:1120px; margin:0 auto; padding:28px 18px 60px; }}
h1 {{ font-size:28px; margin:0 0 6px; }} h2 {{ font-size:18px; margin:0 0 14px; }}
.sub {{ color:var(--muted); margin-bottom:22px; }}
.grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr)); gap:16px; }}
.card {{ background:rgba(21,27,36,.92); border:1px solid var(--line); border-radius:18px; padding:18px; box-shadow:0 12px 30px rgba(0,0,0,.2); }}
.row {{ display:flex; justify-content:space-between; gap:12px; border-bottom:1px solid var(--line); padding:8px 0; }}
.row:last-child {{ border-bottom:0; }} .muted {{ color:var(--muted); }} .ok {{ color:var(--ok); }} .bad {{ color:var(--bad); }} .warn {{ color:var(--warn); }}
code, pre {{ background:#0a0f15; border:1px solid var(--line); border-radius:12px; }} code {{ padding:2px 6px; }} pre {{ padding:12px; overflow:auto; max-height:360px; }}
input, select {{ width:100%; padding:10px 12px; border-radius:12px; border:1px solid var(--line); background:#0a0f15; color:var(--txt); }}
label {{ display:block; margin:10px 0 6px; color:var(--muted); }}
button, .btn {{ display:inline-flex; align-items:center; gap:8px; padding:10px 14px; border:0; border-radius:12px; background:var(--accent); color:#03121f; font-weight:700; cursor:pointer; text-decoration:none; }}
button.secondary {{ background:#263244; color:var(--txt); }} button.danger {{ background:#ff7675; color:#190505; }}
form.inline {{ display:inline; }} .actions {{ display:flex; flex-wrap:wrap; gap:8px; margin-top:12px; }}
.table {{ width:100%; border-collapse:collapse; }} .table th,.table td {{ text-align:left; border-bottom:1px solid var(--line); padding:9px 6px; vertical-align:top; }}
.notice {{ border-left:4px solid var(--warn); padding:10px 12px; background:#1f1b10; border-radius:12px; }}
.topbar {{ display:flex; justify-content:space-between; align-items:center; gap:16px; margin-bottom:18px; }}
@media(max-width:720px) {{ .topbar {{ align-items:flex-start; flex-direction:column; }} }}
</style>
</head>
<body><main>{body}</main></body></html>"""
    return html_body.encode("utf-8")


def esc(value: Any) -> str:
    return html.escape(str(value))


class Handler(BaseHTTPRequestHandler):
    server_version = f"TelemtPanel/{APP_VERSION}"

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def send_html(self, content: bytes, status: int = 200, headers: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        if headers:
            for key, value in headers.items():
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(content)

    def redirect(self, location: str) -> None:
        self.send_response(303)
        self.send_header("Location", location)
        self.end_headers()

    def read_form(self) -> dict[str, str]:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8", "replace")
        return {k: v[-1] for k, v in parse_qs(raw).items()}

    def authenticated(self) -> bool:
        return verify_session(self.headers.get("Cookie"))

    def require_auth(self) -> bool:
        if self.authenticated():
            return True
        self.redirect("/login")
        return False

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/login":
            self.render_login()
            return
        if path == "/logout":
            self.send_html(page("Logout", "<p>Logged out.</p>"), headers={"Set-Cookie": "telemt_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict"})
            return
        if not self.require_auth():
            return
        if path == "/":
            self.render_dashboard()
        elif path == "/logs":
            self.render_logs()
        elif path == "/diagnostics":
            self.render_diagnostics()
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/login":
            form = self.read_form()
            if hmac.compare_digest(form.get("password", ""), PANEL_PASSWORD):
                token = make_session()
                self.send_response(303)
                self.send_header("Location", "/")
                self.send_header("Set-Cookie", f"telemt_session={token}; Path=/; HttpOnly; SameSite=Strict")
                self.end_headers()
            else:
                self.send_html(page("Login", "<p class='bad'>Неверный пароль.</p><p><a class='btn' href='/login'>Назад</a></p>"), status=403)
            return
        if not self.require_auth():
            return
        form = self.read_form()
        try:
            if path == "/users/add":
                self.action_add_user(form)
            elif path == "/users/delete":
                self.action_delete_user(form)
            elif path == "/public-host":
                self.action_public_host(form)
            elif path == "/service/restart":
                self.action_restart_service(form)
            else:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            self.redirect("/")
        except Exception as exc:  # noqa: BLE001
            self.send_html(page("Error", f"<h1>Ошибка</h1><pre>{esc(type(exc).__name__ + ': ' + str(exc))}</pre><p><a class='btn' href='/'>Назад</a></p>"), status=500)

    def action_add_user(self, form: dict[str, str]) -> None:
        name = form.get("name", "").strip()
        secret_value = form.get("secret", "").strip().lower() or secrets.token_hex(16)
        if not USERNAME_RE.fullmatch(name):
            raise ValueError("username: only latin letters, digits, _, ., -, max 48 chars")
        if not HEX32_RE.fullmatch(secret_value):
            raise ValueError("secret must be 32 hex chars")
        users = [u for u in list_config_users() if u.name != name]
        users.append(TelemtUser(name=name, secret=secret_value))
        write_users(users)
        run(["chown", "telemt:telemt", str(TELEMT_CONFIG)], timeout=5)
        run(["chmod", "0640", str(TELEMT_CONFIG)], timeout=5)
        run(["systemctl", "restart", "telemt"], timeout=20)

    def action_delete_user(self, form: dict[str, str]) -> None:
        name = form.get("name", "").strip()
        users = [u for u in list_config_users() if u.name != name]
        write_users(users)
        run(["chown", "telemt:telemt", str(TELEMT_CONFIG)], timeout=5)
        run(["systemctl", "restart", "telemt"], timeout=20)

    def action_public_host(self, form: dict[str, str]) -> None:
        host = form.get("host", "").strip()
        port = form.get("port", "443").strip()
        if not host or any(ch.isspace() for ch in host):
            raise ValueError("public host is invalid")
        if not port.isdigit() or not (1 <= int(port) <= 65535):
            raise ValueError("public port is invalid")
        set_public_host(host, port)
        run(["chown", "telemt:telemt", str(TELEMT_CONFIG)], timeout=5)
        run(["systemctl", "restart", "telemt"], timeout=20)

    def action_restart_service(self, form: dict[str, str]) -> None:
        service = form.get("service", "")
        allowed = {"telemt", "xray", "haproxy", "telemt-panel"}
        if service not in allowed:
            raise ValueError("service is not allowed")
        run(["systemctl", "restart", service], timeout=25)

    def render_login(self) -> None:
        body = """
<div class="card" style="max-width:420px;margin:10vh auto 0">
  <h1>Telemt Double Hop Panel</h1>
  <p class="sub">Вход в локальную панель управления.</p>
  <form method="post" action="/login">
    <label>Пароль</label>
    <input name="password" type="password" autofocus required>
    <div class="actions"><button type="submit">Войти</button></div>
  </form>
</div>
"""
        self.send_html(page("Login", body))

    def render_dashboard(self) -> None:
        services = [service_status(name) for name in ("telemt", "xray", "haproxy", "telemt-panel")]
        users = list_config_users()
        links = get_links_payload() if ROLE in {"egress", "single"} else {"note": "ссылки генерируются на роли egress"}
        health_status, health_body = http_get_local(f"{TELEMT_API}/v1/health/ready") if ROLE in {"egress", "single"} else (0, "edge role")

        service_rows = "".join(
            f"<tr><td>{esc(s['name'])}</td><td class='{ 'ok' if s['active'] == 'active' else 'bad' }'>{esc(s['active'])}</td><td>{esc(s['enabled'])}</td>"
            f"<td><form class='inline' method='post' action='/service/restart'><input type='hidden' name='service' value='{esc(s['name'])}'><button class='secondary' type='submit'>перезапустить</button></form></td></tr>"
            for s in services
        )
        user_rows = "".join(
            f"<tr><td><code>{esc(u.name)}</code></td><td><code>{esc(u.secret)}</code></td><td>"
            f"<form class='inline' method='post' action='/users/delete' onsubmit=\"return confirm('Удалить пользователя {esc(u.name)}?')\"><input type='hidden' name='name' value='{esc(u.name)}'><button class='danger' type='submit'>удалить</button></form>"
            f"</td></tr>" for u in users
        ) or "<tr><td colspan='3' class='muted'>Нет пользователей в telemt.toml</td></tr>"

        body = f"""
<div class="topbar"><div><h1>Telemt + Xray Double Hop</h1><div class="sub">роль: <code>{esc(ROLE)}</code> · версия: <code>{esc(APP_VERSION)}</code></div></div><a class="btn" href="/logout">Выйти</a></div>
<div class="notice">Панель по умолчанию рассчитана на доступ через SSH tunnel. Не публикуй её в Интернет без firewall/VPN.</div>
<div class="grid" style="margin-top:16px">
  <section class="card">
    <h2>Архитектура</h2>
    <div class="row"><span class="muted">Публичный MTProxy host</span><span><code>{esc(EDGE_HOST or 'set on egress')}</code>:{esc(EDGE_PORT)}</span></div>
    <div class="row"><span class="muted">Telemt FakeTLS SNI</span><span><code>{esc(TELEMT_SNI)}</code></span></div>
    <div class="row"><span class="muted">Egress host</span><span><code>{esc(EGRESS_HOST or 'this host / n/a')}</code>:{esc(XRAY_PORT)}</span></div>
    <div class="row"><span class="muted">Xray REALITY SNI</span><span><code>{esc(REALITY_SNI)}</code></span></div>
    <div class="row"><span class="muted">Готовность Telemt</span><span class="{ 'ok' if health_status == 200 else 'warn' }">HTTP {esc(health_status)}</span></div>
  </section>
  <section class="card">
    <h2>Public host для ссылок</h2>
    <form method="post" action="/public-host">
      <label>Host/IP edge-сервера</label><input name="host" value="{esc(EDGE_HOST)}" placeholder="edge.example.com">
      <label>Port</label><input name="port" value="{esc(EDGE_PORT)}">
      <div class="actions"><button type="submit">Сохранить и перезапустить telemt</button></div>
    </form>
  </section>
</div>

<section class="card" style="margin-top:16px">
  <h2>Сервисы</h2>
  <table class="table"><thead><tr><th>сервис</th><th>статус</th><th>автозапуск</th><th></th></tr></thead><tbody>{service_rows}</tbody></table>
</section>

<section class="card" style="margin-top:16px">
  <h2>Пользователи Telemt</h2>
  <table class="table"><thead><tr><th>name</th><th>secret</th><th></th></tr></thead><tbody>{user_rows}</tbody></table>
  <form method="post" action="/users/add" style="margin-top:14px">
    <div class="grid">
      <div><label>Имя</label><input name="name" placeholder="client1" required></div>
      <div><label>Secret, 32 hex; пусто = сгенерировать</label><input name="secret" placeholder="auto"></div>
    </div>
    <div class="actions"><button type="submit">Добавить пользователя</button></div>
  </form>
</section>

<section class="card" style="margin-top:16px">
  <h2>Ссылки Telemt API</h2>
  <pre>{esc(json.dumps(links, ensure_ascii=False, indent=2) if not isinstance(links, str) else links)}</pre>
</section>

<section class="card" style="margin-top:16px">
  <h2>Быстрые действия</h2>
  <div class="actions"><a class="btn" href="/diagnostics">Диагностика</a><a class="btn" href="/logs?service=telemt">Логи telemt</a><a class="btn" href="/logs?service=xray">Логи xray</a><a class="btn" href="/logs?service=haproxy">Логи haproxy</a></div>
</section>
"""
        self.send_html(page("Telemt Double Hop", body))

    def render_logs(self) -> None:
        query = parse_qs(urlparse(self.path).query)
        service = query.get("service", ["telemt"])[0]
        if service not in {"telemt", "xray", "haproxy", "telemt-panel"}:
            service = "telemt"
        _, out = run(["journalctl", "-u", service, "-n", "220", "--no-pager"], timeout=10)
        body = f"<h1>Логи {esc(service)}</h1><p><a class='btn' href='/'>Назад</a></p><pre>{esc(out)}</pre>"
        self.send_html(page("Logs", body))

    def render_diagnostics(self) -> None:
        checks: list[tuple[str, list[str]]] = [
            ("Listening sockets", ["ss", "-lntup"]),
            ("Telemt ready", ["bash", "-lc", f"curl -fsS {shlex.quote(TELEMT_API)}/v1/health/ready || true"]),
            ("Telemt users", ["bash", "-lc", f"curl -fsS {shlex.quote(TELEMT_API)}/v1/users | jq . || true"]),
            ("Xray config test", ["bash", "-lc", "test -x /usr/local/bin/xray && /usr/local/bin/xray -test -config /usr/local/etc/xray/config.json || true"]),
            ("HAProxy config test", ["bash", "-lc", "test -f /etc/haproxy/haproxy.cfg && haproxy -c -f /etc/haproxy/haproxy.cfg || true"]),
            ("Disk", ["df", "-h"]),
            ("Memory", ["free", "-h"]),
        ]
        blocks = []
        for title, cmd in checks:
            code, out = run(cmd, timeout=12)
            cls = "ok" if code == 0 else "warn"
            blocks.append(f"<section class='card' style='margin-top:14px'><h2>{esc(title)} <span class='{cls}'>exit {code}</span></h2><pre>{esc(out)}</pre></section>")
        body = "<h1>Диагностика</h1><p><a class='btn' href='/'>Назад</a></p>" + "".join(blocks)
        self.send_html(page("Diagnostics", body))


def main() -> None:
    if not PANEL_PASSWORD:
        raise SystemExit("PANEL_PASSWORD пустой в /etc/telemt-panel/panel.env")
    server = ThreadingHTTPServer((PANEL_BIND, PANEL_PORT), Handler)
    print(f"Панель Telemt слушает http://{PANEL_BIND}:{PANEL_PORT}/ роль={ROLE}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
PY_EOF
  chmod 0755 "$APP_DIR/server.py"
}

write_panel_service() {
  log "Создаю systemd-unit для веб-панели"
  cat >/etc/systemd/system/${PANEL_SERVICE} <<EOF
[Unit]
Description=Telemt Double Hop Web Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=${APP_ETC}/panel.env
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/python3 ${APP_DIR}/server.py
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

write_helper_cli() {
  log "Создаю helper CLI /usr/local/sbin/telemt-doublehop"
  cat >/usr/local/sbin/telemt-doublehop <<'CLI_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
TELEMT_CONFIG="/etc/telemt/telemt.toml"
cmd="${1:-status}"
case "$cmd" in
  status)
    systemctl --no-pager --full status telemt xray haproxy telemt-panel || true
    ;;
  links)
    curl -fsS http://127.0.0.1:9091/v1/users | jq .
    ;;
  ready)
    curl -fsS http://127.0.0.1:9091/v1/health/ready | jq . || true
    ;;
  logs)
    svc="${2:-telemt}"
    journalctl -u "$svc" -n 200 --no-pager
    ;;
  restart)
    svc="${2:-telemt}"
    systemctl restart "$svc"
    ;;
  set-edge-host)
    host="${2:?usage: telemt-doublehop set-edge-host HOST [PORT]}"
    port="${3:-443}"
    python3 - "$TELEMT_CONFIG" "$host" "$port" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1]); host=sys.argv[2]; port=sys.argv[3]
text=path.read_text(); lines=text.splitlines(); out=[]; in_links=False; found=False; hd=False; pd=False
for raw in lines:
    s=raw.strip()
    if s.startswith('[') and s.endswith(']'):
        if in_links:
            if not hd: out.append(f'public_host = "{host}"')
            if not pd: out.append(f'public_port = {port}')
        in_links = s == '[general.links]'; found = found or in_links; out.append(raw); continue
    if in_links and s.startswith('public_host'):
        out.append(f'public_host = "{host}"'); hd=True
    elif in_links and s.startswith('public_port'):
        out.append(f'public_port = {port}'); pd=True
    else: out.append(raw)
if in_links:
    if not hd: out.append(f'public_host = "{host}"')
    if not pd: out.append(f'public_port = {port}')
if not found: out.extend(['','[general.links]','show = "*"', f'public_host = "{host}"', f'public_port = {port}'])
path.write_text('\n'.join(out).rstrip()+'\n')
PY
    chown telemt:telemt "$TELEMT_CONFIG"
    systemctl restart telemt
    ;;
  *)
    echo "Использование: telemt-doublehop {status|links|ready|logs [service]|restart [service]|set-edge-host HOST [PORT]}" >&2
    exit 2
    ;;
esac
CLI_EOF
  chmod 0755 /usr/local/sbin/telemt-doublehop
}

start_services() {
  if [[ "$ROLE" == "egress" || "$ROLE" == "single" ]]; then
    systemctl enable --now telemt
  fi
  if [[ "$ROLE" == "egress" || "$ROLE" == "edge" ]]; then
    systemctl enable --now xray
  fi
  if [[ "$ROLE" == "edge" ]]; then
    systemctl enable --now haproxy
  fi
  systemctl enable --now telemt-panel
}

wait_for_port() {
  local host="$1" port="$2" label="$3" max="${4:-60}"
  log "Жду запуск ${label} на ${host}:${port}"
  for _ in $(seq 1 "$max"); do
    if nc -z "$host" "$port" >/dev/null 2>&1; then
      log "${label} доступен"
      return 0
    fi
    sleep 1
  done
  warn "${label} не стал доступен за ${max} сек."
  return 1
}

post_install_info() {
  echo
  echo "============================================================"
  echo "${APP_NAME} v${APP_VERSION} установлен"
  echo "Роль: ${ROLE}"
  echo "Веб-панель: http://${PANEL_BIND}:${PANEL_PORT}/"
  echo "Пароль веб-панели: ${PANEL_PASSWORD}"
  echo "Helper CLI: telemt-doublehop {status|links|ready|logs|restart}"
  echo "Лог установки: ${LOG_FILE}"

  if [[ "$ROLE" == "egress" ]]; then
    echo
    echo "Выполни это на EDGE-сервере, при необходимости замени --egress-host:"
    echo "sudo bash ${APP_NAME}-v${APP_VERSION}.sh --role edge \\" 
    echo "  --egress-host ${EGRESS_HOST:-<EGRESS_PUBLIC_IP_OR_DOMAIN>} --xray-port ${XRAY_PORT} \\" 
    echo "  --uuid ${UUID} --reality-public-key ${REALITY_PUBLIC_KEY} --short-id ${REALITY_SHORT_ID} \\" 
    echo "  --reality-sni ${REALITY_SNI} --telemt-local-port ${TELEMT_LOCAL_PORT}"
    echo
    echo "После установки edge открой панель на egress и проверь ссылки."
  fi

  if [[ "$ROLE" == "edge" ]]; then
    echo
    echo "Публичная MTProxy-точка edge: ${EDGE_HOST:-<this-edge-host>}:${EDGE_PORT}"
    echo "Теперь зайди в панель egress и убедись, что public_host указывает на этот edge-host."
  fi

  if [[ "$ROLE" == "single" ]]; then
    echo
    echo "Публичная MTProxy-точка single: ${EDGE_HOST}:${EDGE_PORT}"
  fi

  if [[ "$ROLE" == "egress" || "$ROLE" == "single" ]]; then
    echo
    echo "Текущие Telemt-ссылки из API:"
    curl -fsS "http://${TELEMT_API_LISTEN}/v1/users" | jq . || true
  fi
  echo "============================================================"
}

main() {
  require_root
  parse_args "$@"
  ensure_systemd
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"

  log "Запускаю установку ${APP_NAME} v${APP_VERSION}, роль=${ROLE}"
  apt_install
  configure_sysctl

  if [[ "$ROLE" == "egress" || "$ROLE" == "edge" ]]; then
    install_xray
  fi
  if [[ "$ROLE" == "egress" || "$ROLE" == "single" ]]; then
    install_telemt
    create_telemt_user
  fi

  if [[ "$ROLE" == "egress" ]]; then
    ensure_uuid
    generate_reality_keys_if_needed
    write_xray_egress_config
    write_telemt_config
    write_telemt_service
  elif [[ "$ROLE" == "edge" ]]; then
    write_xray_edge_config
    write_haproxy_config
  elif [[ "$ROLE" == "single" ]]; then
    ensure_uuid
    write_telemt_config
    write_telemt_service
  fi

  configure_firewall
  write_panel_env
  write_panel_app
  write_panel_service
  write_helper_cli
  start_services

  if [[ "$ROLE" == "egress" || "$ROLE" == "single" ]]; then
    local telemt_wait_port="${TELEMT_LOCAL_PORT}"
    [[ "$ROLE" == "single" ]] && telemt_wait_port="${EDGE_PORT}"
    wait_for_port 127.0.0.1 "${telemt_wait_port}" "Telemt TCP" 90 || true
    wait_for_port 127.0.0.1 "9091" "Telemt API" 90 || true
  fi
  if [[ "$ROLE" == "edge" ]]; then
    wait_for_port 127.0.0.1 "${XRAY_LOCAL_PORT}" "локальный forward Xray" 30 || true
    wait_for_port 127.0.0.1 "${EDGE_PORT}" "публичный listener HAProxy" 30 || true
  fi

  post_install_info
}

main "$@"
