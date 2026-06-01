#!/usr/bin/env bash
# Telemt Direct + Fake TLS one-click installer
# Version: 1.1
#
# Baseline route:
#   Telegram client -> VPS:443 -> Telemt -> Telegram DC (Direct)
#
# Policy:
#   - Telemt is pinned to 3.4.13.
#   - Middle Proxy / ad_tag / sponsor mode are not configured.
#   - Cascade is not configured or activated by this standalone installer.
#   - Fake TLS SNI defaults to vk.com and may be chosen only from the allow-list below.
#
# Run:
#   sudo bash ./mtproto-telemt-direct-faketls-v1.1.sh
#
# Optional:
#   SNI=yandex.ru sudo -E bash ./mtproto-telemt-direct-faketls-v1.1.sh
#   PORT=8443 SERVER_HOST=proxy.example.com sudo -E bash ./mtproto-telemt-direct-faketls-v1.1.sh
#   ROTATE_SECRET=1 sudo -E bash ./mtproto-telemt-direct-faketls-v1.1.sh

set -Eeuo pipefail
umask 077

readonly INSTALLER_VERSION="1.1"
readonly TELEMT_VERSION="3.4.13"
readonly SERVICE_NAME="telemt"
readonly USERNAME="main"
readonly CONFIG_DIR="/etc/telemt"
readonly CONFIG_FILE="${CONFIG_DIR}/telemt.toml"
readonly DATA_DIR="/var/lib/telemt"
readonly TLS_FRONT_DIR="${DATA_DIR}/tlsfront"
readonly WORK_DIR="/opt/telemt"
readonly BINARY_PATH="/usr/local/bin/telemt"
readonly SERVICE_FILE="/etc/systemd/system/telemt.service"
readonly STATE_FILE="${CONFIG_DIR}/direct-faketls.state"
readonly LINK_FILE="/root/mtproto-proxy-link.txt"
readonly LOG_FILE="/var/log/telemt-direct-faketls-install.log"
readonly BACKUP_ROOT="/var/backups/telemt-direct-faketls"
readonly STARTUP_TIMEOUT_SECONDS=120
readonly -a ALLOWED_SNI=("vk.com" "yandex.ru" "ozon.ru" "mail.ru" "max.ru" "sber.ru")

PORT="${PORT:-443}"
SNI="${SNI:-vk.com}"
SERVER_HOST="${SERVER_HOST:-}"
ROTATE_SECRET="${ROTATE_SECRET:-0}"

SECRET=""
BACKUP_DIR=""
MUTATION_STARTED=0
COMMITTED=0
HAD_OLD_BINARY=0
HAD_OLD_CONFIG=0
HAD_OLD_SERVICE=0

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

info() { printf '\033[1;36m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; return 1; }

restore_previous_installation() {
  (( MUTATION_STARTED == 1 && COMMITTED == 0 )) || return 0
  warn "Откат: восстанавливаю файлы, которые были до запуска installer."

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

  if (( HAD_OLD_BINARY == 1 )); then
    install -m 0755 "$BACKUP_DIR/telemt.binary" "$BINARY_PATH" || true
  else
    rm -f "$BINARY_PATH" || true
  fi

  if (( HAD_OLD_CONFIG == 1 )); then
    install -D -m 0640 "$BACKUP_DIR/telemt.toml" "$CONFIG_FILE" || true
    chown root:telemt "$CONFIG_FILE" 2>/dev/null || true
  else
    rm -f "$CONFIG_FILE" "$STATE_FILE" || true
  fi

  if (( HAD_OLD_SERVICE == 1 )); then
    install -m 0644 "$BACKUP_DIR/telemt.service" "$SERVICE_FILE" || true
  else
    rm -f "$SERVICE_FILE" || true
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  if (( HAD_OLD_SERVICE == 1 )); then
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  warn "Откат выполнен. Backup сохранён: $BACKUP_DIR"
}

on_error() {
  local exit_code=$?
  local line="${1:-?}"
  local command="${2:-unknown}"
  printf '\033[1;31m[FAIL]\033[0m Ошибка на строке %s: %s\n' "$line" "$command" >&2
  printf 'Журнал установки: %s\n' "$LOG_FILE" >&2
  restore_previous_installation
  exit "$exit_code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "Запустите от root: sudo bash $0"
}

validate_inputs() {
  [[ "$PORT" =~ ^[0-9]+$ ]] || fail "PORT должен быть числом."
  (( PORT >= 1 && PORT <= 65535 )) || fail "PORT должен быть в диапазоне 1..65535."
  [[ "$ROTATE_SECRET" == "0" || "$ROTATE_SECRET" == "1" ]] ||
    fail "ROTATE_SECRET допускает только 0 или 1."

  local item allowed=0
  for item in "${ALLOWED_SNI[@]}"; do
    [[ "$SNI" == "$item" ]] && allowed=1
  done
  (( allowed == 1 )) ||
    fail "Недопустимый SNI: ${SNI}. Разрешены: ${ALLOWED_SNI[*]}"
}

install_dependencies() {
  [[ -r /etc/os-release ]] || fail "Не удалось определить ОС. Требуется Debian/Ubuntu."
  # shellcheck source=/dev/null
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) fail "Поддерживаются Debian/Ubuntu. Обнаружено: ${PRETTY_NAME:-unknown}." ;;
  esac

  info "Устанавливаю зависимости на ${PRETTY_NAME:-$ID}."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl openssl tar gzip iproute2 jq libcap2-bin
  ok "Зависимости установлены."
}

