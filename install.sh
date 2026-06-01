#!/usr/bin/env bash
# Telemt inbound DPI bypass patch: server-advertised TCP MSS fragmentation
# Version: 1.0
#
# Purpose:
#   Keep Telemt Direct egress untouched, but fragment the Telegram client's
#   inbound Fake-TLS ClientHello by advertising a small TCP MSS from VPS:443.
#
# Why:
#   Current DPI identifies the official Telegram MTProxy Fake-TLS client-side
#   packet pattern. This patch changes packetization without WARP/Cascade.
#
# Usage:
#   sudo bash ./telemt-antidpi-mss-v1.0.sh apply
#   sudo bash ./telemt-antidpi-mss-v1.0.sh status
#   sudo bash ./telemt-antidpi-mss-v1.0.sh remove
#
# Optional:
#   PORT=443 MSS=88 sudo -E bash ./telemt-antidpi-mss-v1.0.sh apply
#
# Notes:
#   - New TCP sessions only. Existing Telegram connection attempts must be retried.
#   - MSS=88 is intentionally aggressive for the first DPI-bypass test.
#   - The rule affects only SYN/SYN-ACK packets sourced from Telemt's public port.
#   - Telemt config, secret, Direct routing and service binary are not modified.

set -Eeuo pipefail
umask 077

readonly VERSION="1.0"
readonly PATCH_NAME="telemt-antidpi-mss"
readonly HELPER="/usr/local/sbin/${PATCH_NAME}"
readonly UNIT="/etc/systemd/system/${PATCH_NAME}.service"
readonly BACKUP_ROOT="/var/backups/${PATCH_NAME}"
readonly LOG="/var/log/${PATCH_NAME}.log"
readonly SERVICE="telemt"

ACTION="${1:-apply}"
PORT="${PORT:-443}"
MSS="${MSS:-88}"
BACKUP_DIR=""

mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1

info() { printf '\033[1;36m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "Запустите через sudo/root."
}

validate_input() {
  [[ "$ACTION" =~ ^(apply|status|remove)$ ]] || fail "Действие: apply | status | remove"
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) ||
    fail "PORT должен быть в диапазоне 1..65535."
  [[ "$MSS" =~ ^[0-9]+$ ]] && (( MSS >= 64 && MSS <= 1460 )) ||
    fail "MSS должен быть в диапазоне 64..1460."
}

apt_install_iptables_if_needed() {
  command -v iptables >/dev/null 2>&1 && return 0
  info "Устанавливаю iptables с безопасным ожиданием apt/dpkg lock."
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=600 update -y
  apt-get -o DPkg::Lock::Timeout=600 install -y --no-install-recommends iptables
}

backup_previous_patch() {
  BACKUP_DIR="${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$BACKUP_DIR"
  [[ -f "$HELPER" ]] && cp -a "$HELPER" "$BACKUP_DIR/"
  [[ -f "$UNIT" ]] && cp -a "$UNIT" "$BACKUP_DIR/"
}

write_helper() {
  cat > "$HELPER" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

PORT="\${PORT:-${PORT}}"
MSS="\${MSS:-${MSS}}"
CHAIN="TELEMT_ANTIDPI_MSS"

iptables_cmd() {
  command -v iptables >/dev/null 2>&1 && command -v iptables
}
ip6tables_cmd() {
  command -v ip6tables >/dev/null 2>&1 && command -v ip6tables || true
}

apply_family() {
  local cmd="\$1"
  "\$cmd" -w 10 -t mangle -N "\$CHAIN" 2>/dev/null || true
  "\$cmd" -w 10 -t mangle -F "\$CHAIN"
  "\$cmd" -w 10 -t mangle -A "\$CHAIN" \
    -p tcp --sport "\$PORT" --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss "\$MSS"
  "\$cmd" -w 10 -t mangle -C OUTPUT -j "\$CHAIN" >/dev/null 2>&1 ||
    "\$cmd" -w 10 -t mangle -I OUTPUT 1 -j "\$CHAIN"
}

remove_family() {
  local cmd="\$1"
  while "\$cmd" -w 10 -t mangle -C OUTPUT -j "\$CHAIN" >/dev/null 2>&1; do
    "\$cmd" -w 10 -t mangle -D OUTPUT -j "\$CHAIN"
  done
  "\$cmd" -w 10 -t mangle -F "\$CHAIN" >/dev/null 2>&1 || true
  "\$cmd" -w 10 -t mangle -X "\$CHAIN" >/dev/null 2>&1 || true
}

show_family() {
  local label="\$1" cmd="\$2"
  printf '\n--- %s ---\n' "\$label"
  "\$cmd" -w 10 -t mangle -L "\$CHAIN" -n -v --line-numbers 2>&1 || echo "rule absent"
}

case "\${1:-apply}" in
  apply)
    IPT="\$(iptables_cmd)"
    apply_family "\$IPT"
    IP6T="\$(ip6tables_cmd)"
    [[ -n "\$IP6T" ]] && apply_family "\$IP6T" || true
    ;;
  remove)
    IPT="\$(iptables_cmd)"
    remove_family "\$IPT"
    IP6T="\$(ip6tables_cmd)"
    [[ -n "\$IP6T" ]] && remove_family "\$IP6T" || true
    ;;
  status)
    IPT="\$(iptables_cmd)"
    show_family "IPv4 OUTPUT / TCPMSS" "\$IPT"
    IP6T="\$(ip6tables_cmd)"
    [[ -n "\$IP6T" ]] && show_family "IPv6 OUTPUT / TCPMSS" "\$IP6T" || true
    ;;
  *)
    echo "Usage: \$0 apply|remove|status" >&2
    exit 2
    ;;
