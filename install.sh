#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# telEgo MTProto FakeTLS installer
# Project: https://github.com/Scratch-net/telego
# FakeTLS SNI is intentionally fixed to vk.com.

readonly APP_NAME="telego"
readonly APP_DIR="/opt/telego"
readonly CONFIG_FILE="${APP_DIR}/config.toml"
readonly CONNECTION_FILE="${APP_DIR}/connection.txt"
readonly INSTALL_LOG="/var/log/telego-install.log"
readonly CONTAINER_NAME="telego"
readonly MASK_HOST="vk.com"
readonly PREFERRED_IMAGE="scratchnet/telego:v0.4.0"
readonly FALLBACK_IMAGE="scratchnet/telego:latest"
readonly DEFAULT_PORT="443"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { printf '%b[+]%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[!]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
die() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

on_error() {
    local exit_code=$?
    printf '%b[ERROR]%b Установка прервана на строке %s (код %s).\n' "$RED" "$NC" "${BASH_LINENO[0]:-?}" "$exit_code" >&2
    exit "$exit_code"
}
trap on_error ERR

require_root() {
    [[ ${EUID} -eq 0 ]] || die "Запустите скрипт от root: sudo bash $0"
}

require_supported_os() {
    command -v apt-get >/dev/null 2>&1 || die "Поддерживаются Debian/Ubuntu с apt-get."
}

setup_logging() {
    touch "$INSTALL_LOG"
    chmod 600 "$INSTALL_LOG"
    exec > >(tee -a "$INSTALL_LOG") 2>&1
    log "Лог установки: ${INSTALL_LOG}"
}

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    log "Проверяю необходимые пакеты..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl openssl iproute2 >/dev/null

    if ! command -v docker >/dev/null 2>&1; then
        log "Docker не найден, устанавливаю docker.io..."
        apt-get install -y -qq docker.io >/dev/null
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || die "Не удалось запустить Docker."
    else
        service docker start >/dev/null 2>&1 || die "Не удалось запустить Docker."
    fi
    docker info >/dev/null 2>&1 || die "Docker установлен, но демон недоступен."
}

