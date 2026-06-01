#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Standalone installer for Teleproxy MTProto Proxy.
# Does NOT execute the project's install.sh wrapper.
# It downloads the official binary and creates config/systemd service directly.

readonly TELEPROXY_VERSION="4.14.1"
readonly FAKE_TLS_SNI="vk.com"
readonly DEFAULT_PROXY_PORT="443"
readonly LOCAL_MONITORING_PORT="8888"
readonly BINARY_PATH="/usr/local/bin/teleproxy"
readonly CONFIG_DIR="/etc/teleproxy"
readonly CONFIG_FILE="${CONFIG_DIR}/config.toml"
readonly SERVICE_FILE="/etc/systemd/system/teleproxy.service"
readonly SERVICE_USER="teleproxy"
readonly BACKUP_ROOT="/root/teleproxy-backups"

PUBLIC_HOST=""
HOST_MODE=""
PROXY_PORT="$DEFAULT_PROXY_PORT"
REPLACE_EXISTING=0
BACKUP_DIR=""

ok()    { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

usage() {
  cat <<EOF
Teleproxy Fake-TLS installer (standalone, without upstream install.sh)

Использование:
  sudo ./teleproxy-faketls-vk-standalone-v2.sh
  sudo ./teleproxy-faketls-vk-standalone-v2.sh --ip --port 443
  sudo ./teleproxy-faketls-vk-standalone-v2.sh --domain proxy.example.com --port 443
  sudo ./teleproxy-faketls-vk-standalone-v2.sh --replace --ip --port 443

Параметры:
  --ip             Использовать публичный IPv4 VPS в ссылке Telegram
  --domain DOMAIN  Использовать домен в ссылке Telegram
  --host HOST      Указать IPv4 или домен вручную
  --port PORT      TCP-порт proxy, по умолчанию: ${DEFAULT_PROXY_PORT}
  --replace        Заменить существующий Teleproxy config и создать новый secret
  -h, --help       Справка

Настройки proxy:
  Teleproxy:       v${TELEPROXY_VERSION}
  Fake-TLS SNI:    ${FAKE_TLS_SNI}
  Режим:           Direct-to-DC
EOF
}

on_error() {
  local code=$?
  error "Установка не завершена. Код ошибки: ${code}."
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    warn "Бэкап предыдущей установки: ${BACKUP_DIR}"
  fi
  warn "Диагностика: systemctl status teleproxy --no-pager; journalctl -u teleproxy -n 100 --no-pager"
  exit "$code"
}
trap on_error ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запустите скрипт через sudo."
}

parse_args() {
  while (($#)); do
    case "$1" in
      --ip)
        [[ -z "$HOST_MODE" ]] || die "Используйте только один из параметров: --ip, --domain, --host."
        HOST_MODE="ip"
        shift
        ;;
      --domain)
        [[ $# -ge 2 ]] || die "После --domain нужен домен."
        [[ -z "$HOST_MODE" ]] || die "Используйте только один из параметров: --ip, --domain, --host."
        HOST_MODE="domain"
        PUBLIC_HOST="$2"
        shift 2
        ;;
      --host)
        [[ $# -ge 2 ]] || die "После --host нужен IPv4 или домен."
        [[ -z "$HOST_MODE" ]] || die "Используйте только один из параметров: --ip, --domain, --host."
        HOST_MODE="manual"
        PUBLIC_HOST="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || die "После --port нужен номер порта."
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

install_dependencies() {
  command -v apt-get >/dev/null 2>&1 ||
    die "Скрипт рассчитан на Ubuntu/Debian с apt-get."
  info "Устанавливаю зависимости..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl openssl ufw iproute2 openssh-server libc-bin >/dev/null
  ok "Зависимости установлены."
}

is_ipv4() {
  local ip="$1" octet
  local -a octets=()
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
  done
}

detect_public_ipv4() {
  local endpoint value
  for endpoint in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"; do
    value="$(curl -4fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    if is_ipv4 "$value"; then
      printf '%s' "$value"
      return 0
    fi
  done
  return 1
}

collect_connection_address() {
  local choice detected
  if [[ -z "$HOST_MODE" && -t 0 ]]; then
    cat <<EOF

Какой адрес указать в Telegram-ссылке?
  1) Публичный IPv4 VPS — определить автоматически
  2) Домен — например proxy.example.com
EOF
    read -r -p "Выберите вариант [1]: " choice
    choice="${choice:-1}"
    case "$choice" in
      1) HOST_MODE="ip" ;;
      2) HOST_MODE="domain" ;;
      *) die "Выберите 1 или 2." ;;
    esac
  elif [[ -z "$HOST_MODE" ]]; then
    HOST_MODE="ip"
  fi

  case "$HOST_MODE" in
    ip)
      info "Определяю публичный IPv4 VPS..."
      detected="$(detect_public_ipv4 || true)"
      [[ -n "$detected" ]] || die "IPv4 автоматически не определён. Используйте --host ВАШ_IP."
      PUBLIC_HOST="$detected"
      ok "Будет использован IPv4: ${PUBLIC_HOST}"
      ;;
    domain)
      if [[ -z "$PUBLIC_HOST" ]]; then
        read -r -p "Введите домен, направленный на VPS: " PUBLIC_HOST
      fi
      ;;
    manual)
      ;;
    *)
      die "Неверный режим адреса."
      ;;
  esac
}

