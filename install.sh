#!/usr/bin/env bash
set -Eeuo pipefail

# telemt-doublehop-edge-first-install.sh
#
# Запускать НА РФ-СЕРВЕРЕ A / EDGE.
# Скрипт сам спросит SSH-доступ к зарубежному серверу B / EXIT и настроит связку:
# Telegram client -> A:443/HAProxy -> AmneziaWG tunnel -> B:10.10.10.1:443/Telemt -> Telegram DC
#
# Target: Ubuntu 22.04/24.04/26.04-like VPS with root/sudo.

VERSION="edge-first-1.0.0"

EDGE_PUBLIC_HOST=""
EXIT_SSH=""
EXIT_PUBLIC_HOST=""
TLS_DOMAIN="vk.com"
CLIENT_PORT="443"
AWG_PORT="8443"
TELEMT_VERSION="latest"
SSH_OPTS_STRING="${SSH_OPTS:-}"
ASSUME_YES="0"

TUNNEL_B_IP="10.10.10.1"
TUNNEL_A_IP="10.10.10.2"
TUNNEL_CIDR_B="10.10.10.1/24"
TUNNEL_CIDR_A="10.10.10.2/24"

CONTROL_SOCKET="/tmp/telemt-dh-${RANDOM}-${RANDOM}.sock"
ORIG_ARGS=("$@")

log() { printf '\n\033[1;34m[telemt-doublehop]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${EXIT_SSH:-}" ]]; then
    ssh -S "$CONTROL_SOCKET" -O exit "$EXIT_SSH" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'die "Ошибка на строке $LINENO. Установка остановлена."' ERR

usage() {
  cat <<EOF
telemt-doublehop-edge-first-install.sh v${VERSION}

Запускать НА РФ-СЕРВЕРЕ A / EDGE.
Скрипт спросит зарубежный сервер B / EXIT и настроит double-hop.

Usage:
  bash telemt-doublehop-edge-first-install.sh

Или без вопросов:
  bash telemt-doublehop-edge-first-install.sh \\
    --exit root@IP_ЗАРУБЕЖНОГО_СЕРВЕРА \\
    --exit-public IP_ЗАРУБЕЖНОГО_СЕРВЕРА \\
    --edge-public IP_РФ_СЕРВЕРА \\
    --tls-domain vk.com

Options:
  --exit           SSH до зарубежного сервера B, например root@2.2.2.2
  --exit-public    Публичный IP/домен зарубежного сервера B для AmneziaWG Endpoint
  --edge-public    Публичный IP/домен этого РФ-сервера A для Telegram proxy-ссылок
  --tls-domain     SNI/TLS-домен для ee/FakeTLS ссылок. Default: vk.com
  --client-port    Порт клиентов Telegram на A и Telemt на B. Default: 443
  --awg-port       UDP-порт AmneziaWG на B. Default: 8443
  --telemt-version latest или конкретная версия, например 3.4.18
  --ssh-opts       Дополнительные SSH-опции к B, например '-i ~/.ssh/id_ed25519 -p 22'
  -y, --yes        Не спрашивать финальное подтверждение
  -h, --help       Помощь

Можно также передать SSH_OPTS через окружение:
  SSH_OPTS='-i ~/.ssh/id_ed25519 -p 22' bash telemt-doublehop-edge-first-install.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exit) EXIT_SSH="${2:-}"; shift 2 ;;
    --exit-public) EXIT_PUBLIC_HOST="${2:-}"; shift 2 ;;
    --edge-public) EDGE_PUBLIC_HOST="${2:-}"; shift 2 ;;
    --tls-domain) TLS_DOMAIN="${2:-}"; shift 2 ;;
    --client-port) CLIENT_PORT="${2:-}"; shift 2 ;;
    --awg-port) AWG_PORT="${2:-}"; shift 2 ;;
    --telemt-version) TELEMT_VERSION="${2:-}"; shift 2 ;;
    --ssh-opts) SSH_OPTS_STRING="${2:-}"; shift 2 ;;
    -y|--yes) ASSUME_YES="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    log "Нужны root-права. Перезапускаю через sudo..."
    exec sudo -E bash "$0" "${ORIG_ARGS[@]}"
  fi
  die "Запусти скрипт от root или установи sudo."
fi

