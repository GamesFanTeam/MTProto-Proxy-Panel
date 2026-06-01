#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Simple installer for 9seconds/mtg v2 with Fake TLS SNI vk.com.
# Target OS: Debian/Ubuntu with systemd.

readonly MTG_VERSION="${MTG_VERSION:-2.2.8}"
readonly FAKE_TLS_SNI="vk.com"
readonly SERVICE_NAME="mtg.service"
readonly CONFIG_DIR="/etc/mtg"
readonly CONFIG_FILE="${CONFIG_DIR}/config.toml"
readonly ACCESS_FILE="/root/mtg-access.txt"
readonly BINARY_PATH="/usr/local/bin/mtg"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

TMP_DIR=""
BACKUP_DIR=""
PREVIOUS_SERVICE_ACTIVE="false"
INSTALL_SUCCESS="false"
BINARY_EXISTED="false"
CONFIG_EXISTED="false"
SERVICE_FILE_EXISTED="false"
ACCESS_FILE_EXISTED="false"

log() {
  printf '\033[1;32m[+]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  return 1
}

cleanup() {
  [[ -z "${TMP_DIR}" ]] || rm -rf -- "${TMP_DIR}"
}

backup_file() {
  local source_path="$1"
  [[ -e "${source_path}" ]] || return 0
  install -d -m 0700 "${BACKUP_DIR}$(dirname "${source_path}")"
  cp -a -- "${source_path}" "${BACKUP_DIR}${source_path}"
}

restore_file() {
  local source_path="$1"
  [[ -e "${BACKUP_DIR}${source_path}" ]] || return 0
  install -d "$(dirname "${source_path}")"
  cp -a -- "${BACKUP_DIR}${source_path}" "${source_path}"
}

rollback_on_error() {
  local exit_code=$?
  trap - ERR

  warn "Установка прервана. Возвращаю предыдущие файлы, если они существовали."
  if [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]]; then
    if [[ "${BINARY_EXISTED}" == "true" ]]; then restore_file "${BINARY_PATH}" || true; else rm -f -- "${BINARY_PATH}"; fi
    if [[ "${CONFIG_EXISTED}" == "true" ]]; then restore_file "${CONFIG_FILE}" || true; else rm -f -- "${CONFIG_FILE}"; fi
    if [[ "${SERVICE_FILE_EXISTED}" == "true" ]]; then restore_file "${SERVICE_FILE}" || true; else rm -f -- "${SERVICE_FILE}"; fi
    if [[ "${ACCESS_FILE_EXISTED}" == "true" ]]; then restore_file "${ACCESS_FILE}" || true; else rm -f -- "${ACCESS_FILE}"; fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ "${PREVIOUS_SERVICE_ACTIVE}" == "true" ]]; then
      systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || true
    elif [[ "${INSTALL_SUCCESS}" != "true" ]]; then
      systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
  fi

  cleanup
  exit "${exit_code}"
}

trap rollback_on_error ERR
trap cleanup EXIT

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root: sudo bash $0"
}

validate_version() {
  [[ "${MTG_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "Некорректная версия MTG_VERSION='${MTG_VERSION}'. Ожидается формат X.Y.Z."
}

validate_port() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]+$ ]] || die "Порт должен быть числом."
  (( port >= 1 && port <= 65535 )) || die "Порт должен быть в диапазоне 1..65535."
}

