#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Teleproxy MTProto Fake-TLS installer
# Project: https://github.com/teleproxy/teleproxy
# Installs pinned Teleproxy v4.14.1 in direct mode with Fake-TLS SNI vk.com.

readonly TELEPROXY_VERSION="4.14.1"
readonly SNI_DOMAIN="vk.com"
readonly DEFAULT_PORT="443"
readonly STATS_PORT="8888"
readonly UPSTREAM_INSTALLER_URL="https://raw.githubusercontent.com/teleproxy/teleproxy/v${TELEPROXY_VERSION}/install.sh"
readonly CONFIG_FILE="/etc/teleproxy/config.toml"
readonly SERVICE_NAME="teleproxy"
readonly BACKUP_ROOT="/root/teleproxy-installer-backups"

PUBLIC_HOST=""
PROXY_PORT="$DEFAULT_PORT"
REPLACE_EXISTING=0
BACKUP_DIR=""
WAS_ACTIVE=0
UPSTREAM_INSTALLER=""

log()  { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Использование:
  sudo ./teleproxy-faketls-vk-install.sh
  sudo ./teleproxy-faketls-vk-install.sh --host proxy.example.com --port 443
  sudo ./teleproxy-faketls-vk-install.sh --replace --host proxy.example.com

Параметры:
  --host HOST     Публичный домен или IPv4 VPS для Telegram-ссылки
  --port PORT     TCP-порт прокси, по умолчанию: ${DEFAULT_PORT}
  --replace       Заменить существующую конфигурацию Teleproxy новым secret
  -h, --help      Показать эту справку

Фиксированные настройки:
  Teleproxy:      v${TELEPROXY_VERSION}
  Fake-TLS SNI:   ${SNI_DOMAIN}
  Режим:          direct-to-DC
EOF
}

cleanup() {
  if [[ -n "$UPSTREAM_INSTALLER" && -f "$UPSTREAM_INSTALLER" ]]; then
    rm -f "$UPSTREAM_INSTALLER"
  fi
  return 0
}
trap cleanup EXIT

on_error() {
  local exit_code=$?
  warn "Установка прервана с ошибкой."
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    warn "Бэкап предыдущей установки сохранён: $BACKUP_DIR"
  fi
  exit "$exit_code"
}
trap on_error ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запустите скрипт через sudo: sudo ./teleproxy-faketls-vk-install.sh"
}

