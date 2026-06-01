#!/usr/bin/env bash
# MTProto Proxy one-click installer based on seriyps/mtproto_proxy
# Upstream: https://github.com/seriyps/mtproto_proxy
# Installer version: 1.1
#
# Default deployment:
#   - Ubuntu/Debian VPS
#   - Fake TLS only
#   - SNI: vk.com
#   - TCP port: 443
#   - public IPv4 of the server is detected automatically
#   - Docker container built from pinned upstream release 0.8.4
#   - patches upstream 3-second Telegram bootstrap timeout to 60 seconds
#
# Optional non-interactive overrides:
#   PORT=8443 SERVER_IP=203.0.113.10 sudo -E bash ./mtproto-seriyps-faketls-v1.1.sh
#   ROTATE_SECRET=1 sudo -E bash ./mtproto-seriyps-faketls-v1.1.sh

set -Eeuo pipefail
umask 077

readonly INSTALLER_VERSION="1.1"
readonly UPSTREAM_VERSION="0.8.4"
readonly UPSTREAM_REPOSITORY="https://github.com/seriyps/mtproto_proxy"
readonly CORE_SECRET_URL="https://core.telegram.org/getProxySecret"
readonly CORE_CONFIG_URL="https://core.telegram.org/getProxyConfig"
readonly CORE_HTTP_TIMEOUT_MS="60000"
readonly SNI="vk.com"
readonly EMPTY_AD_TAG="8b081275ec12abd306faeb2f13efbdcb"
readonly CONTAINER_NAME="mtproto-proxy-seriyps"
readonly IMAGE_REPOSITORY="local/mtproto-proxy-seriyps"
readonly INSTALL_DIR="/opt/mtproto-proxy-seriyps"
readonly STATE_FILE="/etc/mtproto-proxy-seriyps.conf"
readonly LOG_FILE="/var/log/mtproto-proxy-seriyps-install.log"
readonly LINK_FILE="/root/mtproto-proxy-link.txt"

PORT="${PORT:-443}"
SERVER_IP="${SERVER_IP:-}"
ROTATE_SECRET="${ROTATE_SECRET:-0}"

mkdir -p /var/log
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

info()    { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
success() { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
die()     { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local line="$1"
  local command="$2"
  printf '\033[1;31m[FAIL]\033[0m Ошибка на строке %s при выполнении: %s\n' "$line" "$command" >&2
  printf 'Полный журнал: %s\n' "$LOG_FILE" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запустите скрипт от root: sudo bash $0"
}

validate_port() {
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT должен быть числом: получено '$PORT'."
  (( PORT >= 1 && PORT <= 65535 )) || die "PORT должен быть в диапазоне 1..65535."
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
  ' <<< "$ip"
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
  local -a services=(
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "http://ipv4.seriyps.com/"
  )

  if [[ -n "$SERVER_IP" ]]; then
    is_ipv4 "$SERVER_IP" || die "SERVER_IP не является корректным IPv4-адресом: '$SERVER_IP'."
    printf '%s' "$SERVER_IP"
    return 0
  fi

  for url in "${services[@]}"; do
    ip="$(curl -4fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$ip" ]] && is_ipv4 "$ip" && ! is_private_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done

  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if [[ -n "$ip" ]] && is_ipv4 "$ip" && ! is_private_ipv4 "$ip"; then
    printf '%s' "$ip"
    return 0
  fi

  die "Не удалось определить публичный IPv4 VPS. Запустите повторно так: SERVER_IP=ВАШ_IP sudo -E bash $0"
}

check_telegram_bootstrap_access() {
  local tmp_dir secret_file config_file secret_size
  tmp_dir="$(mktemp -d)"
  secret_file="$tmp_dir/proxy-secret"
  config_file="$tmp_dir/proxy-multi.conf"

  info "Проверка доступа VPS к Telegram bootstrap API (до 60 секунд на запрос)..."
  if ! curl -4fsSL --retry 2 --retry-all-errors --retry-delay 2 \
       --connect-timeout 15 --max-time 60 -o "$secret_file" "$CORE_SECRET_URL"; then
    rm -rf "$tmp_dir"
    die "VPS не может загрузить getProxySecret с core.telegram.org. Этот upstream не запустится без доступа к Telegram bootstrap API."
  fi
  if ! curl -4fsSL --retry 2 --retry-all-errors --retry-delay 2 \
       --connect-timeout 15 --max-time 60 -o "$config_file" "$CORE_CONFIG_URL"; then
    rm -rf "$tmp_dir"
    die "VPS не может загрузить getProxyConfig с core.telegram.org. Этот upstream не запустится без списка Telegram middle-proxy."
  fi

  secret_size="$(wc -c < "$secret_file" | tr -d ' ')"
  [[ "$secret_size" =~ ^[0-9]+$ ]] && (( secret_size >= 32 )) || {
    rm -rf "$tmp_dir"
    die "Ответ getProxySecret получен, но выглядит некорректно (размер: ${secret_size:-unknown} байт)."
  }
  grep -q '^proxy_for ' "$config_file" || {
    rm -rf "$tmp_dir"
    die "Ответ getProxyConfig получен, но в нём нет записей proxy_for."
  }

  rm -rf "$tmp_dir"
  success "Telegram bootstrap API доступен с VPS."
}