collect_proxy_port() {
  local entered=""
  if [[ "$PROXY_PORT" == "$DEFAULT_PROXY_PORT" && -t 0 ]]; then
    read -r -p "Порт MTProto Proxy [443]: " entered
    PROXY_PORT="${entered:-$DEFAULT_PROXY_PORT}"
  fi
}

validate_inputs() {
  [[ -n "$PUBLIC_HOST" ]] || die "IPv4/домен не указан."
  if is_ipv4 "$PUBLIC_HOST"; then
    HOST_MODE="ip"
  else
    [[ "$PUBLIC_HOST" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] ||
      die "Некорректный адрес: ${PUBLIC_HOST}. Нужен IPv4 либо домен."
    HOST_MODE="domain"
  fi

  [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || die "Порт должен быть числом."
  ((PROXY_PORT >= 1 && PROXY_PORT <= 65535)) || die "Порт вне диапазона 1..65535."
  [[ "$PROXY_PORT" != "$LOCAL_MONITORING_PORT" ]] ||
    die "Порт ${LOCAL_MONITORING_PORT} используется локальной статистикой; выберите другой порт proxy."

  if [[ -f "$CONFIG_FILE" && "$REPLACE_EXISTING" -ne 1 ]]; then
    die "Найден существующий ${CONFIG_FILE}. Для создания нового secret используйте --replace."
  fi
}

check_dns_for_domain() {
  [[ "$HOST_MODE" == "domain" ]] || return 0
  local resolved external_ip
  resolved="$(getent ahostsv4 "$PUBLIC_HOST" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
  if [[ -z "$resolved" ]]; then
    warn "Домен ${PUBLIC_HOST} не имеет доступной A-записи. До подключения Telegram направьте его на IPv4 VPS."
    return 0
  fi
  ok "Домен ${PUBLIC_HOST} разрешается в ${resolved}."
  external_ip="$(detect_public_ipv4 || true)"
  if [[ -n "$external_ip" && "$resolved" != "$external_ip" ]]; then
    warn "Домен указывает на ${resolved}, а IP этого VPS определяется как ${external_ip}."
    warn "Исправьте DNS A-запись, иначе Telegram подключится не к этому серверу."
  fi
}

check_fake_tls_sni() {
  info "Проверяю TLS 1.3 для Fake-TLS SNI ${FAKE_TLS_SNI}..."
  if timeout 15 openssl s_client \
      -connect "${FAKE_TLS_SNI}:443" \
      -servername "$FAKE_TLS_SNI" \
      -tls1_3 </dev/null 2>/dev/null | grep -q "TLSv1.3"; then
    ok "${FAKE_TLS_SNI} доступен с TLS 1.3."
  else
    die "С VPS не удалось подключиться к ${FAKE_TLS_SNI}:443 через TLS 1.3. Fake TLS не сможет работать."
  fi
}

detect_ssh_port() {
  local value=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    value="$(awk '{print $4}' <<< "$SSH_CONNECTION" 2>/dev/null || true)"
  fi
  if [[ ! "$value" =~ ^[0-9]+$ ]] && command -v sshd >/dev/null 2>&1; then
    value="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)"
  fi
  [[ "$value" =~ ^[0-9]+$ ]] || value="22"
  printf '%s' "$value"
}

configure_ufw() {
  local ssh_port
  ssh_port="$(detect_ssh_port)"
  info "Настраиваю UFW: SSH TCP ${ssh_port}, MTProto TCP ${PROXY_PORT}..."
  ufw allow "${ssh_port}/tcp" comment "SSH access" >/dev/null
  ufw allow "${PROXY_PORT}/tcp" comment "Teleproxy MTProto Fake TLS" >/dev/null
  if ufw status | grep -q '^Status: active'; then
    ok "UFW уже активен; порт TCP ${PROXY_PORT} разрешён."
  else
    ufw --force enable >/dev/null
    ok "UFW активирован; SSH и TCP ${PROXY_PORT} разрешены."
  fi
}

check_ports_available() {
  local port owner
  for port in "$PROXY_PORT" "$LOCAL_MONITORING_PORT"; do
    if ss -ltnH | awk -v suffix=":${port}" '$4 ~ suffix "$" {found=1} END {exit !found}'; then
      owner="$(ss -ltnp 2>/dev/null | awk -v suffix=":${port}" '$4 ~ suffix "$" {print; exit}' || true)"
      if systemctl is-active --quiet teleproxy 2>/dev/null; then
        info "Порт ${port} занят прежним teleproxy; служба будет заменена."
      else
        error "Порт TCP ${port} уже занят: ${owner:-неизвестный процесс}"
        die "Остановите занявший порт сервис либо выберите другой порт."
      fi
    fi
  done
}

backup_existing() {
  if [[ -e "$CONFIG_DIR" || -e "$BINARY_PATH" || -e "$SERVICE_FILE" ]]; then
    BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    [[ -e "$CONFIG_DIR" ]] && cp -a "$CONFIG_DIR" "$BACKUP_DIR/"
    [[ -e "$BINARY_PATH" ]] && cp -a "$BINARY_PATH" "$BACKUP_DIR/"
    [[ -e "$SERVICE_FILE" ]] && cp -a "$SERVICE_FILE" "$BACKUP_DIR/"
    ok "Сохранён бэкап прежних файлов: ${BACKUP_DIR}"
  fi
}

stop_old_teleproxy() {
  if systemctl is-active --quiet teleproxy 2>/dev/null; then
    systemctl stop teleproxy
    ok "Предыдущая служба teleproxy остановлена."
  fi
}

install_official_binary() {
  local arch suffix download_url temporary_binary
  arch="$(uname -m)"
  case "$arch" in
    x86_64) suffix="amd64" ;;
    aarch64|arm64) suffix="arm64" ;;
    *) die "Архитектура ${arch} не поддерживается этим installer (нужна amd64 или arm64)." ;;
  esac

  download_url="https://github.com/teleproxy/teleproxy/releases/download/v${TELEPROXY_VERSION}/teleproxy-linux-${suffix}"
  temporary_binary="$(mktemp)"
  info "Скачиваю официальный бинарник Teleproxy v${TELEPROXY_VERSION} (${suffix})..."
  curl -fL --retry 3 --connect-timeout 15 --max-time 180 "$download_url" -o "$temporary_binary"
  chmod 0755 "$temporary_binary"
  install -m 0755 "$temporary_binary" "$BINARY_PATH"
  rm -f "$temporary_binary"
  [[ -x "$BINARY_PATH" ]] || die "Бинарник не установлен."
  ok "Установлен ${BINARY_PATH}."
}

