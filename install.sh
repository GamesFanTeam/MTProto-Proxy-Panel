#!/usr/bin/env bash
# One-click MTProto Proxy installer: Telemt Direct + Fake TLS (SNI vk.com)
# Version: 1.0
#
# Why Telemt Direct:
#   seriyps/mtproto_proxy requires https://core.telegram.org/getProxySecret
#   and getProxyConfig at startup. On VPS networks where that bootstrap URL
#   is blocked, it cannot start. Telemt with use_middle_proxy=false routes
#   directly to Telegram DCs and does not require the Middle Proxy bootstrap.
#
# Defaults:
#   - Ubuntu/Debian VPS
#   - TCP port: 443
#   - Fake TLS only
#   - SNI: vk.com
#   - public IPv4 detected automatically
#   - Telemt pinned to 3.4.13
#
# Optional overrides:
#   PORT=8443 SERVER_IP=203.0.113.10 sudo -E bash ./mtproto-telemt-direct-faketls-v1.0.sh
#   ROTATE_SECRET=1 sudo -E bash ./mtproto-telemt-direct-faketls-v1.0.sh

set -Eeuo pipefail
umask 077

readonly INSTALLER_VERSION="1.0"
readonly TELEMT_VERSION="3.4.13"
readonly SNI="vk.com"
readonly USERNAME="main"
readonly FAILED_SERIYPS_CONTAINER="mtproto-proxy-seriyps"
readonly SERVICE_NAME="telemt"
readonly CONFIG_DIR="/etc/telemt"
readonly CONFIG_FILE="/etc/telemt/telemt.toml"
readonly STATE_FILE="/etc/telemt/direct-faketls.state"
readonly DATA_DIR="/var/lib/telemt"
readonly WORK_DIR="/opt/telemt"
readonly BINARY_PATH="/usr/local/bin/telemt"
readonly SERVICE_FILE="/etc/systemd/system/telemt.service"
readonly LINK_FILE="/root/mtproto-proxy-link.txt"
readonly LOG_FILE="/var/log/telemt-direct-faketls-install.log"
readonly BACKUP_ROOT="/var/backups/telemt-direct-faketls"

PORT="${PORT:-443}"
SERVER_IP="${SERVER_IP:-}"
ROTATE_SECRET="${ROTATE_SECRET:-0}"
SECRET=""

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

info()    { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
ok()      { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
fail()    { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local line="$1"
  local cmd="$2"
  printf '\033[1;31m[FAIL]\033[0m Ошибка на строке %s: %s\n' "$line" "$cmd" >&2
  printf 'Журнал установки: %s\n' "$LOG_FILE" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_root() {
  [[ "$EUID" -eq 0 ]] || fail "Запустите от root: sudo bash $0"
}

validate_port() {
  [[ "$PORT" =~ ^[0-9]+$ ]] || fail "PORT должен быть числом."
  (( PORT >= 1 && PORT <= 65535 )) || fail "PORT должен быть в диапазоне 1..65535."
}

is_ipv4() {
  local ip="$1"
  awk -F. '
    NF != 4 { exit 1 }
    { for (i=1; i<=4; i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1 }
  ' <<<"$ip"
}

is_private_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] ||
  [[ "$ip" =~ ^127\. ]] ||
  [[ "$ip" =~ ^169\.254\. ]] ||
  [[ "$ip" =~ ^192\.168\. ]] ||
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] ||
  [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}

detect_public_ipv4() {
  local ip=""
  local url=""
  if [[ -n "$SERVER_IP" ]]; then
    is_ipv4 "$SERVER_IP" || fail "SERVER_IP некорректен: $SERVER_IP"
    printf '%s' "$SERVER_IP"
    return
  fi

  for url in "https://api.ipify.org" "https://ipv4.icanhazip.com"; do
    ip="$(curl -4fsS --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$ip" ]] && is_ipv4 "$ip" && ! is_private_ipv4 "$ip"; then
      printf '%s' "$ip"
      return
    fi
  done

  fail "Не удалось определить публичный IPv4. Запустите: SERVER_IP=ВАШ_IP sudo -E bash $0"
}

install_dependencies() {
  [[ -r /etc/os-release ]] || fail "Поддерживаются Debian/Ubuntu."
  # shellcheck source=/dev/null
  source /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) fail "Поддерживаются Debian/Ubuntu. Найдено: ${PRETTY_NAME:-unknown}." ;;
  esac

  info "Установка зависимостей на ${PRETTY_NAME:-$ID}..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl openssl tar iproute2 jq
  ok "Зависимости готовы."
}