is_ipv4() {
  local ip="$1"
  awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
    }
  ' <<<"$ip"
}

detect_server_host() {
  if [[ -n "$SERVER_HOST" ]]; then
    printf '%s' "$SERVER_HOST"
    return
  fi

  local ip
  ip="$(curl -4fsS --retry 2 --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  ip="${ip//[[:space:]]/}"
  [[ -n "$ip" ]] && is_ipv4 "$ip" ||
    fail "Не удалось определить внешний IPv4. Используйте SERVER_HOST=ВАШ_IP."
  printf '%s' "$ip"
}

backup_existing_installation() {
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  BACKUP_DIR="${BACKUP_ROOT}/${stamp}"
  mkdir -p "$BACKUP_DIR"

  if [[ -x "$BINARY_PATH" ]]; then
    cp -a "$BINARY_PATH" "$BACKUP_DIR/telemt.binary"
    HAD_OLD_BINARY=1
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    cp -a "$CONFIG_FILE" "$BACKUP_DIR/telemt.toml"
    HAD_OLD_CONFIG=1
  fi
  if [[ -f "$SERVICE_FILE" ]]; then
    cp -a "$SERVICE_FILE" "$BACKUP_DIR/telemt.service"
    HAD_OLD_SERVICE=1
  fi

  ok "Backup текущего состояния: $BACKUP_DIR"
}

ensure_port_can_be_reused() {
  local occupied
  occupied="$(ss -H -ltnp "sport = :${PORT}" 2>/dev/null || true)"
  [[ -z "$occupied" ]] && return 0

  if grep -q '"telemt"' <<<"$occupied"; then
    info "Порт ${PORT}/tcp занят текущим telemt; сервис будет безопасно перезапущен."
    return 0
  fi

  printf '%s\n' "$occupied" >&2
  fail "Порт ${PORT}/tcp занят другим процессом. Освободите порт или выберите PORT=..."
}

detect_asset_name() {
  local arch libc
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) fail "Неподдерживаемая архитектура: $(uname -m)" ;;
  esac

  if ldd --version 2>&1 | grep -qi musl; then
    libc="musl"
  else
    libc="gnu"
  fi

  printf 'telemt-%s-linux-%s.tar.gz' "$arch" "$libc"
}

download_pinned_telemt() {
  local asset url temp_dir archive extracted_binary
  asset="$(detect_asset_name)"
  url="https://github.com/telemt/telemt/releases/download/${TELEMT_VERSION}/${asset}"
  temp_dir="$(mktemp -d /tmp/telemt-install.XXXXXX)"
  archive="${temp_dir}/${asset}"

  info "Скачиваю строго закреплённый Telemt ${TELEMT_VERSION}: ${asset}"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
    -o "$archive" "$url"

  tar -xzf "$archive" -C "$temp_dir"
  extracted_binary="$(find "$temp_dir" -type f -name telemt -print -quit)"
  [[ -n "$extracted_binary" ]] || fail "Бинарник telemt отсутствует в официальном архиве."

  install -m 0755 "$extracted_binary" "$BINARY_PATH"
  rm -rf "$temp_dir"

  "$BINARY_PATH" --version 2>/dev/null || true
  ok "Telemt ${TELEMT_VERSION} установлен: $BINARY_PATH"
}