validate_public_host() {
  local host="$1"
  [[ -n "${host}" ]] || die "Не удалось определить внешний IP. Укажи домен или IP вручную."
  [[ "${host}" != *"://"* && "${host}" != */* && "${host}" != *"?"* && "${host}" != *"#"* && "${host}" != *"&"* && "${host}" != *" "* ]] || \
    die "Укажи только домен или IP, без http://, пути и параметров."
  [[ "${host}" =~ ^[A-Za-z0-9._:-]+$ ]] || \
    die "Адрес содержит неподдерживаемые символы. Используй ASCII-домен, IPv4 или IPv6."
}

is_ipv4() {
  local ip="$1" octet
  local -a octets
  IFS='.' read -r -a octets <<< "${ip}"
  [[ "${#octets[@]}" -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#${octet} <= 255 )) || return 1
  done
}

detect_public_ipv4() {
  local service detected_ip
  for service in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"; do
    detected_ip="$(curl -4fsS --max-time 7 "${service}" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "${detected_ip}"; then
      printf '%s' "${detected_ip}"
      return 0
    fi
  done
  return 1
}

urlencode() {
  local LC_ALL=C input="$1" char encoded="" i
  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    case "${char}" in
      [a-zA-Z0-9.~_-]) encoded+="${char}" ;;
      *) printf -v char '%%%02X' "'${char}"; encoded+="${char}" ;;
    esac
  done
  printf '%s' "${encoded}"
}

install_dependencies() {
  [[ -f /etc/debian_version ]] || die "Этот installer рассчитан на Debian/Ubuntu с systemd."
  command -v systemctl >/dev/null 2>&1 || die "systemd не найден."

  log "Устанавливаю необходимые пакеты"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ca-certificates curl tar coreutils iproute2 >/dev/null
}

select_download_asset() {
  local machine
  machine="$(uname -m)"
  case "${machine}" in
    x86_64|amd64) printf 'mtg-%s-linux-amd64.tar.gz' "${MTG_VERSION}" ;;
    aarch64|arm64) printf 'mtg-%s-linux-arm64.tar.gz' "${MTG_VERSION}" ;;
    armv7l|armv7) printf 'mtg-%s-linux-armv7.tar.gz' "${MTG_VERSION}" ;;
    armv6l|armv6) printf 'mtg-%s-linux-armv6.tar.gz' "${MTG_VERSION}" ;;
    i386|i686) printf 'mtg-%s-linux-386.tar.gz' "${MTG_VERSION}" ;;
    mips) printf 'mtg-%s-linux-mips.tar.gz' "${MTG_VERSION}" ;;
    mipsel|mipsle) printf 'mtg-%s-linux-mipsle.tar.gz' "${MTG_VERSION}" ;;
    *) die "Архитектура '${machine}' не поддерживается этим installer." ;;
  esac
}

port_is_busy() {
  local port="$1"
  ss -H -ltn 2>/dev/null | awk -v suffix=":${port}" '$4 ~ suffix "$" { found=1 } END { exit !found }'
}

prepare_backup() {
  [[ -e "${BINARY_PATH}" ]] && BINARY_EXISTED="true"
  [[ -e "${CONFIG_FILE}" ]] && CONFIG_EXISTED="true"
  [[ -e "${SERVICE_FILE}" ]] && SERVICE_FILE_EXISTED="true"
  [[ -e "${ACCESS_FILE}" ]] && ACCESS_FILE_EXISTED="true"

  BACKUP_DIR="/var/backups/mtg-installer/$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "${BACKUP_DIR}"
  backup_file "${BINARY_PATH}"
  backup_file "${CONFIG_FILE}"
  backup_file "${SERVICE_FILE}"
  backup_file "${ACCESS_FILE}"
}

download_and_install_mtg() {
  local asset base_url expected_line extracted_binary
  asset="$(select_download_asset)"
  base_url="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}"

  TMP_DIR="$(mktemp -d)"
  log "Скачиваю mtg v${MTG_VERSION} (${asset})"
  curl -fL --retry 3 --connect-timeout 10 --proto '=https' --tlsv1.2 \
    -o "${TMP_DIR}/${asset}" "${base_url}/${asset}"
  curl -fL --retry 3 --connect-timeout 10 --proto '=https' --tlsv1.2 \
    -o "${TMP_DIR}/checksums.txt" "${base_url}/mtg-${MTG_VERSION}-checksums.txt"

  expected_line="$(grep -E "^[0-9a-f]{64}  ${asset}$" "${TMP_DIR}/checksums.txt" || true)"
  [[ -n "${expected_line}" ]] || die "В checksum-файле релиза не найден архив ${asset}."
  printf '%s\n' "${expected_line}" > "${TMP_DIR}/selected.sha256"
  (cd "${TMP_DIR}" && sha256sum -c selected.sha256 --status) || die "SHA256-проверка архива mtg не пройдена."

  install -d "${TMP_DIR}/unpack"
  tar -xzf "${TMP_DIR}/${asset}" -C "${TMP_DIR}/unpack"
  extracted_binary="$(find "${TMP_DIR}/unpack" -type f -name mtg -print -quit)"
  [[ -n "${extracted_binary}" ]] || die "Бинарный файл mtg не найден внутри архива."
  install -o root -g root -m 0755 "${extracted_binary}" "${BINARY_PATH}"
  log "Установлен $(${BINARY_PATH} --version 2>/dev/null || printf 'mtg v%s' "${MTG_VERSION}")"
}

create_service_user() {
  getent group mtg >/dev/null 2>&1 || groupadd --system mtg
  id -u mtg >/dev/null 2>&1 || useradd --system --gid mtg --home-dir /var/lib/mtg --shell /usr/sbin/nologin mtg
  install -d -o root -g mtg -m 0750 "${CONFIG_DIR}"
  install -d -o mtg -g mtg -m 0750 /var/lib/mtg
}

write_configuration() {
  local port="$1" secret="$2"
  local temporary_config="${TMP_DIR}/config.toml"

  cat > "${temporary_config}" <<EOF
# Generated by install-mtg-faketls-vk.sh
# Fake TLS SNI is encoded into the secret below: ${FAKE_TLS_SNI}
secret = "${secret}"
bind-to = "0.0.0.0:${port}"
EOF
  install -o root -g mtg -m 0640 "${temporary_config}" "${CONFIG_FILE}"
}

write_systemd_service() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=mtg - MTProto Proxy with Fake TLS (${FAKE_TLS_SNI})
Documentation=https://github.com/9seconds/mtg
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=mtg
Group=mtg
WorkingDirectory=/var/lib/mtg
ExecStart=${BINARY_PATH} run ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
StateDirectory=mtg

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${SERVICE_FILE}"
}

open_firewall_if_needed() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${port}/tcp" >/dev/null
    log "Открыт TCP-порт ${port} в UFW"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    log "Открыт TCP-порт ${port} в firewalld"
  fi
}

wait_until_listening() {
  local port="$1" attempt
  for attempt in {1..20}; do
    systemctl is-active --quiet "${SERVICE_NAME}" || {
      journalctl -u "${SERVICE_NAME}" -n 50 --no-pager >&2 || true
      die "Сервис mtg завершился с ошибкой."
    }
    if port_is_busy "${port}"; then
      return 0
    fi
    sleep 1
  done
  journalctl -u "${SERVICE_NAME}" -n 50 --no-pager >&2 || true
  die "mtg запущен, но не открыл TCP-порт ${port}."
}

write_access_file() {
  local endpoint="$1" port="$2" secret="$3" encoded_endpoint tg_url tme_url
  encoded_endpoint="$(urlencode "${endpoint}")"
  tg_url="tg://proxy?server=${encoded_endpoint}&port=${port}&secret=${secret}"
  tme_url="https://t.me/proxy?server=${encoded_endpoint}&port=${port}&secret=${secret}"

  umask 077
  cat > "${ACCESS_FILE}" <<EOF
MTProto Proxy (mtg v${MTG_VERSION})
Endpoint: ${endpoint}:${port}
Fake TLS SNI: ${FAKE_TLS_SNI}
Secret: ${secret}

tg:// link:
${tg_url}

https://t.me link:
${tme_url}
EOF
  chmod 0600 "${ACCESS_FILE}"

  printf '\n\033[1;32mУстановка успешно завершена.\033[0m\n'
  printf 'Адрес:        %s:%s\n' "${endpoint}" "${port}"
  printf 'Fake TLS SNI: %s\n' "${FAKE_TLS_SNI}"
  printf 'Сервис:       systemctl status %s\n' "${SERVICE_NAME}"
  printf 'Логи:         journalctl -u %s -f\n' "${SERVICE_NAME}"
  printf 'Данные доступа сохранены в: %s\n\n' "${ACCESS_FILE}"
  printf 'Ссылка Telegram:\n%s\n\n' "${tme_url}"
}

main() {
  local public_host port_input proxy_port secret

  require_root
  validate_version
  install_dependencies

  printf '\nУстановка MTProto Proxy на базе mtg v%s\n' "${MTG_VERSION}"
  printf 'Fake TLS SNI фиксирован: %s\n\n' "${FAKE_TLS_SNI}"

  if [[ -n "${MTG_PUBLIC_HOST:-}" ]]; then
    public_host="${MTG_PUBLIC_HOST}"
  elif [[ -t 0 ]]; then
    read -r -p 'Домен или IP для ссылки Telegram (Enter = определить IP сервера): ' public_host
  else
    public_host=""
  fi

  if [[ -z "${public_host}" ]]; then
    log "Определяю внешний IPv4 сервера"
    public_host="$(detect_public_ipv4 || true)"
  fi
  validate_public_host "${public_host}"

  if [[ -n "${MTG_PORT:-}" ]]; then
    proxy_port="${MTG_PORT}"
  elif [[ -t 0 ]]; then
    read -r -p 'Порт прокси [443]: ' port_input
    proxy_port="${port_input:-443}"
  else
    proxy_port="443"
  fi
  validate_port "${proxy_port}"

  prepare_backup

  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    PREVIOUS_SERVICE_ACTIVE="true"
    log "Останавливаю ранее установленный сервис mtg перед обновлением"
    systemctl stop "${SERVICE_NAME}"
  fi

  if port_is_busy "${proxy_port}"; then
    die "TCP-порт ${proxy_port} уже занят другим сервисом. Освободи порт или выбери другой."
  fi

  download_and_install_mtg
  create_service_user

  secret="$(${BINARY_PATH} generate-secret --hex "${FAKE_TLS_SNI}")"
  [[ "${secret}" =~ ^ee[0-9a-fA-F]+$ ]] || die "mtg вернул некорректный Fake TLS secret."

  write_configuration "${proxy_port}" "${secret}"
  write_systemd_service
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}" >/dev/null
  wait_until_listening "${proxy_port}"
  open_firewall_if_needed "${proxy_port}"
  write_access_file "${public_host}" "${proxy_port}" "${secret}"

  INSTALL_SUCCESS="true"
  log "Резервная копия предыдущей установки (если была): ${BACKUP_DIR}"
}

main "$@"