esac
EOF
  chmod 0755 "$HELPER"
}

write_unit() {
  cat > "$UNIT" <<EOF
[Unit]
Description=Telemt inbound anti-DPI TCPMSS fragmentation (TCP/${PORT}, MSS=${MSS})
After=network-pre.target
Before=telemt.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=${HELPER} apply
ExecStop=${HELPER} remove
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$UNIT"
  systemctl daemon-reload
}

show_status() {
  printf '\n===== Telemt inbound anti-DPI MSS status =====\n'
  systemctl status "$PATCH_NAME.service" --no-pager -l 2>&1 || true
  [[ -x "$HELPER" ]] && "$HELPER" status || warn "Helper ещё не установлен."
  printf '\nTelemt listener:\n'
  ss -H -ltnp "sport = :${PORT}" 2>/dev/null || true
  printf '\nПоследние handshake-события:\n'
  journalctl -u "$SERVICE" --no-pager -n 80 2>/dev/null |
    grep -Ei 'handshake|connection|unknown sni|Listening|direct|DC[0-9]' || true
}

apply_patch() {
  apt_install_iptables_if_needed

  systemctl is-active --quiet "$SERVICE" ||
    warn "telemt сейчас не active; правило установится, но проверка соединения возможна после запуска telemt."

  if ! ss -H -ltn "sport = :${PORT}" 2>/dev/null | grep -q ":${PORT}"; then
    warn "Listener TCP/${PORT} сейчас не найден. Проверь, что Telemt слушает этот порт."
  fi

  backup_previous_patch
  write_helper
  write_unit

  systemctl enable "$PATCH_NAME.service" >/dev/null
  systemctl restart "$PATCH_NAME.service"

  ok "Включён входной DPI-bypass: TCPMSS=${MSS} для новых соединений к Telemt TCP/${PORT}."
  info "Маршрут Telemt → Telegram DC, конфиг и secret не менялись."
  info "Backup предыдущей версии patch: ${BACKUP_DIR}"
  show_status

  printf '\nПРОВЕРКА СЕЙЧАС:\n'
  printf '1) На телефоне выключи WARP.\n'
  printf '2) Отключи/включи этот же MTProxy в Telegram, чтобы создать новый TCP-сеанс.\n'
  printf '3) Через 10 секунд выполни:\n'
  printf '   sudo bash %s status\n' "$0"
  printf '\nВ status у правила TCPMSS счётчик pkts должен стать > 0.\n'
}

remove_patch() {
  if [[ -x "$HELPER" ]]; then
    "$HELPER" remove || true
  fi
  systemctl disable --now "$PATCH_NAME.service" >/dev/null 2>&1 || true
  rm -f "$UNIT" "$HELPER"
  systemctl daemon-reload
  ok "Anti-DPI TCPMSS patch полностью удалён. Telemt/config не изменялись."
}

main() {
  require_root
  validate_input
  case "$ACTION" in
    apply) apply_patch ;;
    status) show_status ;;
    remove) remove_patch ;;
  esac
}

main "$@"