install_dependencies() {
  if [[ ! -r /etc/os-release ]]; then
    die "Не удалось определить ОС. Поддерживаются Debian и Ubuntu."
  fi

  # shellcheck source=/dev/null
  source /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "Поддерживаются Debian/Ubuntu. Обнаружено: ${PRETTY_NAME:-unknown}." ;;
  esac

  info "Установка зависимостей и Docker на ${PRETTY_NAME:-$ID}..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends ca-certificates curl openssl tar docker.io iproute2

  systemctl enable --now docker >/dev/null
  docker info >/dev/null 2>&1 || die "Docker установлен, но daemon недоступен."
  success "Docker готов."
}

load_or_create_secrets() {
  BASE_SECRET=""
  SNI_SALT=""
  ERLANG_COOKIE=""

  if [[ -f "$STATE_FILE" && "$ROTATE_SECRET" != "1" ]]; then
    # This file is created root-only by this installer.
    # shellcheck source=/dev/null
    source "$STATE_FILE"
    info "Найдена прежняя установка: сохраняю существующую ссылку/секрет."
  fi

  if [[ ! "${BASE_SECRET:-}" =~ ^[0-9a-f]{32}$ ]]; then
    BASE_SECRET="$(openssl rand -hex 16)"
  fi
  if [[ ! "${SNI_SALT:-}" =~ ^[0-9a-f]{64}$ ]]; then
    SNI_SALT="$(openssl rand -hex 32)"
  fi
  if [[ ! "${ERLANG_COOKIE:-}" =~ ^[A-Za-z0-9_]{8,80}$ ]]; then
    ERLANG_COOKIE="mtp_$(openssl rand -hex 20)"
  fi

  if [[ "$ROTATE_SECRET" == "1" ]]; then
    BASE_SECRET="$(openssl rand -hex 16)"
    SNI_SALT="$(openssl rand -hex 32)"
    ERLANG_COOKIE="mtp_$(openssl rand -hex 20)"
    warn "Секрет обновлён: прежняя Telegram-ссылка перестанет подключаться."
  fi
}

build_client_link() {
  SNI_HEX="$(printf '%s' "$SNI" | od -An -tx1 | tr -d ' \n')"
  DERIVED_SECRET="$(printf '%s%s%s' "$SNI_SALT" "$BASE_SECRET" "$SNI" | sha256sum | cut -c1-32)"
  CLIENT_SECRET="ee${DERIVED_SECRET}${SNI_HEX}"
  TG_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${PORT}&secret=${CLIENT_SECRET}"
}