prompt() {
  local var_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local value=""

  if [[ -n "${!var_name:-}" ]]; then
    return 0
  fi

  if [[ -n "$default_value" ]]; then
    read -r -p "$label [$default_value]: " value </dev/tty || value=""
    value="${value:-$default_value}"
  else
    while [[ -z "$value" ]]; do
      read -r -p "$label: " value </dev/tty || value=""
    done
  fi

  printf -v "$var_name" '%s' "$value"
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsS --max-time 6 https://ifconfig.me/ip 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s' "$ip"
}

q() { printf '%q' "$1"; }

rand_int() {
  local min="$1"
  local max="$2"
  local n
  n="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
  echo $(( min + (n % (max - min + 1)) ))
}

rand_hex() {
  openssl rand -hex "$1"
}

validate_port() {
  local value="$1"
  local name="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name должен быть числом"
  (( value >= 1 && value <= 65535 )) || die "$name вне диапазона 1..65535"
}

install_base_packages_local() {
  export DEBIAN_FRONTEND=noninteractive
  command -v apt-get >/dev/null 2>&1 || die "Скрипт рассчитан на Ubuntu/Debian с apt-get. Лучше использовать чистый Ubuntu VPS."

  apt-get update -y
  apt-get install -y \
    ca-certificates \
    curl \
    gnupg2 \
    software-properties-common \
    python3-launchpadlib \
    lsb-release \
    iproute2 \
    iputils-ping \
    net-tools \
    jq \
    openssl \
    ufw
}

install_awg_local() {
  install_base_packages_local
  apt-get install -y "linux-headers-$(uname -r)" || true

  if ! command -v awg >/dev/null 2>&1; then
    add-apt-repository -y ppa:amnezia/ppa
    apt-get update -y
    apt-get install -y amneziawg
  fi

  mkdir -p /etc/amnezia/amneziawg
  chmod 700 /etc/amnezia/amneziawg

  if [[ ! -s /etc/amnezia/amneziawg/private.key || ! -s /etc/amnezia/amneziawg/public.key ]]; then
    umask 077
    awg genkey | tee /etc/amnezia/amneziawg/private.key | awg pubkey > /etc/amnezia/amneziawg/public.key
  fi

  chmod 600 /etc/amnezia/amneziawg/private.key
  chmod 644 /etc/amnezia/amneziawg/public.key
}

extract_marker() {
  local marker="$1"
  awk -F= -v key="$marker" '$1 == key {print substr($0, length(key) + 2)}'
}

build_ssh_arrays() {
  # shellcheck disable=SC2206
  SSH_EXTRA_OPTS_ARRAY=($SSH_OPTS_STRING)
  SSH_COMMON_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o ControlMaster=auto
    -o ControlPersist=10m
    -o ControlPath="$CONTROL_SOCKET"
  )
}

ssh_b() {
  ssh "${SSH_COMMON_OPTS[@]}" "${SSH_EXTRA_OPTS_ARRAY[@]}" "$EXIT_SSH" "$@"
}

remote_b() {
  local env_string="${1:-:}"
  local setup_env="set -a; ${env_string}; set +a;"
  ssh_b "if [ \"\$(id -u)\" -eq 0 ]; then ${setup_env} bash -s; elif command -v sudo >/dev/null 2>&1; then ${setup_env} sudo -E bash -s; else echo 'Need root or sudo on EXIT server' >&2; exit 1; fi"
}

install_awg_remote_b_and_get_keys() {
  remote_b "" <<'REMOTE'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

command -v apt-get >/dev/null 2>&1 || { echo "Only apt-based Ubuntu/Debian systems are supported" >&2; exit 1; }

apt-get update -y
apt-get install -y \
  ca-certificates \
  curl \
  gnupg2 \
  software-properties-common \
  python3-launchpadlib \
  lsb-release \
  iproute2 \
  iputils-ping \
  net-tools \
  jq \
  openssl \
  ufw
apt-get install -y "linux-headers-$(uname -r)" || true

if ! command -v awg >/dev/null 2>&1; then
  add-apt-repository -y ppa:amnezia/ppa
  apt-get update -y
  apt-get install -y amneziawg
fi

mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg

if [ ! -s /etc/amnezia/amneziawg/private.key ] || [ ! -s /etc/amnezia/amneziawg/public.key ]; then
  umask 077
  awg genkey | tee /etc/amnezia/amneziawg/private.key | awg pubkey > /etc/amnezia/amneziawg/public.key
fi

chmod 600 /etc/amnezia/amneziawg/private.key
chmod 644 /etc/amnezia/amneziawg/public.key

echo "__AWG_PRIVATE=$(tr -d '\n' < /etc/amnezia/amneziawg/private.key)"
echo "__AWG_PUBLIC=$(tr -d '\n' < /etc/amnezia/amneziawg/public.key)"
REMOTE
}