ensure_service_user() {
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    ok "Создан системный пользователь ${SERVICE_USER}."
  fi
}

write_config() {
  local raw_secret
  raw_secret="$(openssl rand -hex 16)"
  [[ "$raw_secret" =~ ^[0-9a-f]{32}$ ]] || die "Не удалось создать secret."

  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<EOF
# Teleproxy configuration generated by standalone installer
port = ${PROXY_PORT}
stats_port = ${LOCAL_MONITORING_PORT}
http_stats = true
user = "${SERVICE_USER}"
direct = true
workers = 1
domain = "${FAKE_TLS_SNI}"

[[secret]]
key = "${raw_secret}"
label = "primary"
EOF
  chown root:"$SERVICE_USER" "$CONFIG_FILE"
  chmod 0640 "$CONFIG_FILE"
  ok "Создан конфиг ${CONFIG_FILE}."
}

write_systemd_service() {
  cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Teleproxy MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=teleproxy
ExecStart=/usr/local/bin/teleproxy --config /etc/teleproxy/config.toml
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/teleproxy

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable teleproxy >/dev/null
  ok "Создана systemd-служба teleproxy."
}

start_and_verify() {
  info "Запускаю Teleproxy и проверяю TCP ${PROXY_PORT}..."
  systemctl restart teleproxy

  local attempt
  for attempt in {1..30}; do
    if systemctl is-active --quiet teleproxy &&
       ss -ltnH | awk -v suffix=":${PROXY_PORT}" '$4 ~ suffix "$" {found=1} END {exit !found}'; then
      ok "Teleproxy запущен и слушает TCP ${PROXY_PORT}."
      return 0
    fi
    sleep 1
  done

  systemctl status teleproxy --no-pager || true
  journalctl -u teleproxy -n 100 --no-pager || true
  die "Teleproxy не открыл порт ${PROXY_PORT}."
}