parse_args() {
  while (($#)); do
    case "$1" in
      --host)
        [[ $# -ge 2 ]] || die "После --host требуется значение."
        PUBLIC_HOST="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || die "После --port требуется значение."
        PROXY_PORT="$2"
        shift 2
        ;;
      --replace)
        REPLACE_EXISTING=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Неизвестный параметр: $1"
        ;;
    esac
  done
}

collect_input() {
  if [[ -z "$PUBLIC_HOST" ]]; then
    read -r -p "Публичный домен или IPv4 вашего VPS для ссылки Telegram: " PUBLIC_HOST
  fi

  if [[ "$PROXY_PORT" == "$DEFAULT_PORT" && -t 0 ]]; then
    local entered_port=""
    read -r -p "Порт MTProto Proxy [443]: " entered_port
    PROXY_PORT="${entered_port:-$DEFAULT_PORT}"
  fi
}

validate_input() {
  [[ -n "$PUBLIC_HOST" ]] || die "Домен/IP не может быть пустым."
  [[ "$PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]] ||
    die "Используйте домен или IPv4 без схемы и пути, например proxy.example.com или 203.0.113.10."
  [[ "$PUBLIC_HOST" != *".."* && "$PUBLIC_HOST" != .* && "$PUBLIC_HOST" != *. ]] ||
    die "Некорректный домен/IP: $PUBLIC_HOST"

  [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || die "Порт должен быть числом."
  (( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )) || die "Порт должен быть в диапазоне 1..65535."
  [[ "$PROXY_PORT" != "$STATS_PORT" ]] ||
    die "Порт ${STATS_PORT} зарезервирован для локальной страницы статистики Teleproxy. Выберите другой порт."

  if [[ -f "$CONFIG_FILE" && "$REPLACE_EXISTING" -ne 1 ]]; then
    die "Уже найдена конфигурация $CONFIG_FILE. Чтобы сознательно создать новый secret и заменить её, повторите запуск с --replace."
  fi
}

install_dependencies() {
  command -v apt-get >/dev/null 2>&1 ||
    die "Этот простой установщик рассчитан на Ubuntu/Debian с apt-get."

  info "Устанавливаю системные зависимости..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl openssl ufw iproute2 openssh-client openssh-server >/dev/null
  log "Зависимости установлены."
}

detect_ssh_port() {
  local ssh_port=""

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ssh_port="$(awk '{print $4}' <<<"$SSH_CONNECTION" 2>/dev/null || true)"
  fi

  if [[ -z "$ssh_port" ]] && command -v sshd >/dev/null 2>&1; then
    ssh_port="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)"
  fi

  if [[ ! "$ssh_port" =~ ^[0-9]+$ ]] || (( ssh_port < 1 || ssh_port > 65535 )); then
    ssh_port="22"
    warn "Не удалось точно определить SSH-порт; сохраняю стандартный доступ TCP 22."
  fi

  printf '%s' "$ssh_port"
}

configure_firewall() {
  local ssh_port
  ssh_port="$(detect_ssh_port)"

  info "Настраиваю UFW: SSH TCP ${ssh_port} и MTProto TCP ${PROXY_PORT}..."
  ufw allow "${ssh_port}/tcp" comment "SSH access" >/dev/null
  ufw allow "${PROXY_PORT}/tcp" comment "Teleproxy MTProto Fake TLS" >/dev/null

  if ufw status | grep -q '^Status: active'; then
    log "UFW уже активен; правило TCP ${PROXY_PORT} добавлено."
  else
    ufw --force enable >/dev/null
    log "UFW активирован; SSH TCP ${ssh_port} и proxy TCP ${PROXY_PORT} разрешены."
  fi

  ufw status numbered | grep -Fq "${PROXY_PORT}/tcp" ||
    die "UFW не подтвердил правило для TCP ${PROXY_PORT}."
}

check_port_available() {
  local checked_port
  for checked_port in "$PROXY_PORT" "$STATS_PORT"; do
    if ss -ltnH 2>/dev/null | awk -v port=":${checked_port}" '$4 ~ port "$" {found=1} END {exit !found}'; then
      if systemctl is-active --quiet teleproxy 2>/dev/null; then
        info "Порт ${checked_port} занят текущим teleproxy; служба будет заменена."
      else
        ss -ltnp 2>/dev/null | grep -E "[:.]${checked_port}[[:space:]]" || true
        die "TCP-порт ${checked_port} уже занят другим процессом. Teleproxy использует ${PROXY_PORT} для proxy и ${STATS_PORT} для статистики."
      fi
    fi
  done
}

check_fake_tls_backend() {
  info "Проверяю доступность TLS 1.3 backend для SNI ${SNI_DOMAIN}..."
  if timeout 15 openssl s_client       -connect "${SNI_DOMAIN}:443"       -servername "$SNI_DOMAIN"       -tls1_3 </dev/null 2>/dev/null |
      grep -q "TLSv1.3"; then
    log "${SNI_DOMAIN} доступен с TLS 1.3; Fake-TLS backend пригоден."
  else
    die "С VPS не удалось установить TLS 1.3-соединение с ${SNI_DOMAIN}:443. Fake TLS с этим SNI не сможет работать; проверьте DNS/исходящий доступ VPS."
  fi
}

backup_existing() {
  if [[ -e /etc/teleproxy || -e /usr/local/bin/teleproxy || -e /etc/systemd/system/teleproxy.service ]]; then
    BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    systemctl is-active --quiet teleproxy 2>/dev/null && WAS_ACTIVE=1 || true
    [[ -e /etc/teleproxy ]] && cp -a /etc/teleproxy "$BACKUP_DIR/"
    [[ -e /usr/local/bin/teleproxy ]] && cp -a /usr/local/bin/teleproxy "$BACKUP_DIR/"
    [[ -e /etc/systemd/system/teleproxy.service ]] && cp -a /etc/systemd/system/teleproxy.service "$BACKUP_DIR/"

    log "Предыдущие файлы Teleproxy сохранены: $BACKUP_DIR"
  fi
}

install_teleproxy() {
  UPSTREAM_INSTALLER="$(mktemp)"
  info "Загружаю официальный установщик Teleproxy v${TELEPROXY_VERSION}..."
  curl -fsSL "$UPSTREAM_INSTALLER_URL" -o "$UPSTREAM_INSTALLER"

  grep -q 'EE_DOMAIN' "$UPSTREAM_INSTALLER" &&
    grep -q 'TELEPROXY_VERSION' "$UPSTREAM_INSTALLER" &&
    grep -q 'direct = true' "$UPSTREAM_INSTALLER" ||
    die "Формат официального установщика неожиданно изменился; установка остановлена безопасно."

  # Upstream keeps an old config during upgrades. For --replace we need a
  # newly generated secret plus guaranteed vk.com/port/direct settings.
  if [[ "$REPLACE_EXISTING" -eq 1 && -f "$CONFIG_FILE" ]]; then
    systemctl stop teleproxy 2>/dev/null || true
    rm -f "$CONFIG_FILE"
    warn "Существующая конфигурация заменяется; старые proxy-ссылки перестанут работать."
  fi

  info "Устанавливаю Teleproxy в Direct + Fake-TLS режиме (SNI ${SNI_DOMAIN})..."
  PORT="$PROXY_PORT" \
  STATS_PORT="$STATS_PORT" \
  WORKERS="1" \
  SECRET_COUNT="1" \
  EE_DOMAIN="$SNI_DOMAIN" \
  TELEPROXY_VERSION="$TELEPROXY_VERSION" \
    sh "$UPSTREAM_INSTALLER"

  log "Teleproxy установлен."
}

verify_installation() {
  info "Проверяю службу и listener TCP ${PROXY_PORT}..."
  local attempt
  for attempt in {1..30}; do
    if systemctl is-active --quiet teleproxy &&
       ss -ltnH 2>/dev/null | awk -v port=":${PROXY_PORT}" '$4 ~ port "$" {found=1} END {exit !found}'; then
      log "teleproxy.service активен и слушает TCP ${PROXY_PORT}."
      return 0
    fi
    sleep 1
  done

  systemctl status teleproxy --no-pager || true
  journalctl -u teleproxy -n 80 --no-pager || true
  die "Teleproxy не открыл TCP ${PROXY_PORT}. Выше показаны диагностические логи."
}

print_connection_link() {
  local raw_secret domain_hex client_secret tg_link https_link
  raw_secret="$(awk -F'"' '/^[[:space:]]*key[[:space:]]*=[[:space:]]*"/ {print $2; exit}' "$CONFIG_FILE")"
  [[ "$raw_secret" =~ ^[0-9a-fA-F]{32}$ ]] || die "Не удалось извлечь базовый secret из $CONFIG_FILE."

  domain_hex="$(printf '%s' "$SNI_DOMAIN" | od -An -tx1 | tr -d ' \n')"
  client_secret="ee${raw_secret}${domain_hex}"
  tg_link="tg://proxy?server=${PUBLIC_HOST}&port=${PROXY_PORT}&secret=${client_secret}"
  https_link="https://t.me/proxy?server=${PUBLIC_HOST}&port=${PROXY_PORT}&secret=${client_secret}"

  cat <<EOF

============================================================
 Teleproxy MTProto Proxy готов
============================================================
 Версия:     v${TELEPROXY_VERSION}
 Режим:      Direct-to-DC + Fake-TLS (EE)
 SNI:        ${SNI_DOMAIN}
 Сервер:     ${PUBLIC_HOST}
 Порт:       ${PROXY_PORT}/tcp

 Ссылка для Telegram:
 ${tg_link}

 Альтернативная ссылка:
 ${https_link}

 Проверка:
   systemctl status teleproxy --no-pager
   journalctl -u teleproxy -f
   ufw status verbose

 Конфигурация:
   ${CONFIG_FILE}
============================================================

EOF

  warn "Если у VPS есть внешний Cloud Firewall / Security Group, в панели хостинга также разрешите входящий TCP ${PROXY_PORT}."
  warn "Порт статистики ${STATS_PORT} намеренно не открывается в UFW для публичного доступа."
}

main() {
  parse_args "$@"
  require_root
  collect_input
  validate_input
  install_dependencies
  check_port_available
  check_fake_tls_backend
  backup_existing
  configure_firewall
  install_teleproxy
  verify_installation
  print_connection_link
}

main "$@"