backup_existing_installation() {
  local stamp backup_dir
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="$BACKUP_ROOT/$stamp"
  mkdir -p "$backup_dir"

  [[ -d "$CONFIG_DIR" ]] && cp -a "$CONFIG_DIR" "$backup_dir/" || true
  [[ -f "$SERVICE_FILE" ]] && cp -a "$SERVICE_FILE" "$backup_dir/" || true
  [[ -f "$BINARY_PATH" ]] && cp -a "$BINARY_PATH" "$backup_dir/" || true

  ok "Резервная копия предыдущих файлов: $backup_dir"
}

stop_failed_previous_attempt() {
  if command -v docker >/dev/null 2>&1 && docker container inspect "$FAILED_SERIYPS_CONTAINER" >/dev/null 2>&1; then
    info "Удаляю аварийный контейнер прежней попытки: $FAILED_SERIYPS_CONTAINER"
    docker rm -f "$FAILED_SERIYPS_CONTAINER" >/dev/null 2>&1 || true
  fi

  if systemctl list-unit-files "${SERVICE_NAME}.service" --no-legend 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
    systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  fi
}

ensure_port_free() {
  local in_use=""
  in_use="$(ss -H -ltnp 2>/dev/null | awk -v p=":${PORT}" '$4 ~ (p "$") {print; exit}' || true)"
  [[ -z "$in_use" ]] || fail "TCP-порт ${PORT} уже занят: ${in_use}. Освободите порт или используйте PORT=8443."
}

load_or_create_secret() {
  mkdir -p "$CONFIG_DIR"
  SECRET=""

  if [[ -f "$STATE_FILE" && "$ROTATE_SECRET" != "1" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
    if [[ "${SECRET:-}" =~ ^[0-9a-f]{32}$ ]]; then
      info "Сохраняю ранее созданный клиентский секрет и ссылку."
      return
    fi
  fi

  SECRET="$(openssl rand -hex 16)"
  [[ "$ROTATE_SECRET" == "1" ]] && warn "Создан новый secret: старая ссылка перестанет подключаться."
}

download_telemt() {
  local arch libc asset tmpdir archive pinned_url latest_url
  arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64) ;;
    *) fail "Архитектура $arch не поддержана этим установщиком." ;;
  esac

  libc="gnu"
  if ldd --version 2>&1 | grep -qi musl; then
    libc="musl"
  fi

  asset="telemt-${arch}-linux-${libc}.tar.gz"
  pinned_url="https://github.com/telemt/telemt/releases/download/${TELEMT_VERSION}/${asset}"
  latest_url="https://github.com/telemt/telemt/releases/latest/download/${asset}"
  tmpdir="$(mktemp -d)"
  archive="$tmpdir/$asset"

  info "Загрузка Telemt ${TELEMT_VERSION} (${asset})..."
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 -o "$archive" "$pinned_url"; then
    warn "Pinned asset ${TELEMT_VERSION} недоступен; пробую latest asset из официального репозитория."
    curl -fL --retry 3 --connect-timeout 15 --max-time 180 -o "$archive" "$latest_url" ||
      fail "Не удалось скачать бинарник Telemt с GitHub."
  fi

  tar -xzf "$archive" -C "$tmpdir"
  [[ -x "$tmpdir/telemt" ]] || chmod +x "$tmpdir/telemt" 2>/dev/null || true
  [[ -f "$tmpdir/telemt" ]] || fail "В архиве Telemt не найден бинарник telemt."

  install -m 0755 "$tmpdir/telemt" "$BINARY_PATH"
  rm -rf "$tmpdir"
  ok "Telemt установлен: $BINARY_PATH"
}

create_user_and_direct_config() {
  if ! id -u telemt >/dev/null 2>&1; then
    useradd --system --home-dir "$WORK_DIR" --create-home --shell /usr/sbin/nologin telemt
  fi

  mkdir -p "$CONFIG_DIR" "$DATA_DIR/tlsfront" "$WORK_DIR"
  chown -R telemt:telemt "$DATA_DIR" "$WORK_DIR"

  cat > "$CONFIG_FILE" <<EOF
# Generated by mtproto-telemt-direct-faketls-v${INSTALLER_VERSION}.sh
# Transport: Telegram client -> this VPS -> Telegram DC directly
# No Middle Proxy and no getProxySecret/getProxyConfig bootstrap are used.

[general]
config_strict = true
use_middle_proxy = false
fast_mode = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${SERVER_IP}"
public_port = ${PORT}

[server]
port = ${PORT}

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${SNI}"
mask = true
tls_emulation = true
tls_front_dir = "${DATA_DIR}/tlsfront"

[access.users]
${USERNAME} = "${SECRET}"
EOF

  chmod 600 "$CONFIG_FILE"
  chown root:telemt "$CONFIG_FILE"

  cat > "$STATE_FILE" <<EOF
SECRET='${SECRET}'
EOF
  chmod 600 "$STATE_FILE"
  ok "Создан Direct-конфиг: Fake TLS only, SNI=${SNI}, port=${PORT}."
}

