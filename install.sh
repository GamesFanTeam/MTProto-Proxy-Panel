#!/usr/bin/env bash
set -Eeuo pipefail

# telemt-doublehop-edge-first-install.sh
#
# Запускать НА РФ-СЕРВЕРЕ A / EDGE.
# Скрипт сам спросит SSH-доступ к зарубежному серверу B / EXIT и настроит связку:
# Browser -> site-domain:443/HAProxy -> nginx decoy 127.0.0.1:8443
# Telegram client -> proxy-domain:443/HAProxy -> AmneziaWG tunnel -> B:10.10.10.1:443/Telemt -> Telegram DC
#
# Target: clean Ubuntu/Debian VPS with root/sudo. Optimized for Ubuntu 22.04/24.04/26.04.

VERSION="1.3.3"

EDGE_PUBLIC_HOST=""
EDGE_SOURCE_IP=""
SITE_DOMAIN=""
PROXY_DOMAIN=""
EXIT_SSH=""
EXIT_PUBLIC_HOST=""
TLS_DOMAIN=""
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
install.sh / telemt-doublehop edge-first v${VERSION}

Запускать НА РФ-СЕРВЕРЕ A / EDGE.
Скрипт спросит зарубежный сервер B / EXIT и настроит double-hop.

Usage:
  bash install.sh

Или без вопросов:
  bash install.sh \\
    --site-domain hid-net.ru \\
    --proxy-domain tg.hid-net.ru \\
    --exit root@IP_ЗАРУБЕЖНОГО_СЕРВЕРА \\
    --exit-public IP_ЗАРУБЕЖНОГО_СЕРВЕРА

Options:
  --site-domain    Домен сайта-заглушки на РФ-сервере A, например hid-net.ru
  --proxy-domain   Домен Telegram proxy/SNI, например tg.hid-net.ru
  --exit           SSH до зарубежного сервера B, например root@2.2.2.2
  --exit-public    Публичный IP/домен зарубежного сервера B для AmneziaWG Endpoint
  --edge-public    Совместимость со старыми версиями: то же, что --proxy-domain
  --tls-domain     Совместимость со старыми версиями: то же, что --proxy-domain
  --client-port    Порт клиентов Telegram на A и Telemt на B. Default: 443
  --awg-port       UDP-порт AmneziaWG на B. Default: 8443
  --telemt-version latest или конкретная версия, например 3.4.18
  --ssh-opts       Дополнительные SSH-опции к B, например '-i /root/.ssh/id_ed25519 -p 22'
  -y, --yes        Не спрашивать финальное подтверждение
  -h, --help       Помощь

Можно также передать SSH_OPTS через окружение:
  SSH_OPTS='-i /root/.ssh/id_ed25519 -p 22' bash install.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-domain) SITE_DOMAIN="${2:-}"; shift 2 ;;
    --proxy-domain) PROXY_DOMAIN="${2:-}"; shift 2 ;;
    --exit) EXIT_SSH="${2:-}"; shift 2 ;;
    --exit-public) EXIT_PUBLIC_HOST="${2:-}"; shift 2 ;;
    --edge-public) EDGE_PUBLIC_HOST="${2:-}"; PROXY_DOMAIN="${2:-}"; shift 2 ;;
    --tls-domain) TLS_DOMAIN="${2:-}"; PROXY_DOMAIN="${2:-}"; shift 2 ;;
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

extract_host_from_ssh_target() {
  local target="$1"
  local host=""
  host="${target##*@}"
  host="${host%%:*}"
  printf '%s' "$host"
}

normalize_domain() {
  local domain="$1"
  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"
  domain="${domain%.}"
  printf '%s' "$domain"
}

is_ipv4() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

resolve_ipv4s() {
  local domain="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true
  else
    getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true
  fi
}