prepare_source_and_config() {
  local archive="$INSTALL_DIR/mtproto_proxy-${UPSTREAM_VERSION}.tar.gz"
  local unpack_dir="$INSTALL_DIR/source.new"
  local extracted_dir="$INSTALL_DIR/mtproto_proxy-${UPSTREAM_VERSION}"

  mkdir -p "$INSTALL_DIR"
  rm -rf "$unpack_dir" "$extracted_dir"

  info "Загрузка исходников ${UPSTREAM_REPOSITORY}, release ${UPSTREAM_VERSION}..."
  curl -fL --retry 3 --connect-timeout 15 \
    -o "$archive" \
    "https://github.com/seriyps/mtproto_proxy/archive/refs/tags/${UPSTREAM_VERSION}.tar.gz"

  tar -xzf "$archive" -C "$INSTALL_DIR"
  [[ -d "$extracted_dir" ]] || die "Архив upstream распакован в неожиданную директорию."
  mv "$extracted_dir" "$unpack_dir"

  # Upstream 0.8.4 aborts startup if Telegram bootstrap does not answer in 3000 ms.
  # Keep the release pinned, applying one auditable compatibility patch only.
  if ! grep -q '{timeout, 3000}' "$unpack_dir/src/mtp_config.erl"; then
    die "Не найден ожидаемый upstream timeout-паттерн; сборка остановлена, чтобы не применять небезопасную правку."
  fi
  sed -i "s/{timeout, 3000}/{timeout, ${CORE_HTTP_TIMEOUT_MS}}/" "$unpack_dir/src/mtp_config.erl"
  grep -q "{timeout, ${CORE_HTTP_TIMEOUT_MS}}" "$unpack_dir/src/mtp_config.erl" || \
    die "Не удалось применить патч Telegram bootstrap timeout."
  success "Применён совместимый патч upstream: Telegram bootstrap timeout ${CORE_HTTP_TIMEOUT_MS} ms."

  cat > "$unpack_dir/config/prod-sys.config" <<EOF
%% Generated by mtproto-seriyps-faketls-v${INSTALLER_VERSION}.sh
[
 {mtproto_proxy,
  [
   {allowed_protocols, [mtp_fake_tls]},
   {per_sni_secrets, on},
   {per_sni_secret_salt, <<"${SNI_SALT}">>},
   {domain_fronting, "${SNI}:443"},
   {domain_fronting_timeout_sec, 10},
   {proxy_secret_url, "${CORE_SECRET_URL}"},
   {proxy_config_url, "${CORE_CONFIG_URL}"},
   {external_ip, "${SERVER_IP}"},
   {reset_close_socket, handshake_error},
   {replay_check_server_error_filter, first},
   {replay_check_session_storage, on},
   {ports,
    [#{name => mtp_fake_tls_vk,
       listen_ip => "0.0.0.0",
       port => ${PORT},
       secret => <<"${BASE_SECRET}">>,
       tag => <<"${EMPTY_AD_TAG}">>}
    ]}
  ]},
 {kernel,
  [{logger_level, info},
   {logger,
    [{handler, default, logger_std_h,
      #{level => info,
        config => #{type => file,
                    file => "/var/log/mtproto-proxy/application.log",
                    max_no_bytes => 104857600,
                    max_no_files => 10,
                    filesync_repeat_interval => no_repeat}}},
     {handler, console, logger_std_h,
      #{level => critical,
        config => #{type => standard_io}}}
    ]}]},
 {sasl, [{errlog_type, error}]}
].
EOF

  cat > "$unpack_dir/config/prod-vm.args" <<EOF
-name mtproto_proxy@127.0.0.1
-setcookie ${ERLANG_COOKIE}
+K true
+A 2
+SDio 2
EOF

  SOURCE_DIR="$unpack_dir"
  success "Конфигурация создана: Fake TLS only, SNI=${SNI}, port=${PORT}."
}

build_image() {
  local fingerprint
  fingerprint="$(printf '%s|%s|%s|%s|%s' "$UPSTREAM_VERSION" "$PORT" "$SERVER_IP" "$BASE_SECRET" "$SNI_SALT" | sha256sum | cut -c1-12)"
  IMAGE="${IMAGE_REPOSITORY}:${UPSTREAM_VERSION}-${fingerprint}"

  info "Сборка Docker-образа из официальных исходников ${UPSTREAM_VERSION}..."
  docker build --pull --tag "$IMAGE" "$SOURCE_DIR"

  rm -rf "$INSTALL_DIR/source"
  mv "$SOURCE_DIR" "$INSTALL_DIR/source"
  success "Образ собран: ${IMAGE}."
}

port_is_listening() {
  ss -H -ltn 2>/dev/null | awk -v p=":${PORT}" '$4 ~ (p "$") {found=1} END {exit !found}'
}

running_our_container() {
  docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"
}

restore_previous_container() {
  local backup_name="$1"
  if docker container inspect "$backup_name" >/dev/null 2>&1; then
    warn "Возвращаю предыдущий рабочий контейнер."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rename "$backup_name" "$CONTAINER_NAME" >/dev/null
    docker start "$CONTAINER_NAME" >/dev/null
  fi
}

deploy_container() {
  local backup_name="${CONTAINER_NAME}-rollback"

  if port_is_listening && ! running_our_container; then
    die "TCP-порт ${PORT} уже занят сторонним процессом. Освободите порт или запустите с PORT=другой_порт."
  fi

  docker rm -f "$backup_name" >/dev/null 2>&1 || true
  if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    info "Останавливаю прежний контейнер с возможностью автоматического отката."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rename "$CONTAINER_NAME" "$backup_name" >/dev/null
  fi

  info "Запуск контейнера ${CONTAINER_NAME}..."
  if ! docker run -d \
      --name "$CONTAINER_NAME" \
      --network host \
      --restart unless-stopped \
      --log-opt max-size=20m \
      --log-opt max-file=3 \
      "$IMAGE" >/dev/null; then
    restore_previous_container "$backup_name"
    die "Не удалось запустить новый контейнер."
  fi

  local attempt
  for attempt in {1..90}; do
    if running_our_container && port_is_listening; then
      docker rm -f "$backup_name" >/dev/null 2>&1 || true
      success "Прокси слушает TCP-порт ${PORT}."
      return 0
    fi
    sleep 1
  done

  docker logs --tail 80 "$CONTAINER_NAME" || true
  restore_previous_container "$backup_name"
  die "Контейнер не открыл порт ${PORT}; предыдущая установка восстановлена при её наличии."
}