print_links() {
  local raw_secret domain_hex client_secret
  raw_secret="$(awk -F'"' '/^[[:space:]]*key[[:space:]]*=/ {print $2; exit}' "$CONFIG_FILE")"
  [[ "$raw_secret" =~ ^[0-9a-fA-F]{32}$ ]] || die "Secret не найден в конфигурации."
  domain_hex="$(printf '%s' "$FAKE_TLS_SNI" | od -An -tx1 | tr -d ' \n')"
  client_secret="ee${raw_secret}${domain_hex}"

  cat <<EOF

============================================================
 Teleproxy MTProto Fake-TLS proxy готов
============================================================
 Версия:     v${TELEPROXY_VERSION}
 Режим:      Direct-to-DC + Fake-TLS
 SNI:        ${FAKE_TLS_SNI}
 Адрес:      ${PUBLIC_HOST}
 Порт:       ${PROXY_PORT}/tcp

 tg://proxy?server=${PUBLIC_HOST}&port=${PROXY_PORT}&secret=${client_secret}

 https://t.me/proxy?server=${PUBLIC_HOST}&port=${PROXY_PORT}&secret=${client_secret}

 Проверка:
   systemctl status teleproxy --no-pager
   journalctl -u teleproxy -n 100 --no-pager
   ufw status verbose
   ss -ltnp | grep ':${PROXY_PORT}'
============================================================
EOF
  warn "Если у провайдера VPS включён Cloud Firewall, разрешите там входящий TCP ${PROXY_PORT}."
  warn "Порт статистики ${LOCAL_MONITORING_PORT} не открыт через UFW."
}

main() {
  parse_args "$@"
  require_root
  install_dependencies
  collect_connection_address
  collect_proxy_port
  validate_inputs
  check_dns_for_domain
  check_fake_tls_sni
  configure_ufw
  check_ports_available
  backup_existing
  stop_old_teleproxy
  install_official_binary
  ensure_service_user
  write_config
  write_systemd_service
  start_and_verify
  print_links
}

main "$@"