warn_if_domain_not_points_to_edge() {
  local domain="$1"
  local edge_ip="$2"
  local records=""

  if is_ipv4 "$domain"; then
    warn "${domain} выглядит как IP, а для v1.3.3 лучше использовать домен. Продолжаю, но маскировка будет слабее."
    return 0
  fi

  records="$(resolve_ipv4s "$domain" | paste -sd' ' - | sed 's/[[:space:]]*$//')"
  if [[ -z "$records" ]]; then
    warn "DNS A-запись для ${domain} пока не найдена. Проверь, что домен указывает на РФ-сервер A: ${edge_ip}."
    return 0
  fi

  if ! grep -qw "$edge_ip" <<< "$records"; then
    warn "DNS ${domain} сейчас указывает на: ${records}, а публичный IP этого РФ-сервера A: ${edge_ip}."
    warn "Для корректной схемы ${domain} должен указывать именно на РФ-сервер A."
  else
    ok "DNS ${domain} указывает на РФ-сервер A (${edge_ip})"
  fi
}
domain_to_hex() {
  local domain="$1"
  printf '%s' "$domain" | od -An -tx1 | tr -d '[:space:]'
}
build_ee_proxy_link() {
  local host="$1"
  local port="$2"
  local secret="$3"
  local sni="$4"
  local sni_hex
  sni_hex="$(domain_to_hex "$sni")"
  printf 'https://t.me/proxy?server=%s&port=%s&secret=ee%s%s' "$host" "$port" "$secret" "$sni_hex"
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

install_preflight_packages_local() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a

  command -v apt-get >/dev/null 2>&1 || die "Скрипт рассчитан на Ubuntu/Debian с apt-get. Лучше использовать чистый Ubuntu VPS."

  clean_amnezia_apt_sources_local
  apt-get update -y
  apt-get install -y ca-certificates curl openssh-client gnupg2 lsb-release iproute2 jq openssl dnsutils
}