configure_awg_b() {
  local envs
  envs="
    B_PRIVATE_KEY=$(q "$B_PRIVATE_KEY")
    A_PUBLIC_KEY=$(q "$A_PUBLIC_KEY")
    EDGE_PUBLIC_HOST=$(q "$EDGE_PUBLIC_HOST")
    AWG_PORT=$(q "$AWG_PORT")
    TUNNEL_CIDR_B=$(q "$TUNNEL_CIDR_B")
    TUNNEL_A_IP=$(q "$TUNNEL_A_IP")
    CLIENT_PORT=$(q "$CLIENT_PORT")
    JC=$(q "$JC")
    JMIN=$(q "$JMIN")
    JMAX=$(q "$JMAX")
    S1=$(q "$S1")
    S2=$(q "$S2")
    S3=$(q "$S3")
    S4=$(q "$S4")
    H1=$(q "$H1")
    H2=$(q "$H2")
    H3=$(q "$H3")
    H4=$(q "$H4")
  "

  remote_b "$envs" <<'REMOTE'
set -Eeuo pipefail

mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg

if [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
  cp /etc/amnezia/amneziawg/awg0.conf "/etc/amnezia/amneziawg/awg0.conf.bak.$(date +%Y%m%d-%H%M%S)"
fi

cat > /etc/amnezia/amneziawg/awg0.conf <<EOF
[Interface]
Address = ${TUNNEL_CIDR_B}
ListenPort = ${AWG_PORT}
PrivateKey = ${B_PRIVATE_KEY}
SaveConfig = false

Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = ${A_PUBLIC_KEY}
AllowedIPs = ${TUNNEL_A_IP}/32
EOF

chmod 600 /etc/amnezia/amneziawg/awg0.conf

systemctl disable --now awg-quick@awg0 >/dev/null 2>&1 || true
systemctl enable --now awg-quick@awg0

if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then
  ufw allow from "${EDGE_PUBLIC_HOST}" to any port "${AWG_PORT}" proto udp || true
  ufw allow from "${TUNNEL_A_IP}" to any port "${CLIENT_PORT}" proto tcp || true
fi

awg show awg0 >/dev/null
REMOTE
}

configure_awg_a_local() {
  if [[ -f /etc/amnezia/amneziawg/awg0.conf ]]; then
    cp /etc/amnezia/amneziawg/awg0.conf "/etc/amnezia/amneziawg/awg0.conf.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  cat > /etc/amnezia/amneziawg/awg0.conf <<EOF
[Interface]
Address = ${TUNNEL_CIDR_A}
PrivateKey = ${A_PRIVATE_KEY}

Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

I1 = ${I1}
I2 = ${I2}
I3 = ${I3}
I4 = ${I4}
I5 = ${I5}

[Peer]
PublicKey = ${B_PUBLIC_KEY}
Endpoint = ${EXIT_PUBLIC_HOST}:${AWG_PORT}
AllowedIPs = ${TUNNEL_B_IP}/32
PersistentKeepalive = 25
EOF

  chmod 600 /etc/amnezia/amneziawg/awg0.conf

  systemctl disable --now awg-quick@awg0 >/dev/null 2>&1 || true
  systemctl enable --now awg-quick@awg0
  awg show awg0 >/dev/null
}

install_telemt_b() {
  local envs
  envs="
    CLIENT_PORT=$(q "$CLIENT_PORT")
    TLS_DOMAIN=$(q "$TLS_DOMAIN")
    TELEMT_SECRET=$(q "$TELEMT_SECRET")
    TELEMT_VERSION=$(q "$TELEMT_VERSION")
    EDGE_PUBLIC_HOST=$(q "$EDGE_PUBLIC_HOST")
    TUNNEL_B_IP=$(q "$TUNNEL_B_IP")
    TUNNEL_A_IP=$(q "$TUNNEL_A_IP")
  "

  remote_b "$envs" <<'REMOTE'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y curl jq openssl iproute2 net-tools ca-certificates

if ss -ltnp | grep -E "[:.]${CLIENT_PORT}[[:space:]]" | grep -vq telemt; then
  echo "Port ${CLIENT_PORT}/tcp is already used by another process on EXIT server:" >&2
  ss -ltnp | grep -E "[:.]${CLIENT_PORT}[[:space:]]" >&2 || true
  exit 1
fi

if [ "${TELEMT_VERSION}" = "latest" ]; then
  TELEMT_ACTION="install"
else
  TELEMT_ACTION="${TELEMT_VERSION}"
fi

curl -fsSL https://raw.githubusercontent.com/telemt/telemt/main/install.sh \
  | sh -s -- "${TELEMT_ACTION}" \
      -p "${CLIENT_PORT}" \
      -d "${TLS_DOMAIN}" \
      -s "${TELEMT_SECRET}" \
      -l ru

mkdir -p /etc/telemt

if [ -f /etc/telemt/telemt.toml ]; then
  cp /etc/telemt/telemt.toml "/etc/telemt/telemt.toml.bak.$(date +%Y%m%d-%H%M%S)"
fi

cat > /etc/telemt/telemt.toml <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${EDGE_PUBLIC_HOST}"
public_port = ${CLIENT_PORT}

[server]
port = ${CLIENT_PORT}
listen_addr_ipv4 = "${TUNNEL_B_IP}"
proxy_protocol = true
max_connections = 10000

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
main = "${TELEMT_SECRET}"
EOF

if id telemt >/dev/null 2>&1; then
  chown -R telemt:telemt /etc/telemt || true
  chown -R telemt:telemt /opt/telemt || true
fi

systemctl restart telemt

for i in $(seq 1 90); do
  if systemctl is-active --quiet telemt && curl -fsS http://127.0.0.1:9091/v1/users >/tmp/telemt-users.json 2>/dev/null; then
    echo "__TELEMT_READY=1"
    exit 0
  fi
  sleep 1
done

echo "Telemt did not become ready in 90 seconds" >&2
systemctl status telemt --no-pager >&2 || true
journalctl -u telemt -n 120 --no-pager >&2 || true
exit 1
REMOTE
}

install_haproxy_a_local() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y haproxy iproute2 net-tools curl

  if ss -ltnp | grep -E "[:.]${CLIENT_PORT}[[:space:]]" | grep -vq haproxy; then
    echo "Port ${CLIENT_PORT}/tcp is already used by another process on EDGE/RF server:" >&2
    ss -ltnp | grep -E "[:.]${CLIENT_PORT}[[:space:]]" >&2 || true
    exit 1
  fi

  if [[ -f /etc/haproxy/haproxy.cfg ]]; then
    cp /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 10000

defaults
    log     global
    mode    tcp
    option  tcplog
    option  clitcpka
    option  srvtcpka
    timeout connect 5s
    timeout client  2h
    timeout server  2h
    timeout check   5s

frontend tcp_in_${CLIENT_PORT}
    bind *:${CLIENT_PORT}
    maxconn 8000
    option tcp-smart-accept
    default_backend telemt_nodes

backend telemt_nodes
    option tcp-smart-connect
    server telemt_b ${TUNNEL_B_IP}:${CLIENT_PORT} check inter 5s rise 2 fall 3 send-proxy-v2

EOF

  haproxy -c -f /etc/haproxy/haproxy.cfg
  systemctl enable --now haproxy
  systemctl restart haproxy
  systemctl is-active --quiet haproxy

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then
    ufw allow "${CLIENT_PORT}/tcp" || true
  fi
}

