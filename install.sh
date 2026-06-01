#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly TELEMT_VERSION="3.4.13"
readonly SNI_DOMAIN="vk.com"
readonly DEFAULT_PORT="443"
readonly BIN_PATH="/usr/local/bin/telemt"
readonly CONFIG_DIR="/etc/telemt"
readonly CONFIG_FILE="${CONFIG_DIR}/telemt.toml"
readonly WORK_DIR="/opt/telemt"
readonly SERVICE_FILE="/etc/systemd/system/telemt.service"
readonly SERVICE_NAME="telemt"

PUBLIC_HOST=""
SERVER_PORT="${DEFAULT_PORT}"
PORT_PROVIDED=0

log() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local line="$1"
  warn "Установка остановлена на строке ${line}."
  if command -v systemctl >/dev/null 2>&1 && systemctl cat "${SERVICE_NAME}" >/dev/null 2>&1; then
    warn "Последние логи: journalctl -u ${SERVICE_NAME} -n 80 --no-pager"
  fi
}
trap 'on_error "$LINENO"' ERR

usage() {
  cat <<EOF
Установка Telemt ${TELEMT_VERSION}: Direct MTProto + Fake TLS, SNI ${SNI_DOMAIN}.

Использование:
  sudo bash $0
  sudo bash $0 --host proxy.example.com --port 443

Опции:
  --host HOST   Публичный домен или IPv4 VPS для Telegram-ссылки.
  --port PORT   TCP-порт proxy, по умолчанию ${DEFAULT_PORT}.
  -h, --help    Показать помощь.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || die "После --host требуется домен или IPv4."
      PUBLIC_HOST="$2"; shift 2 ;;
    --port)
      [[ $# -ge 2 ]] || die "После --port требуется число."
      SERVER_PORT="$2"; PORT_PROVIDED=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "Запустите скрипт от root: sudo bash $0"
[[ -d /run/systemd/system ]] || die "Этот простой скрипт рассчитан на Ubuntu/Debian с systemd."

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) warn "Система ${PRETTY_NAME:-unknown} не проверена; скрипт ориентирован на Ubuntu/Debian." ;;
  esac
fi

validate_host() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$1" != -* ]] && [[ "$1" != *..* ]]
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

while [[ -z "${PUBLIC_HOST}" ]]; do
  read -r -p "Публичный домен или IPv4 вашего VPS для ссылки Telegram: " PUBLIC_HOST </dev/tty
  [[ -n "${PUBLIC_HOST}" ]] || warn "Значение не может быть пустым."
done
validate_host "${PUBLIC_HOST}" || die "HOST должен быть доменом или IPv4 без http://, пути и пробелов."

if (( PORT_PROVIDED == 0 )); then
  read -r -p "Порт Telemt [${DEFAULT_PORT}]: " INPUT_PORT </dev/tty || true
  [[ -z "${INPUT_PORT:-}" ]] || SERVER_PORT="${INPUT_PORT}"
fi
validate_port "${SERVER_PORT}" || die "Порт должен быть числом от 1 до 65535."

printf '\nПараметры установки:\n'
printf '  Telemt:      %s\n' "${TELEMT_VERSION}"
printf '  Public host: %s\n' "${PUBLIC_HOST}"
printf '  Port:        %s\n' "${SERVER_PORT}"
printf '  Mode:        Direct + Fake TLS only\n'
printf '  SNI:         %s (фиксирован)\n\n' "${SNI_DOMAIN}"

log "Установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl openssl jq tar gzip iproute2 libcap2-bin >/dev/null

case "$(uname -m)" in
  x86_64)
    ARCHIVE="telemt-x86_64-linux-gnu.tar.gz"
    ARCHIVE_SHA256="48a92a07ae0e10a756222131416b604532500e0f2ab4d06bc7a898fe5f4c4cd3"
    ;;
  aarch64|arm64)
    ARCHIVE="telemt-aarch64-linux-gnu.tar.gz"
    ARCHIVE_SHA256="7c0e8c15242c5d960eefe36b930063b0c454f19e50f5fe5b9b48f947912a456a"
    ;;
  *) die "Архитектура $(uname -m) не поддержана этим скриптом (нужна x86_64 или aarch64)." ;;
esac

BACKUP_DIR="/var/backups/telemt-simple/$(date +%Y%m%d-%H%M%S)"
if [[ -e "${CONFIG_FILE}" || -e "${SERVICE_FILE}" || -e "${BIN_PATH}" ]]; then
  log "Создание резервной копии существующей установки: ${BACKUP_DIR}"
  mkdir -p "${BACKUP_DIR}"
  [[ -e "${CONFIG_FILE}" ]] && cp -a "${CONFIG_FILE}" "${BACKUP_DIR}/telemt.toml" || true
  [[ -e "${SERVICE_FILE}" ]] && cp -a "${SERVICE_FILE}" "${BACKUP_DIR}/telemt.service" || true
  [[ -e "${BIN_PATH}" ]] && cp -a "${BIN_PATH}" "${BACKUP_DIR}/telemt" || true