create_systemd_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Telemt MTProto Proxy Direct Fake TLS (${SNI})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=${DATA_DIR}
ExecStart=${BINARY_PATH} ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
}

allow_ufw_if_active() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${PORT}/tcp" >/dev/null
    ok "UFW: открыт TCP-порт ${PORT}."
  fi
}

probe_known_telegram_dcs() {
  local endpoint host port good=0
  local -a endpoints=(
    "149.154.175.50:443"
    "149.154.167.51:443"
    "149.154.175.100:443"
    "149.154.167.91:443"
    "149.154.171.5:443"
    "91.105.192.100:443"
  )

  info "Проверка исходящего TCP-доступа к известным Telegram DC:443..."
  for endpoint in "${endpoints[@]}"; do
    host="${endpoint%:*}"
    port="${endpoint##*:}"
    if timeout 4 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
      printf '  [ OK ] %s доступен\n' "$endpoint"
      good=$((good + 1))
    else
      printf '  [ -- ] %s недоступен за 4 с\n' "$endpoint"
    fi
  done

  if (( good == 0 )); then
    warn "Ни один проверенный Telegram DC не доступен. Сервис установится, но прокси, вероятнее всего, не соединится на этом VPS."
  else
    ok "Доступны Telegram DC: ${good} из ${#endpoints[@]}."
  fi
}

start_and_wait() {
  local attempt
  info "Запуск Telemt Direct; инициализация DC может занять до 90 секунд..."
  systemctl restart "$SERVICE_NAME"

  for attempt in {1..90}; do
    if ss -H -ltn 2>/dev/null | awk -v p=":${PORT}" '$4 ~ (p "$") {found=1} END {exit !found}'; then
      ok "Telemt слушает TCP-порт ${PORT}."
      return 0
    fi
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
      journalctl -u "$SERVICE_NAME" -n 100 --no-pager || true
      fail "Telemt завершился при запуске."
    fi
    sleep 1
  done

  journalctl -u "$SERVICE_NAME" -n 120 --no-pager || true
  fail "Telemt не открыл порт ${PORT} за 90 секунд."
}

get_and_save_link() {
  local response tg_link=""
  response="$(curl -fsS --retry 3 --retry-delay 1 http://127.0.0.1:9091/v1/users 2>/dev/null || true)"
  if [[ -n "$response" ]]; then
    tg_link="$(jq -r '.data[]? | .links.tls[]? // empty' <<<"$response" | head -n1 || true)"
  fi

  if [[ -z "$tg_link" ]]; then
    tg_link="$(journalctl -u "$SERVICE_NAME" --no-pager -n 200 2>/dev/null | sed -n 's/.*EE-TLS:[[:space:]]*\(tg:\/\/proxy[^[:space:]]*\).*/\1/p' | tail -n1 || true)"
  fi

  [[ -n "$tg_link" ]] || fail "Сервис запущен, но не удалось получить Fake TLS ссылку из API Telemt. Проверьте: curl -s http://127.0.0.1:9091/v1/users | jq"

  cat > "$LINK_FILE" <<EOF
MTProto Proxy / Telemt ${TELEMT_VERSION}
Mode: Direct DC (use_middle_proxy=false)
Server: ${SERVER_IP}
Port: ${PORT}
Fake TLS SNI: ${SNI}

${tg_link}
EOF
  chmod 600 "$LINK_FILE"

  printf '\n============================================================\n'
  printf ' MTProto Proxy установлен: Telemt Direct + Fake TLS\n'
  printf '============================================================\n'
  printf 'IP сервера: %s\n' "$SERVER_IP"
  printf 'Порт:       %s/tcp\n' "$PORT"
  printf 'SNI:        %s\n' "$SNI"
  printf 'Маршрут:    Telegram client -> VPS -> Telegram DC (Direct)\n'
  printf 'Middle:     отключён; core.telegram.org bootstrap не нужен\n\n'
  printf 'Ссылка для Telegram:\n%s\n\n' "$tg_link"
  printf 'Ссылка сохранена: %s\n' "$LINK_FILE"
  printf 'Проверка логов:    journalctl -u telemt -n 100 --no-pager\n'
  printf '============================================================\n'
}

main() {
  require_root
  validate_port
  info "MTProto one-click installer v${INSTALLER_VERSION}: Telemt Direct + Fake TLS ${SNI}, port ${PORT}."

  install_dependencies
  SERVER_IP="$(detect_public_ipv4)"
  ok "Публичный IPv4 сервера: ${SERVER_IP}."

  backup_existing_installation
  stop_failed_previous_attempt
  ensure_port_free
  load_or_create_secret
  download_telemt
  create_user_and_direct_config
  create_systemd_service
  allow_ufw_if_active
  probe_known_telegram_dcs
  start_and_wait
  get_and_save_link
}

main "$@"