get_final_links_from_b() {
  remote_b "" <<'REMOTE'
set -Eeuo pipefail

curl -fsS http://127.0.0.1:9091/v1/users >/tmp/telemt-users.json

echo "__LINKS_BEGIN"
jq -r '
  .. | strings
  | select(startswith("tg://") or startswith("https://t.me/proxy") or startswith("https://t.me/mtproxy"))
' /tmp/telemt-users.json

echo "__LINKS_END"

echo "__RAW_USERS_JSON_BEGIN"
cat /tmp/telemt-users.json
echo
echo "__RAW_USERS_JSON_END"
REMOTE
}

check_tunnel_local() {
  log "Проверяю туннель A -> B"
  ping -c 3 "$TUNNEL_B_IP" || return 1
  timeout 5 bash -c "cat < /dev/null > /dev/tcp/${TUNNEL_B_IP}/${CLIENT_PORT}" || return 1
}

print_summary() {
  cat <<EOF

========================================================================
ГОТОВО.

Схема:
  Telegram client -> ${EDGE_PUBLIC_HOST}:${CLIENT_PORT}
                  -> HAProxy на РФ-сервере A
                  -> AmneziaWG tunnel
                  -> Telemt на зарубежном B / ${TUNNEL_B_IP}:${CLIENT_PORT}
                  -> Telegram DC

Открой в cloud/firewall провайдера:

  A / РФ / этот сервер:
    TCP ${CLIENT_PORT} from clients

  B / зарубежный:
    UDP ${AWG_PORT} from ${EDGE_PUBLIC_HOST}

Команды диагностики на РФ-сервере A:
  systemctl status awg-quick@awg0 haproxy --no-pager
  awg show
  ss -ltnp | grep ':${CLIENT_PORT}'
  journalctl -u haproxy -n 100 --no-pager

Команды диагностики на зарубежном B:
  ssh ${EXIT_SSH} 'systemctl status awg-quick@awg0 telemt --no-pager'
  ssh ${EXIT_SSH} 'awg show; ss -ltnp | grep ":${CLIENT_PORT}"'
  ssh ${EXIT_SSH} 'journalctl -u telemt -n 150 --no-pager'
  ssh ${EXIT_SSH} 'curl -s http://127.0.0.1:9091/v1/users | jq'

Если поменяешь tls-domain/SNI, старые ee/tls-ссылки могут перестать работать.
========================================================================
EOF
}