detect_public_ipv4() {
    local ip=""
    ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$ip" ]] || ip="$(curl -4fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    printf '%s' "$ip"
}

validate_server_address() {
    local value="$1"
    [[ -n "$value" ]] || return 1
    [[ "$value" != *"://"* && "$value" != *"/"* && "$value" != *":"* ]] || return 1
    [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
}

ask_connection_address() {
    local entered=""
    local detected_ip=""
    detected_ip="$(detect_public_ipv4 || true)"

    if [[ -n "$detected_ip" ]]; then
        printf 'Введите домен или внешний IP для подключения [%s]: ' "$detected_ip"
    else
        printf 'Введите домен или внешний IP для подключения: '
    fi
    read -r entered

    SERVER_ADDRESS="${entered:-$detected_ip}"
    [[ -n "$SERVER_ADDRESS" ]] || die "Не удалось определить IP автоматически. Запустите снова и введите домен или внешний IP."
    validate_server_address "$SERVER_ADDRESS" || die "Некорректный домен/IP: ${SERVER_ADDRESS}. Вводите без http:// и без порта."

    if [[ "$SERVER_ADDRESS" != "$detected_ip" && ! "$SERVER_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        if ! getent ahostsv4 "$SERVER_ADDRESS" >/dev/null 2>&1; then
            warn "Домен ${SERVER_ADDRESS} сейчас не резолвится в IPv4. Ссылка будет создана, но подключение заработает только после настройки DNS."
        fi
    fi
}

ask_port() {
    local entered=""
    printf 'Порт MTProto proxy [%s]: ' "$DEFAULT_PORT"
    read -r entered
    PROXY_PORT="${entered:-$DEFAULT_PORT}"
    [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || die "Порт должен быть числом."
    (( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )) || die "Порт должен быть в диапазоне 1..65535."
}

check_existing_installation_and_port() {
    if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        die "Контейнер '${CONTAINER_NAME}' уже существует. Удалите его перед чистой переустановкой: docker rm -f ${CONTAINER_NAME}"
    fi

    if ss -H -ltn "sport = :${PROXY_PORT}" 2>/dev/null | grep -q .; then
        ss -ltnp "sport = :${PROXY_PORT}" >&2 || true
        die "TCP-порт ${PROXY_PORT} уже занят. Выберите другой порт или освободите его."
    fi

    if [[ -e "$CONFIG_FILE" || -e "$CONNECTION_FILE" ]]; then
        local backup_dir="${APP_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$backup_dir"
        [[ -e "$CONFIG_FILE" ]] && cp -a "$CONFIG_FILE" "$backup_dir/"
        [[ -e "$CONNECTION_FILE" ]] && cp -a "$CONNECTION_FILE" "$backup_dir/"
        warn "Найдены старые файлы конфигурации; резервная копия сохранена в ${backup_dir}."
    fi
}

pull_telego_image() {
    log "Загружаю telEgo v0.4.0..."
    if docker pull "$PREFERRED_IMAGE" >/dev/null 2>&1; then
        TELEGO_IMAGE="$PREFERRED_IMAGE"
    else
        warn "Docker-тег v0.4.0 недоступен; использую официальный latest из README проекта."
        docker pull "$FALLBACK_IMAGE" >/dev/null
        TELEGO_IMAGE="$FALLBACK_IMAGE"
    fi
    docker run --rm "$TELEGO_IMAGE" version >/dev/null 2>&1 || die "Образ telEgo не запускается на этой архитектуре сервера."
}

write_configuration() {
    umask 077
    mkdir -p "$APP_DIR"

    SECRET_KEY="$(openssl rand -hex 16)"
    [[ "$SECRET_KEY" =~ ^[0-9a-f]{32}$ ]] || die "Не удалось создать MTProto secret."
    MASK_HOST_HEX="$(printf '%s' "$MASK_HOST" | od -An -tx1 | tr -d ' \n')"
    FAKE_TLS_SECRET="ee${SECRET_KEY}${MASK_HOST_HEX}"
    TG_LINK="tg://proxy?server=${SERVER_ADDRESS}&port=${PROXY_PORT}&secret=${FAKE_TLS_SECRET}"
    HTTPS_LINK="https://t.me/proxy?server=${SERVER_ADDRESS}&port=${PROXY_PORT}&secret=${FAKE_TLS_SECRET}"

    cat > "$CONFIG_FILE" <<EOF
[general]
bind-to = "0.0.0.0:${PROXY_PORT}"
log-level = "info"
max-connections-per-ip = 100
handshake-timeout = "8s"

[secrets]
default = "${SECRET_KEY}"

[tls-fronting]
mask-host = "${MASK_HOST}"
mask-port = 443

[performance]
prefer-ip = "prefer-ipv4"
idle-timeout = "5m"
EOF

    cat > "$CONNECTION_FILE" <<EOF
MTProto proxy: telEgo FakeTLS
Server: ${SERVER_ADDRESS}
Port: ${PROXY_PORT}
SNI / FakeTLS mask-host: ${MASK_HOST}

Telegram link:
${TG_LINK}

HTTPS Telegram link:
${HTTPS_LINK}
EOF

    chmod 600 "$CONFIG_FILE" "$CONNECTION_FILE"
}

open_firewall_if_needed() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "${PROXY_PORT}/tcp" >/dev/null
        log "Открыл TCP-порт ${PROXY_PORT} в UFW."
    fi
}

start_proxy() {
    log "Запускаю MTProto proxy на TCP-порту ${PROXY_PORT} с FakeTLS SNI ${MASK_HOST}..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p "${PROXY_PORT}:${PROXY_PORT}/tcp" \
        -v "${CONFIG_FILE}:/config.toml:ro" \
        "$TELEGO_IMAGE" run -c /config.toml >/dev/null

    sleep 3
    if ! docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qx 'true'; then
        docker logs --tail 100 "$CONTAINER_NAME" >&2 || true
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        die "telEgo не смог запуститься. Лог показан выше."
    fi

    if ! ss -H -ltn "sport = :${PROXY_PORT}" 2>/dev/null | grep -q .; then
        docker logs --tail 100 "$CONTAINER_NAME" >&2 || true
        die "Контейнер запущен, но TCP-порт ${PROXY_PORT} не слушается."
    fi
}

print_result() {
    printf '\n%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' "$BLUE" "$NC"
    printf '%bГотово: telEgo MTProto Proxy с FakeTLS установлен.%b\n' "$GREEN" "$NC"
    printf 'SNI маскировки: %b%s%b\n' "$BLUE" "$MASK_HOST" "$NC"
    printf 'Адрес подключения: %s:%s\n\n' "$SERVER_ADDRESS" "$PROXY_PORT"
    printf 'Ссылка для Telegram:\n%b%s%b\n\n' "$GREEN" "$TG_LINK" "$NC"
    printf 'Ссылка сохранена в: %s\n' "$CONNECTION_FILE"
    printf 'Конфигурация: %s\n' "$CONFIG_FILE"
    printf 'Лог установки: %s\n' "$INSTALL_LOG"
    printf '\nКоманды управления:\n'
    printf '  docker logs -f telego       # логи\n'
    printf '  docker restart telego       # перезапуск\n'
    printf '  docker stop telego          # остановка\n'
    printf '%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' "$BLUE" "$NC"
}

main() {
    printf '%bУстановка telEgo MTProto Proxy / FakeTLS SNI: %s%b\n\n' "$BLUE" "$MASK_HOST" "$NC"
    require_root
    require_supported_os
    setup_logging
    install_dependencies
    ask_connection_address
    ask_port
    check_existing_installation_and_port
    pull_telego_image
    write_configuration
    open_firewall_if_needed
    start_proxy
    print_result
}

main "$@"