configure_ufw_if_active() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    info "UFW активен: открываю TCP-порт ${PORT}."
    ufw allow "${PORT}/tcp" >/dev/null
    success "Правило UFW добавлено."
  fi
}

check_middle_proxy_readiness() {
  local attempt logs
  info "Проверка исходящего соединения к Telegram middle-proxy..."
  for attempt in {1..30}; do
    logs="$(docker logs "$CONTAINER_NAME" 2>&1 || true)"
    if grep -q 'handshake complete' <<< "$logs"; then
      success "Соединение с Telegram middle-proxy установлено."
      return 0
    fi
    sleep 1
  done
  warn "Порт открыт, но в журнале пока нет подтверждения handshake с Telegram middle-proxy."
  warn "Если ссылка не подключится в Telegram, проверьте исходящую доступность middle-proxy с этого VPS."
}

check_fake_tls_fronting() {
  info "Проверка маскировки TLS через SNI ${SNI}..."
  if timeout 15 openssl s_client \
       -connect "127.0.0.1:${PORT}" \
       -servername "$SNI" \
       -brief </dev/null 2>&1 | grep -qi 'CONNECTION ESTABLISHED'; then
    success "Fake TLS fronting отвечает как HTTPS ${SNI}."
  else
    warn "Контейнер запущен, но локально не удалось подтвердить fronting к ${SNI}:443."
    warn "Это возможно при исходящей фильтрации HTTPS на VPS; проверьте подключение по ссылке в Telegram."
  fi
}

persist_state_and_link() {
  cat > "$STATE_FILE" <<EOF
# Root-only state generated by mtproto-seriyps-faketls-v${INSTALLER_VERSION}.sh
BASE_SECRET='${BASE_SECRET}'
SNI_SALT='${SNI_SALT}'
ERLANG_COOKIE='${ERLANG_COOKIE}'
EOF
  chmod 600 "$STATE_FILE"

  cat > "$LINK_FILE" <<EOF
MTProto Proxy / seriyps/mtproto_proxy ${UPSTREAM_VERSION}
Server: ${SERVER_IP}
Port: ${PORT}
Fake TLS SNI: ${SNI}
Telegram link:
${TG_LINK}
EOF
  chmod 600 "$LINK_FILE"
}

print_result() {
  cat <<EOF

============================================================
  MTProto Proxy установлен и запущен
============================================================
Проект:        seriyps/mtproto_proxy ${UPSTREAM_VERSION} + bootstrap-timeout patch
IP сервера:    ${SERVER_IP}
Порт:          ${PORT}/tcp
Режим:         Fake TLS only
SNI:           ${SNI}
Автозапуск:    Docker --restart unless-stopped

Ссылка для добавления прокси в Telegram:
${TG_LINK}

Ссылка также сохранена в: ${LINK_FILE}
Журнал установки:          ${LOG_FILE}
Bootstrap API:              core.telegram.org, timeout ${CORE_HTTP_TIMEOUT_MS} ms

Проверить работу:
  docker ps --filter name=${CONTAINER_NAME}
  docker logs --tail 100 ${CONTAINER_NAME}

Перезапустить:
  docker restart ${CONTAINER_NAME}

Важно: убедитесь, что входящий TCP-порт ${PORT} открыт
в firewall/security group вашего VPS-провайдера.
============================================================
EOF
}

main() {
  require_root
  validate_port

  info "MTProto Proxy one-click installer v${INSTALLER_VERSION}"
  info "Параметры по умолчанию: upstream=${UPSTREAM_VERSION}, SNI=${SNI}, port=${PORT}."

  install_dependencies
  SERVER_IP="$(detect_public_ipv4)"
  success "Определён публичный IPv4 сервера: ${SERVER_IP}."
  check_telegram_bootstrap_access

  load_or_create_secrets
  build_client_link
  prepare_source_and_config
  build_image
  configure_ufw_if_active
  deploy_container
  check_middle_proxy_readiness
  check_fake_tls_fronting
  persist_state_and_link
  print_result
}

main "$@"