clean_amnezia_apt_sources_local() {
  # После старых попыток установки может остаться PPA под неподдерживаемый codename
  # вроде Ubuntu 26.04 resolute. Он ломает любой apt-get update, поэтому чистим его заранее.
  rm -f /etc/apt/sources.list.d/*amnezia* 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/*launchpadcontent*amnezia* 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/*ppa_launchpadcontent_net_amnezia* 2>/dev/null || true

  if [[ -f /etc/apt/sources.list ]]; then
    sed -i.bak.telemt-dh \
      -e '/ppa\.launchpadcontent\.net\/amnezia\/ppa/d' \
      -e '/ppa\.launchpad\.net\/amnezia\/ppa/d' \
      /etc/apt/sources.list || true
  fi
}

choose_amnezia_ppa_suite_local() {
  local os_id="" codename="" suite=""
  # shellcheck disable=SC1091
  [[ -f /etc/os-release ]] && . /etc/os-release
  os_id="${ID:-}"
  codename="${VERSION_CODENAME:-}"

  if [[ "$os_id" == "ubuntu" ]]; then
    case "$codename" in
      focal|jammy|noble) suite="$codename" ;;
      # Ubuntu 25.10/26.04 и другие свежие релизы часто ещё не имеют отдельного PPA.
      # Для них используем noble fallback.
      *) suite="noble" ;;
    esac
  else
    # Для Debian в публичных инструкциях AmneziaWG обычно используется focal PPA.
    suite="focal"
  fi

  printf '%s' "$suite"
}

setup_amnezia_repo_local() {
  local suite
  suite="$(choose_amnezia_ppa_suite_local)"

  log "Подключаю репозиторий AmneziaWG через PPA suite: ${suite}"
  clean_amnezia_apt_sources_local

  install -d -m 0755 /usr/share/keyrings
  rm -f /usr/share/keyrings/amnezia-archive-keyring.gpg.tmp

  if ! curl -fsSL 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x57290828' \
    | gpg --dearmor -o /usr/share/keyrings/amnezia-archive-keyring.gpg.tmp; then
    warn "Не удалось получить ключ AmneziaWG через curl. Пробую через gpg keyserver."
    gpg --batch --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 57290828
    gpg --batch --export 57290828 | gpg --dearmor -o /usr/share/keyrings/amnezia-archive-keyring.gpg.tmp
  fi

  mv -f /usr/share/keyrings/amnezia-archive-keyring.gpg.tmp /usr/share/keyrings/amnezia-archive-keyring.gpg
  chmod 0644 /usr/share/keyrings/amnezia-archive-keyring.gpg

  cat > /etc/apt/sources.list.d/amnezia-ppa.list <<EOF
# AmneziaWG PPA. For unsupported Ubuntu codenames, installer intentionally uses a supported fallback suite.
deb [signed-by=/usr/share/keyrings/amnezia-archive-keyring.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${suite} main
EOF
}

install_base_packages_local() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  command -v apt-get >/dev/null 2>&1 || die "Скрипт рассчитан на Ubuntu/Debian с apt-get. Лучше использовать чистый Ubuntu VPS."

  clean_amnezia_apt_sources_local
  apt-get update -y
  apt-get install -y \
    ca-certificates \
    curl \
    openssh-client \
    gnupg2 \
    software-properties-common \
    python3-launchpadlib \
    lsb-release \
    iproute2 \
    iputils-ping \
    net-tools \
    jq \
    openssl \
    dnsutils \
    ufw
}

install_awg_local() {
  install_base_packages_local
  apt-get install -y "linux-headers-$(uname -r)" || true

  if ! command -v awg >/dev/null 2>&1; then
    setup_amnezia_repo_local
    apt-get update -y
    if ! apt-get install -y amneziawg; then
      warn "Пакет amneziawg не установился метапакетом. Пробую amneziawg-dkms + amneziawg-tools."
      apt-get install -y amneziawg-dkms amneziawg-tools
    fi
  fi

  command -v awg >/dev/null 2>&1 || die "Команда awg не найдена после установки AmneziaWG."
  command -v awg-quick >/dev/null 2>&1 || die "Команда awg-quick не найдена после установки AmneziaWG."
  modprobe amneziawg >/dev/null 2>&1 || true

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
  local env_string="${1:-}"
  local env_prefix=""
  local line=""

  # env_string приходит как многострочный список безопасно экранированных VAR=value.
  # Не вставляем его через `set -a; ...;`, потому что пустые/отступные строки
  # могут превратиться в одиночный `;` и сломать remote bash.
  while IFS= read -r line; do
    # trim leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    env_prefix+="${line} "
  done <<< "$env_string"

  ssh_b "if [ \"\$(id -u)\" -eq 0 ]; then ${env_prefix}bash -s; elif command -v sudo >/dev/null 2>&1; then ${env_prefix}sudo -E bash -s; else echo 'Need root or sudo on EXIT server' >&2; exit 1; fi"
}

install_awg_remote_b_and_get_keys() {
  remote_b "" <<'REMOTE'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

command -v apt-get >/dev/null 2>&1 || { echo "Only apt-based Ubuntu/Debian systems are supported" >&2; exit 1; }

export NEEDRESTART_MODE=a

# Чистим старые/битые amnezia PPA, например Ubuntu 26.04 resolute без Release-файла.
rm -f /etc/apt/sources.list.d/*amnezia* 2>/dev/null || true
rm -f /etc/apt/sources.list.d/*launchpadcontent*amnezia* 2>/dev/null || true
rm -f /etc/apt/sources.list.d/*ppa_launchpadcontent_net_amnezia* 2>/dev/null || true
if [ -f /etc/apt/sources.list ]; then
  sed -i.bak.telemt-dh \
    -e '/ppa\.launchpadcontent\.net\/amnezia\/ppa/d' \
    -e '/ppa\.launchpad\.net\/amnezia\/ppa/d' \
    /etc/apt/sources.list || true
fi

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
  . /etc/os-release
  case "${ID:-}:${VERSION_CODENAME:-}" in
    ubuntu:focal|ubuntu:jammy|ubuntu:noble) AWG_SUITE="${VERSION_CODENAME}" ;;
    ubuntu:*) AWG_SUITE="noble" ;;
    *) AWG_SUITE="focal" ;;
  esac

  echo "Using AmneziaWG PPA suite: ${AWG_SUITE}"
  install -d -m 0755 /usr/share/keyrings
  rm -f /usr/share/keyrings/amnezia-archive-keyring.gpg.tmp

  if ! curl -fsSL 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x57290828' \
    | gpg --dearmor -o /usr/share/keyrings/amnezia-archive-keyring.gpg.tmp; then
    gpg --batch --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 57290828
    gpg --batch --export 57290828 | gpg --dearmor -o /usr/share/keyrings/amnezia-archive-keyring.gpg.tmp
  fi

  mv -f /usr/share/keyrings/amnezia-archive-keyring.gpg.tmp /usr/share/keyrings/amnezia-archive-keyring.gpg
  chmod 0644 /usr/share/keyrings/amnezia-archive-keyring.gpg

  cat > /etc/apt/sources.list.d/amnezia-ppa.list <<EOF
# AmneziaWG PPA. For unsupported Ubuntu codenames, installer intentionally uses a supported fallback suite.
deb [signed-by=/usr/share/keyrings/amnezia-archive-keyring.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${AWG_SUITE} main
EOF

  apt-get update -y
  apt-get install -y amneziawg || apt-get install -y amneziawg-dkms amneziawg-tools
fi

command -v awg >/dev/null 2>&1 || { echo "awg command not found after AmneziaWG installation" >&2; exit 1; }
command -v awg-quick >/dev/null 2>&1 || { echo "awg-quick command not found after AmneziaWG installation" >&2; exit 1; }
modprobe amneziawg >/dev/null 2>&1 || true

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
    EDGE_SOURCE_IP=$(q "$EDGE_SOURCE_IP")
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
  ufw allow from "${EDGE_SOURCE_IP}" to any port "${AWG_PORT}" proto udp || true
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
export NEEDRESTART_MODE=a

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

install_decoy_nginx_a_local() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a

  log "Настраиваю сайт-заглушку на РФ-сервере A: https://${SITE_DOMAIN}"

  apt-get update -y
  apt-get install -y nginx certbot openssl ca-certificates

  local root_dir="/var/www/telemt-decoy"
  local cert_path="/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem"
  local key_path="/etc/letsencrypt/live/${SITE_DOMAIN}/privkey.pem"

  mkdir -p "$root_dir/.well-known/acme-challenge"
  cat > "$root_dir/index.html" <<EOF
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${SITE_DOMAIN}</title>
  <style>
    body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;background:#f7f7f7;color:#222;display:grid;place-items:center;min-height:100vh}
    main{max-width:720px;background:#fff;border:1px solid #e6e6e6;border-radius:18px;padding:36px;box-shadow:0 12px 40px rgba(0,0,0,.06)}
    h1{margin:0 0 12px;font-size:28px}p{line-height:1.6;color:#555}.ok{color:#167a3a;font-weight:700}
  </style>
</head>
<body>
  <main>
    <h1>${SITE_DOMAIN}</h1>
    <p class="ok">Service is online.</p>
    <p>Техническая страница домена. Сервер работает штатно.</p>
  </main>
</body>
</html>
EOF

  cat > /etc/nginx/sites-available/telemt-decoy-http.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SITE_DOMAIN};

    root ${root_dir};
    index index.html;

    location /.well-known/acme-challenge/ {
        root ${root_dir};
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/telemt-decoy-http.conf /etc/nginx/sites-enabled/telemt-decoy-http.conf
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx

  if [[ ! -s "$cert_path" || ! -s "$key_path" ]]; then
    if ! certbot certonly --webroot \
      -w "$root_dir" \
      -d "$SITE_DOMAIN" \
      --agree-tos \
      --register-unsafely-without-email \
      --non-interactive \
      --keep-until-expiring; then
      warn "Let's Encrypt сертификат для ${SITE_DOMAIN} получить не удалось. Сделаю временный self-signed сертификат, чтобы nginx запустился."
      cert_path="/etc/ssl/certs/telemt-decoy-${SITE_DOMAIN}.crt"
      key_path="/etc/ssl/private/telemt-decoy-${SITE_DOMAIN}.key"
      openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$key_path" \
        -out "$cert_path" \
        -subj "/CN=${SITE_DOMAIN}" >/dev/null 2>&1
      chmod 600 "$key_path"
    fi
  fi

  cat > /etc/nginx/sites-available/telemt-decoy-https-internal.conf <<EOF
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name ${SITE_DOMAIN};

    ssl_certificate     ${cert_path};
    ssl_certificate_key ${key_path};
    ssl_protocols TLSv1.2 TLSv1.3;

    root ${root_dir};
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/telemt-decoy-https-internal.conf /etc/nginx/sites-enabled/telemt-decoy-https-internal.conf
  nginx -t
  systemctl reload nginx

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then
    ufw allow 80/tcp || true
  fi

  ok "Сайт-заглушка готов: https://${SITE_DOMAIN} через HAProxy -> nginx 127.0.0.1:8443"
}

install_haproxy_a_local() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
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

    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }

    acl sni_decoy req.ssl_sni -i ${SITE_DOMAIN}
    acl sni_proxy req.ssl_sni -i ${PROXY_DOMAIN}

    use_backend nginx_decoy if sni_decoy
    use_backend telemt_nodes if sni_proxy
    default_backend telemt_nodes

backend nginx_decoy
    option tcp-smart-connect
    server nginx_local 127.0.0.1:8443 check inter 5s rise 2 fall 3

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

choose_recommended_link() {
  # Из всех ссылок Telemt выбираем одну основную: FakeTLS/EE, желательно https://t.me/...
  local links="$1"
  local recommended=""

  recommended="$(printf '%s\n' "$links" | grep -E '^https://t\.me/(proxy|mtproxy)\?' | grep -E 'secret=ee|secret%3Dee' | head -n 1 || true)"
  if [[ -z "$recommended" ]]; then
    recommended="$(printf '%s\n' "$links" | grep -E '^tg://proxy\?' | grep -E 'secret=ee|secret%3Dee' | head -n 1 || true)"
  fi
  if [[ -z "$recommended" ]]; then
    recommended="$(printf '%s\n' "$links" | grep -E '^https://t\.me/(proxy|mtproxy)\?' | head -n 1 || true)"
  fi
  if [[ -z "$recommended" ]]; then
    recommended="$(printf '%s\n' "$links" | grep -E '^tg://proxy\?' | head -n 1 || true)"
  fi
  if [[ -z "$recommended" ]]; then
    recommended="$(printf '%s\n' "$links" | head -n 1 || true)"
  fi

  printf '%s' "$recommended"
}

print_final_proxy_link() {
  local link="$1"
  local green='\033[1;32m'
  local cyan='\033[1;36m'
  local reset='\033[0m'

  if [[ -z "$link" ]]; then
    warn "Telemt не вернул ссылку через API. Проверь: ssh ${EXIT_SSH} 'curl -s http://127.0.0.1:9091/v1/users | jq'"
    return 0
  fi

  printf '\n'
  printf "${green}================================================================${reset}\n"
  printf "${green}✅ ИТОГОВАЯ ССЫЛКА ДЛЯ TELEGRAM${reset}\n"
  printf "${green}================================================================${reset}\n"
  printf "${green}%s${reset}\n" "$link"
  printf "${cyan}Кликабельная ссылка:${reset} "
  # OSC-8 hyperlink. В терминалах, где OSC-8 не поддерживается, ниже всё равно есть обычный URL.
  printf '\033]8;;%s\aОткрыть прокси в Telegram\033]8;;\a\n' "$link"
  printf "${cyan}Обычный URL для копирования:${reset}\n%s\n" "$link"
  printf "${green}================================================================${reset}\n\n"
}

print_antiblock_diagnostics() {
  cat <<EOF

Если с VPN на устройстве прокси работает, а без VPN из РФ пишет «недоступен»,
то сама связка A -> B, скорее всего, живая. Нужно понять, доходит ли трафик
без VPN до РФ-сервера A.

Быстрая проверка на РФ-сервере A:

  1) Запусти прослушку входящих подключений на ${CLIENT_PORT}/tcp:
     timeout 90 tcpdump -ni any 'tcp port ${CLIENT_PORT}'

  2) Пока команда работает, на телефоне/ПК БЕЗ VPN попробуй подключить прокси.

Как читать результат:

  - Если в tcpdump НЕТ пакетов от твоего клиента — трафик режется до сервера A:
    оператор/маршрут/провайдер/блокировка IP/порта. Решение: менять IP/провайдера A,
    пробовать другой порт или ставить A в другой сети.

  - Если SYN приходит на A, но Telemt на B молчит — проблема в HAProxy/туннеле:
    journalctl -u haproxy -f
    awg show

  - Если пакеты доходят до B/Telemt, но Telegram не подключается — будем менять
    TLS/SNI-домен, режим выдачи ссылки и параметры маскировки Telemt.

EOF
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

  # Пингуем внутренний адрес B, чтобы спровоцировать handshake.
  ping -c 3 "$TUNNEL_B_IP" >/dev/null 2>&1 || true

  local latest now
  latest="$(awg show awg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -n 1 || true)"
  now="$(date +%s)"

  if [[ -n "$latest" && "$latest" =~ ^[0-9]+$ && "$latest" -gt 0 && $((now - latest)) -le 180 ]]; then
    return 0
  fi

  return 1
}

check_telemt_internal_from_a() {
  log "Проверяю доступ A -> B:${CLIENT_PORT} внутри туннеля"
  timeout 6 bash -c "cat < /dev/null > /dev/tcp/${TUNNEL_B_IP}/${CLIENT_PORT}" >/dev/null 2>&1
}

print_summary() {
  cat <<EOF

========================================================================
ГОТОВО.

Схема:
  Обычный браузер -> https://${SITE_DOMAIN}
                  -> HAProxy на РФ-сервере A
                  -> nginx-заглушка 127.0.0.1:8443

  Telegram client -> ${PROXY_DOMAIN}:${CLIENT_PORT}
                  -> HAProxy на РФ-сервере A по SNI ${PROXY_DOMAIN}
                  -> AmneziaWG tunnel
                  -> Telemt на зарубежном B / ${TUNNEL_B_IP}:${CLIENT_PORT}
                  -> Telegram DC

Открой в cloud/firewall провайдера:

  A / РФ / этот сервер:
    TCP ${CLIENT_PORT} from clients
    TCP 80 для выпуска/обновления Let's Encrypt сертификата сайта-заглушки

  B / зарубежный:
    UDP ${AWG_PORT} from ${EDGE_SOURCE_IP}

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

Привет. Это финальный установщик для чистых VPS. Запускать его нужно именно НА РФ-СЕРВЕРЕ A.

Что будет дальше:
  1) этот сервер станет входной точкой для Telegram-клиентов;
  2) я спрошу SSH-доступ к зарубежному VPS B;
  3) сам настрою оба сервера в схему A -> B;
  4) подниму сайт-заглушку для реального домена;
  5) в конце покажу одну главную зелёную Telegram proxy-ссылку.

Пароли от SSH я не храню: если вход на B по паролю, его спросит обычный ssh.

EOF

  local detected_edge_ip
  detected_edge_ip="$(detect_public_ip)"
  EDGE_SOURCE_IP="$detected_edge_ip"

  echo "Шаг 1/8. Укажи домен сайта-заглушки на РФ-сервере A."
  echo "Пример: hid-net.ru. Этот домен должен A-записью указывать на IP этого РФ-сервера: ${detected_edge_ip}"
  prompt SITE_DOMAIN "Домен сайта-заглушки" "$SITE_DOMAIN"
  SITE_DOMAIN="$(normalize_domain "$SITE_DOMAIN")"

  echo
  echo "Шаг 2/8. Укажи домен Telegram proxy/SNI."
  echo "Лучший вариант: отдельный поддомен, например tg.${SITE_DOMAIN}. Он тоже должен указывать на этот РФ-сервер A."
  if [[ -z "$PROXY_DOMAIN" ]]; then
    PROXY_DOMAIN="tg.${SITE_DOMAIN}"
  fi
  prompt PROXY_DOMAIN "Домен proxy/SNI" "$PROXY_DOMAIN"
  PROXY_DOMAIN="$(normalize_domain "$PROXY_DOMAIN")"

  EDGE_PUBLIC_HOST="$PROXY_DOMAIN"
  TLS_DOMAIN="$PROXY_DOMAIN"

  echo
  echo "Шаг 3/8. Укажи SSH-доступ к зарубежному серверу B, где будет работать Telemt."
  echo "Пример: root@2.2.2.2"
  prompt EXIT_SSH "SSH к зарубежному серверу B" ""

  echo
  echo "Шаг 4/8. Укажи публичный IP или домен зарубежного сервера B."
  echo "Обычно это тот же IP, что в SSH после root@. Он нужен серверу A для подключения к туннелю."
  default_exit_public="$(extract_host_from_ssh_target "$EXIT_SSH")"
  prompt EXIT_PUBLIC_HOST "Публичный IP или домен зарубежного B" "$default_exit_public"

  echo
  echo "Шаг 5/8. Порт, который будет открыт для клиентов Telegram на РФ-сервере A. Обычно 443."
  prompt CLIENT_PORT "TCP-порт для клиентов Telegram" "$CLIENT_PORT"

  echo
  echo "Шаг 6/8. UDP-порт туннеля AmneziaWG на зарубежном B. Обычно 8443."
  prompt AWG_PORT "UDP-порт AmneziaWG" "$AWG_PORT"

  echo
  echo "Шаг 7/8. Версия Telemt. Обычно оставляем latest."
  prompt TELEMT_VERSION "Версия Telemt" "$TELEMT_VERSION"

  echo
  echo "Шаг 8/8. Проверяю DNS-логику: сайт и proxy-домен должны указывать на РФ-сервер A."

  if [[ -z "$SSH_OPTS_STRING" ]]; then
    echo
    echo "Дополнительно: если для SSH к B нужен ключ или нестандартный порт, укажи опции."
    echo "Пример: -i /root/.ssh/id_ed25519 -p 2222"
    read -r -p "SSH-опции к B, или просто Enter: " SSH_OPTS_STRING </dev/tty || SSH_OPTS_STRING=""
  fi

  validate_port "$CLIENT_PORT" "client-port"
  validate_port "$AWG_PORT" "awg-port"

  cat <<EOF

Проверь роли перед установкой:

  A / EDGE / РФ / ЭТОТ СЕРВЕР:
    site domain:  ${SITE_DOMAIN}
    proxy domain: ${PROXY_DOMAIN}
    client TCP:   ${CLIENT_PORT}
    будет установлено: AmneziaWG + HAProxy + nginx-заглушка

  B / EXIT / зарубежный сервер:
    ssh:         ${EXIT_SSH}
    public host: ${EXIT_PUBLIC_HOST}
    AWG UDP:     ${AWG_PORT}
    будет установлено: AmneziaWG + Telemt

  TLS/SNI domain: ${TLS_DOMAIN}
  Telemt version: ${TELEMT_VERSION}
EOF

  if [[ "$ASSUME_YES" != "1" ]]; then
    read -r -p "Всё верно? Начинаю установку. Введи y и нажми Enter [y/N]: " confirm </dev/tty || confirm=""
    case "$confirm" in
      y|Y|yes|YES|да|ДА) ;;
      *) die "Отменено пользователем." ;;
    esac
  fi

  log "Подготавливаю РФ-сервер A: ставлю базовые пакеты для установки"
  install_preflight_packages_local
  ok "Базовые пакеты на A готовы"

  warn_if_domain_not_points_to_edge "$SITE_DOMAIN" "$detected_edge_ip"
  warn_if_domain_not_points_to_edge "$PROXY_DOMAIN" "$detected_edge_ip"

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
    warn "Туннель A -> B пока не прошёл проверку. Проверь cloud firewall: на B должен быть открыт UDP ${AWG_PORT} от ${EDGE_SOURCE_IP}. Продолжаю установку."
  fi

  log "Устанавливаю и настраиваю Telemt на зарубежном B"
  install_telemt_b
  ok "Telemt на B запущен"

  if check_telemt_internal_from_a; then
    ok "A видит Telemt на B через туннель"
  else
    warn "A пока не видит Telemt на B через туннель. Чаще всего причина — закрыт UDP ${AWG_PORT} на зарубежном B в cloud firewall провайдера. HAProxy всё равно установлю, но ссылку нужно тестировать после открытия порта."
  fi

  log "Устанавливаю nginx-заглушку на РФ-сервере A"
  install_decoy_nginx_a_local
  ok "nginx-заглушка на A готова"

  log "Устанавливаю и настраиваю HAProxy на РФ-сервере A"
  install_haproxy_a_local
  ok "HAProxy на A запущен"

  log "Получаю готовые Telegram proxy-ссылки с B"
  LINKS_OUTPUT="$(get_final_links_from_b || true)"

  ALL_PROXY_LINKS="$(printf '%s\n' "$LINKS_OUTPUT" | awk '/__LINKS_BEGIN/{flag=1;next}/__LINKS_END/{flag=0}flag && NF')"
  # Главную ссылку собираем сами, чтобы гарантировать совпадение:
  # server=${PROXY_DOMAIN}, tls_domain=${PROXY_DOMAIN}, secret=ee + TELEMT_SECRET + hex(PROXY_DOMAIN)
  FINAL_PROXY_LINK="$(build_ee_proxy_link "$PROXY_DOMAIN" "$CLIENT_PORT" "$TELEMT_SECRET" "$TLS_DOMAIN")"

  print_final_proxy_link "$FINAL_PROXY_LINK"

  if [[ -n "$ALL_PROXY_LINKS" ]]; then
    echo "Все ссылки, которые вернул Telemt:"
    printf '%s\n' "$ALL_PROXY_LINKS" | sed 's/^/  - /'
  else
    printf '%s\n' "$LINKS_OUTPUT"
  fi

  print_summary
  print_antiblock_diagnostics
}

main "$@"