main() {
  log "Telemt double-hop edge-first installer v${VERSION}"
  cat <<'EOF'

Запусти этот файл НА РФ-СЕРВЕРЕ A.
Этот сервер станет входом для Telegram-клиентов.
Зарубежный сервер B будет настроен по SSH из этого скрипта.

EOF

  local detected_edge_ip
  detected_edge_ip="$(detect_public_ip)"

  prompt EDGE_PUBLIC_HOST "Публичный IP/домен ЭТОГО РФ-сервера A для Telegram proxy-ссылок" "$detected_edge_ip"
  prompt EXIT_SSH "SSH до зарубежного сервера B / EXIT, например root@2.2.2.2"
  prompt EXIT_PUBLIC_HOST "Публичный IP/домен зарубежного сервера B для AmneziaWG Endpoint"
  prompt TLS_DOMAIN "TLS/SNI-домен для FakeTLS/ee-ссылок" "$TLS_DOMAIN"
  prompt CLIENT_PORT "Порт клиентов Telegram на РФ-сервере A" "$CLIENT_PORT"
  prompt AWG_PORT "UDP-порт AmneziaWG на зарубежном B" "$AWG_PORT"
  prompt TELEMT_VERSION "Версия Telemt: latest или конкретная версия" "$TELEMT_VERSION"

  if [[ -z "$SSH_OPTS_STRING" ]]; then
    read -r -p "Дополнительные SSH-опции к B, если нужны [-i key -p port], иначе Enter: " SSH_OPTS_STRING </dev/tty || SSH_OPTS_STRING=""
  fi

  validate_port "$CLIENT_PORT" "client-port"
  validate_port "$AWG_PORT" "awg-port"

  cat <<EOF

Проверь роли перед установкой:

  A / EDGE / РФ / ЭТОТ СЕРВЕР:
    public host: ${EDGE_PUBLIC_HOST}
    client TCP:  ${CLIENT_PORT}
    будет установлено: AmneziaWG + HAProxy

  B / EXIT / зарубежный сервер:
    ssh:         ${EXIT_SSH}
    public host: ${EXIT_PUBLIC_HOST}
    AWG UDP:     ${AWG_PORT}
    будет установлено: AmneziaWG + Telemt

  TLS/SNI domain: ${TLS_DOMAIN}
  Telemt version: ${TELEMT_VERSION}
EOF

  if [[ "$ASSUME_YES" != "1" ]]; then
    read -r -p "Продолжить установку? [y/N]: " confirm </dev/tty || confirm=""
    case "$confirm" in
      y|Y|yes|YES|да|ДА) ;;
      *) die "Отменено пользователем." ;;
    esac
  fi

  build_ssh_arrays

  log "Проверяю SSH к зарубежному серверу B"
  ssh_b "echo SSH_OK" >/dev/null
  ok "SSH к B работает"

  log "Устанавливаю AmneziaWG на РФ-сервере A"
  install_awg_local
  A_PRIVATE_KEY="$(tr -d '\n' < /etc/amnezia/amneziawg/private.key)"
  A_PUBLIC_KEY="$(tr -d '\n' < /etc/amnezia/amneziawg/public.key)"
  [[ -n "$A_PRIVATE_KEY" && -n "$A_PUBLIC_KEY" ]] || die "Не удалось получить ключи A"
  ok "AmneziaWG на A готов"

  log "Устанавливаю AmneziaWG на зарубежном B и получаю ключи"
  B_KEYS_OUTPUT="$(install_awg_remote_b_and_get_keys)"
  B_PRIVATE_KEY="$(printf '%s\n' "$B_KEYS_OUTPUT" | extract_marker "__AWG_PRIVATE")"
  B_PUBLIC_KEY="$(printf '%s\n' "$B_KEYS_OUTPUT" | extract_marker "__AWG_PUBLIC")"
  [[ -n "$B_PRIVATE_KEY" && -n "$B_PUBLIC_KEY" ]] || die "Не удалось получить ключи B"
  ok "AmneziaWG на B готов"

  log "Генерирую уникальные параметры AmneziaWG и Telemt secret"
  JC="4"
  JMIN="8"
  JMAX="80"
  S1="$(rand_int 15 150)"
  S2="$(rand_int 15 150)"
  while [[ $((S1 + 56)) -eq "$S2" ]]; do S2="$(rand_int 15 150)"; done
  S3="$(rand_int 15 150)"
  S4="0"
  H1="$(rand_int 5 2147483647)"
  H2="$(rand_int 5 2147483647)"; while [[ "$H2" == "$H1" ]]; do H2="$(rand_int 5 2147483647)"; done
  H3="$(rand_int 5 2147483647)"; while [[ "$H3" == "$H1" || "$H3" == "$H2" ]]; do H3="$(rand_int 5 2147483647)"; done
  H4="$(rand_int 5 2147483647)"; while [[ "$H4" == "$H1" || "$H4" == "$H2" || "$H4" == "$H3" ]]; do H4="$(rand_int 5 2147483647)"; done
  I_HEX="$(rand_hex 8)"
  I1="<b 0xc100000001${I_HEX}00>"
  I2="<b 0xc200000001${I_HEX}00>"
  I3="<b 0xc300000001${I_HEX}00>"
  I4="<b 0x43${I_HEX}>"
  I5="<b 0x43${I_HEX}>"
  TELEMT_SECRET="$(rand_hex 16)"
  ok "Параметры сгенерированы"

  log "Настраиваю AmneziaWG на B"
  configure_awg_b
  ok "B awg0 запущен"

  log "Настраиваю AmneziaWG на A"
  configure_awg_a_local
  ok "A awg0 запущен"

  if check_tunnel_local; then
    ok "Туннель A -> B работает"
  else
    warn "Туннель A -> B пока не прошёл проверку. Проверь cloud firewall: на B должен быть открыт UDP ${AWG_PORT} от ${EDGE_PUBLIC_HOST}. Продолжаю установку."
  fi

  log "Устанавливаю и настраиваю Telemt на зарубежном B"
  install_telemt_b
  ok "Telemt на B запущен"

  log "Устанавливаю и настраиваю HAProxy на РФ-сервере A"
  install_haproxy_a_local
  ok "HAProxy на A запущен"

  log "Получаю готовые Telegram proxy-ссылки с B"
  LINKS_OUTPUT="$(get_final_links_from_b || true)"
  printf '%s\n' "$LINKS_OUTPUT"

  print_summary
}

main "$@"