ensure_service_user() {
  if ! getent group telemt >/dev/null 2>&1; then
    groupadd --system telemt
  fi
  if ! id -u telemt >/dev/null 2>&1; then
    useradd --system --gid telemt --home-dir "$WORK_DIR" --create-home \
      --shell /usr/sbin/nologin --comment "Telemt Proxy" telemt
  fi

  mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$TLS_FRONT_DIR" "$WORK_DIR"
  chown root:telemt "$CONFIG_DIR"
  chmod 0750 "$CONFIG_DIR"
  chown -R telemt:telemt "$DATA_DIR" "$WORK_DIR"
  chmod 0750 "$DATA_DIR" "$TLS_FRONT_DIR" "$WORK_DIR"
}

load_or_generate_secret() {
  if [[ "$ROTATE_SECRET" == "0" && -f "$STATE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
    if [[ "${SECRET:-}" =~ ^[0-9a-fA-F]{32}$ ]]; then
      SECRET="${SECRET,,}"
      ok "Сохранён существующий secret пользователя ${USERNAME}."
      return
    fi
  fi

  if [[ "$ROTATE_SECRET" == "0" && -f "$CONFIG_FILE" ]]; then
    SECRET="$(awk -F'"' -v user="$USERNAME" '$1 ~ "^[[:space:]]*" user "[[:space:]]*=" {print $2; exit}' "$CONFIG_FILE" || true)"
    if [[ "$SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
      SECRET="${SECRET,,}"
      ok "Secret извлечён из существующего Direct-конфига."
      return
    fi
  fi

  SECRET="$(openssl rand -hex 16)"
  [[ "$SECRET" =~ ^[0-9a-f]{32}$ ]] || fail "Не удалось сгенерировать корректный secret."
  ok "Создан новый secret пользователя ${USERNAME}."
}

write_direct_config() {
  cat > "$CONFIG_FILE" <<EOF
# Generated by mtproto-telemt-direct-faketls-v${INSTALLER_VERSION}.sh
# Baseline: Telegram client -> VPS -> Telegram DC directly.
# Middle Proxy, sponsor/ad_tag and automatic Cascade are intentionally absent.

[general]
use_middle_proxy = false
fast_mode = true
log_level = "normal"
disable_colors = true

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${SERVER_HOST}"
public_port = ${PORT}

[server]
port = ${PORT}
max_connections = 10000

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
tls_front_dir = "${TLS_FRONT_DIR}"

[access.users]
${USERNAME} = "${SECRET}"
EOF

  chown root:telemt "$CONFIG_FILE"
  chmod 0640 "$CONFIG_FILE"

  cat > "$STATE_FILE" <<EOF
SECRET='${SECRET}'
SNI='${SNI}'
SERVER_HOST='${SERVER_HOST}'
PORT='${PORT}'
TELEMT_VERSION='${TELEMT_VERSION}'
EOF
  chown root:root "$STATE_FILE"
  chmod 0600 "$STATE_FILE"

  ok "Direct-конфиг создан: use_middle_proxy=false, Fake TLS SNI=${SNI}, TCP/${PORT}."
}

write_systemd_unit() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Telemt MTProto Proxy Direct Fake TLS (${SNI})
Documentation=https://github.com/telemt/telemt
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

  chmod 0644 "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
}

allow_ufw_port_when_active() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${PORT}/tcp" >/dev/null
    ok "UFW: открыт входящий TCP/${PORT}."
  else
    info "UFW не активен; локальные правила firewall не изменялись."
  fi
}

start_and_wait_for_listener() {
  local elapsed=0
  systemctl restart "$SERVICE_NAME"

  info "Ожидаю listener TCP/${PORT}; Direct DC probe Telemt может занять больше 30 секунд."
  while (( elapsed < STARTUP_TIMEOUT_SECONDS )); do
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
      journalctl -u "$SERVICE_NAME" -n 120 --no-pager || true
      fail "Сервис telemt завершился до появления listener."
    fi

    if ss -H -ltn "sport = :${PORT}" 2>/dev/null | grep -q ":${PORT}"; then
      ok "Telemt слушает TCP/${PORT} через ${elapsed} сек."
      return
    fi

    sleep 2
    elapsed=$((elapsed + 2))
    if (( elapsed % 10 == 0 )); then
      info "Инициализация Telemt: прошло ${elapsed}/${STARTUP_TIMEOUT_SECONDS} сек..."
    fi
  done

  journalctl -u "$SERVICE_NAME" -n 160 --no-pager || true
  fail "Telemt не открыл TCP/${PORT} за ${STARTUP_TIMEOUT_SECONDS} секунд."
}

probe_runtime_status() {
  local ready_response http_code
  http_code="$(
    curl -sS -o /tmp/telemt-health-ready.json -w '%{http_code}' \
      --connect-timeout 3 --max-time 5 http://127.0.0.1:9091/v1/health/ready || true
  )"
  ready_response="$(cat /tmp/telemt-health-ready.json 2>/dev/null || true)"
  rm -f /tmp/telemt-health-ready.json

  if [[ "$http_code" == "200" ]]; then
    ok "Runtime readiness API: HTTP 200."
  else
    warn "Listener поднят, но /v1/health/ready вернул HTTP ${http_code:-n/a}; это требует проверки Telegram-клиентом."
  fi
  [[ -n "$ready_response" ]] && printf 'Runtime response: %s\n' "$ready_response"

  if journalctl -u "$SERVICE_NAME" -n 160 --no-pager 2>/dev/null | grep -q 'No DC connectivity'; then
    warn "Лог Telemt содержит 'No DC connectivity via direct': listener жив, но серверный DC-probe деградирован."
  fi
}

hex_encode() {
  printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}

save_connection_link() {
  local tls_secret link
  tls_secret="ee${SECRET}$(hex_encode "$SNI")"
  link="tg://proxy?server=${SERVER_HOST}&port=${PORT}&secret=${tls_secret}"

  cat > "$LINK_FILE" <<EOF
Telemt ${TELEMT_VERSION} — Direct + Fake TLS
Server: ${SERVER_HOST}
Port: ${PORT}
SNI: ${SNI}
Middle Proxy: disabled
Cascade: not configured
Link:
${link}
EOF
  chmod 0600 "$LINK_FILE"

  printf '\n====================================================================\n'
  printf ' TELEMT DIRECT + FAKE TLS УСТАНОВЛЕН\n'
  printf '====================================================================\n'
  printf 'Telemt:   %s (pinned)\n' "$TELEMT_VERSION"
  printf 'Маршрут:  Telegram client -> VPS -> Telegram DC (Direct)\n'
  printf 'SNI:      %s\n' "$SNI"
  printf 'Порт:     %s/tcp\n' "$PORT"
  printf 'Ссылка:\n%s\n\n' "$link"
  printf 'Сохранено: %s\n' "$LINK_FILE"
  printf 'Логи:     journalctl -u telemt -n 150 --no-pager\n'
  printf 'Конфиг:   %s\n' "$CONFIG_FILE"
  printf 'Backup:   %s\n' "$BACKUP_DIR"
  printf '\nВАЖНО: официальный README Telemt сообщает о блокировке TLS ClientHello\n'
  printf 'Telegram-клиентов по JA3. Поэтому корректный listener/Fake TLS не\n'
  printf 'гарантирует подключение конкретного официального клиента.\n'
  printf '====================================================================\n'
}

main() {
  require_root
  validate_inputs

  info "Installer v${INSTALLER_VERSION}: Telemt ${TELEMT_VERSION}, Direct + Fake TLS, SNI=${SNI}."
  install_dependencies
  SERVER_HOST="$(detect_server_host)"
  ok "Публичный адрес для Telegram-ссылки: ${SERVER_HOST}"

  ensure_port_can_be_reused
  backup_existing_installation
  MUTATION_STARTED=1

  ensure_service_user
  load_or_generate_secret
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  download_pinned_telemt
  write_direct_config
  write_systemd_unit
  allow_ufw_port_when_active
  start_and_wait_for_listener
  probe_runtime_status

  COMMITTED=1
  save_connection_link
}

main "$@"