fi

systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
if ss -H -ltn | awk -v suffix=":${SERVER_PORT}" '$4 ~ (suffix "$" ) { found=1 } END { exit !found }'; then
  die "TCP-порт ${SERVER_PORT} уже занят другим сервисом. Освободите порт и запустите скрипт снова."
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
DOWNLOAD_URL="https://github.com/telemt/telemt/releases/download/${TELEMT_VERSION}/${ARCHIVE}"
log "Загрузка Telemt ${TELEMT_VERSION} (${ARCHIVE})..."
curl --fail --location --retry 3 --connect-timeout 15 --output "${TMP_DIR}/${ARCHIVE}" "${DOWNLOAD_URL}"
printf '%s  %s\n' "${ARCHIVE_SHA256}" "${TMP_DIR}/${ARCHIVE}" | sha256sum --check --status \
  || die "SHA-256 архива Telemt не совпал. Установка прервана."
ok "SHA-256 архива проверен."

tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "${TMP_DIR}"
EXTRACTED_BIN="$(find "${TMP_DIR}" -type f -name telemt -perm -u+x -print -quit)"
[[ -n "${EXTRACTED_BIN}" ]] || die "В архиве не найден исполняемый файл telemt."

log "Создание системного пользователя и директорий..."
getent group telemt >/dev/null || groupadd --system telemt
id -u telemt >/dev/null 2>&1 || useradd --system --gid telemt --home-dir "${WORK_DIR}" --shell /usr/sbin/nologin --comment "Telemt Proxy" telemt
mkdir -p "${CONFIG_DIR}" "${WORK_DIR}/tlsfront"
chown root:telemt "${CONFIG_DIR}"
chmod 750 "${CONFIG_DIR}"
chown -R telemt:telemt "${WORK_DIR}"
chmod 750 "${WORK_DIR}" "${WORK_DIR}/tlsfront"
install -m 0755 "${EXTRACTED_BIN}" "${BIN_PATH}"

USER_SECRET="$(openssl rand -hex 16)"
[[ "${#USER_SECRET}" -eq 32 ]] || die "Не удалось сгенерировать пользовательский secret."

log "Создание Direct-конфига Fake TLS с SNI ${SNI_DOMAIN}..."
cat > "${CONFIG_FILE}" <<EOF
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
public_port = ${SERVER_PORT}

[server]
port = ${SERVER_PORT}

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${SNI_DOMAIN}"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
default = "${USER_SECRET}"
EOF
chown root:telemt "${CONFIG_FILE}"
chmod 640 "${CONFIG_FILE}"

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Telemt MTProto Proxy (Direct + Fake TLS ${SNI_DOMAIN})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=${WORK_DIR}
ExecStart=${BIN_PATH} ${CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "${SERVICE_FILE}"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  log "UFW активен: открываю ${SERVER_PORT}/tcp..."
  ufw allow "${SERVER_PORT}/tcp" comment 'Telemt MTProto' >/dev/null
else
  warn "UFW не активен. Убедитесь, что порт ${SERVER_PORT}/tcp открыт в firewall VPS/облачной панели."
fi

log "Запуск telemt. Первичная Fake TLS/Direct инициализация может занять до 90 секунд..."
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}" >/dev/null

LINK=""
for (( attempt=1; attempt<=90; attempt++ )); do
  if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    journalctl -u "${SERVICE_NAME}" -n 80 --no-pager >&2 || true
    die "Сервис telemt остановился при запуске."
  fi
  if ss -H -ltn | awk -v suffix=":${SERVER_PORT}" '$4 ~ (suffix "$" ) { found=1 } END { exit !found }'; then
    LINK="$(curl -fsS --max-time 2 http://127.0.0.1:9091/v1/users 2>/dev/null \
      | jq -r '.data[]? | select(.username == "default") | .links.tls[0] // empty' \
      | head -n 1 || true)"
    [[ -n "${LINK}" ]] && break
  fi
  sleep 1
done

if [[ -z "${LINK}" ]]; then
  journalctl -u "${SERVICE_NAME}" -n 80 --no-pager >&2 || true
  die "Telemt не выдал Fake TLS-ссылку за 90 секунд. Проверьте логи выше."
fi

ok "Telemt ${TELEMT_VERSION} установлен и запущен."
printf '\n============================================================\n'
printf ' Telegram MTProto Proxy: Direct + Fake TLS\n'
printf '============================================================\n'
printf ' SNI:    %s\n' "${SNI_DOMAIN}"
printf ' Host:   %s\n' "${PUBLIC_HOST}"
printf ' Port:   %s\n\n' "${SERVER_PORT}"
printf ' Ссылка для подключения:\n%s\n\n' "${LINK}"
printf ' Проверка статуса:\n  systemctl status telemt --no-pager\n'
printf ' Логи:\n  journalctl -u telemt -f\n'
printf ' Конфиг:\n  %s\n' "${CONFIG_FILE}"
printf '============================================================\n'
