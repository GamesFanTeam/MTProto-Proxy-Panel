#!/usr/bin/env bash
# Teleproxy Direct + Fake-TLS DPI-hardening A/B test installer
# Version: 0.2-test — adds explicit post-test restore
#
# Goal:
#   Replace the Telemt inbound engine for an isolated no-WARP client test,
#   while preserving server egress as Direct -> Telegram DC.
#
# Engine under test:
#   Teleproxy v4.14.1 (pinned), direct=true, Fake-TLS domain=mts.ru.
#
# Notes:
#   - This is an A/B migration test, not a guarantee against every network.
#   - It backs up and stops an existing Telemt installation occupying :443.
#   - It disables/removes the previous standalone TCPMSS patch before testing,
#     because Teleproxy v4.14.1 ships automatic ClientHello fragmentation.
#   - On any install/health failure, it attempts to restore the previous Telemt state.
#
# Run:
#   sudo bash ./mtproto-teleproxy-direct-dpi-test-v0.2.sh
#
# Optional:
#   DOMAIN=ya.ru sudo -E bash ./mtproto-teleproxy-direct-dpi-test-v0.2.sh
#
# Roll back after a failed no-WARP connection test:
#   sudo bash ./mtproto-teleproxy-direct-dpi-test-v0.2.sh restore
#   sudo bash ./mtproto-teleproxy-direct-dpi-test-v0.2.sh restore /var/backups/teleproxy-direct-dpi-test/<timestamp>

set -Eeuo pipefail
umask 077

readonly SCRIPT_VERSION="0.2-test"
readonly TELEPROXY_VERSION="4.14.1"
readonly PORT="${PORT:-443}"
readonly STATS_PORT="${STATS_PORT:-8888}"
readonly DOMAIN="${DOMAIN:-mts.ru}"
readonly SECRET="${SECRET:-$(openssl rand -hex 16)}"
readonly INSTALLER_URL="https://raw.githubusercontent.com/teleproxy/teleproxy/v${TELEPROXY_VERSION}/install.sh"
readonly BACKUP_ROOT="/var/backups/teleproxy-direct-dpi-test"
readonly LOG_FILE="/var/log/teleproxy-direct-dpi-test.log"
readonly LINK_FILE="/root/teleproxy-direct-dpi-test-link.txt"
readonly TELEMT_SERVICE="/etc/systemd/system/telemt.service"
readonly TELEMT_CONFIG_DIR="/etc/telemt"
readonly TELEMT_BINARY="/usr/local/bin/telemt"
readonly OLD_DPI_SERVICE="/etc/systemd/system/telemt-antidpi-mss.service"
readonly OLD_DPI_HELPER="/usr/local/sbin/telemt-antidpi-mss"
readonly TELEPROXY_SERVICE="/etc/systemd/system/teleproxy.service"
readonly TELEPROXY_CONFIG_DIR="/etc/teleproxy"
readonly TELEPROXY_BINARY="/usr/local/bin/teleproxy"

ACTION="${1:-install}"
RESTORE_DIR="${2:-}"

BACKUP_DIR=""
TELEMT_WAS_ACTIVE=0
OLD_DPI_WAS_ACTIVE=0
TELEPROXY_WAS_ACTIVE=0
MUTATED=0
COMMITTED=0

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

info() { printf '\033[1;36m[INFO]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; return 1; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "Запусти от root: sudo bash $0"
}

validate_inputs() {
  [[ "$ACTION" == "install" || "$ACTION" == "restore" ]] ||
    fail "Команда: install или restore."
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) ||
    fail "PORT должен быть в диапазоне 1..65535."
  [[ "$STATS_PORT" =~ ^[0-9]+$ ]] && (( STATS_PORT >= 1 && STATS_PORT <= 65535 )) ||
    fail "STATS_PORT должен быть в диапазоне 1..65535."
  [[ "$SECRET" =~ ^[0-9a-fA-F]{32}$ ]] ||
    fail "SECRET должен быть 32-символьным HEX secret."
  [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] ||
    fail "DOMAIN содержит недопустимые символы."
}

backup_file_or_dir() {
  local source="$1" target_name="$2"
  [[ -e "$source" ]] && cp -a "$source" "$BACKUP_DIR/$target_name"
}

backup_existing_state() {
  BACKUP_DIR="${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$BACKUP_DIR"

  systemctl is-active --quiet telemt 2>/dev/null && TELEMT_WAS_ACTIVE=1 || true
  systemctl is-active --quiet telemt-antidpi-mss.service 2>/dev/null && OLD_DPI_WAS_ACTIVE=1 || true
  systemctl is-active --quiet teleproxy 2>/dev/null && TELEPROXY_WAS_ACTIVE=1 || true

  backup_file_or_dir "$TELEMT_CONFIG_DIR" "telemt-config"
  backup_file_or_dir "$TELEMT_SERVICE" "telemt.service"
  backup_file_or_dir "$TELEMT_BINARY" "telemt.binary"
  backup_file_or_dir "$OLD_DPI_SERVICE" "telemt-antidpi-mss.service"
  backup_file_or_dir "$OLD_DPI_HELPER" "telemt-antidpi-mss.helper"
  backup_file_or_dir "$TELEPROXY_CONFIG_DIR" "teleproxy-config"
  backup_file_or_dir "$TELEPROXY_SERVICE" "teleproxy.service"
  backup_file_or_dir "$TELEPROXY_BINARY" "teleproxy.binary"

  cat > "$BACKUP_DIR/state.env" <<EOF
TELEMT_WAS_ACTIVE=${TELEMT_WAS_ACTIVE}
OLD_DPI_WAS_ACTIVE=${OLD_DPI_WAS_ACTIVE}
TELEPROXY_WAS_ACTIVE=${TELEPROXY_WAS_ACTIVE}
EOF
  chmod 600 "$BACKUP_DIR/state.env"
  ok "Backup создан: $BACKUP_DIR"
}

remove_old_antidpi_rule() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^telemt-antidpi-mss.service'; then
    systemctl disable --now telemt-antidpi-mss.service >/dev/null 2>&1 || true
  fi
  if [[ -x "$OLD_DPI_HELPER" ]]; then
    "$OLD_DPI_HELPER" remove >/dev/null 2>&1 || true
  fi
  info "Старый внешний TCPMSS patch отключён для чистого A/B-теста."
}

restore_from_backup() {
  if [[ -n "$RESTORE_DIR" ]]; then
    BACKUP_DIR="$RESTORE_DIR"
  else
    BACKUP_DIR="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 {print $2}')"
  fi
  [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" && -f "$BACKUP_DIR/state.env" ]] ||
    fail "Backup для восстановления не найден. Укажи каталог вторым аргументом."

  # shellcheck source=/dev/null
  source "$BACKUP_DIR/state.env"

  info "Возвращаю состояние из backup: $BACKUP_DIR"
  systemctl disable --now teleproxy >/dev/null 2>&1 || true
  rm -rf "$TELEPROXY_CONFIG_DIR"
  rm -f "$TELEPROXY_SERVICE" "$TELEPROXY_BINARY"

  if [[ -d "$BACKUP_DIR/teleproxy-config" ]]; then
    cp -a "$BACKUP_DIR/teleproxy-config" "$TELEPROXY_CONFIG_DIR"
  fi
  [[ -f "$BACKUP_DIR/teleproxy.service" ]] && cp -a "$BACKUP_DIR/teleproxy.service" "$TELEPROXY_SERVICE"
  [[ -f "$BACKUP_DIR/teleproxy.binary" ]] && cp -a "$BACKUP_DIR/teleproxy.binary" "$TELEPROXY_BINARY"

  if [[ -d "$BACKUP_DIR/telemt-config" ]]; then
    rm -rf "$TELEMT_CONFIG_DIR"
    cp -a "$BACKUP_DIR/telemt-config" "$TELEMT_CONFIG_DIR"
  fi
  [[ -f "$BACKUP_DIR/telemt.service" ]] && cp -a "$BACKUP_DIR/telemt.service" "$TELEMT_SERVICE"
  [[ -f "$BACKUP_DIR/telemt.binary" ]] && cp -a "$BACKUP_DIR/telemt.binary" "$TELEMT_BINARY"

  rm -f "$OLD_DPI_SERVICE" "$OLD_DPI_HELPER"
  [[ -f "$BACKUP_DIR/telemt-antidpi-mss.service" ]] && cp -a "$BACKUP_DIR/telemt-antidpi-mss.service" "$OLD_DPI_SERVICE"
  [[ -f "$BACKUP_DIR/telemt-antidpi-mss.helper" ]] && cp -a "$BACKUP_DIR/telemt-antidpi-mss.helper" "$OLD_DPI_HELPER"

  systemctl daemon-reload
  if [[ "${TELEMT_WAS_ACTIVE:-0}" == "1" ]]; then
    systemctl enable --now telemt >/dev/null
  fi
  if [[ "${OLD_DPI_WAS_ACTIVE:-0}" == "1" && -f "$OLD_DPI_SERVICE" ]]; then
    systemctl enable --now telemt-antidpi-mss.service >/dev/null || true
  fi
  if [[ "${TELEPROXY_WAS_ACTIVE:-0}" == "1" && -f "$TELEPROXY_SERVICE" ]]; then
    systemctl enable --now teleproxy >/dev/null || true
  fi

  ok "Восстановление завершено."
  systemctl status telemt --no-pager -l 2>/dev/null || true
}

restore_previous_state() {
  (( MUTATED == 1 && COMMITTED == 0 )) || return 0
  warn "Ошибка тестовой миграции: откатываю состояние до Teleproxy-теста."

  systemctl disable --now teleproxy >/dev/null 2>&1 || true
  rm -rf "$TELEPROXY_CONFIG_DIR"
  rm -f "$TELEPROXY_SERVICE" "$TELEPROXY_BINARY"

  if [[ -d "$BACKUP_DIR/teleproxy-config" ]]; then
    cp -a "$BACKUP_DIR/teleproxy-config" "$TELEPROXY_CONFIG_DIR"
  fi
  [[ -f "$BACKUP_DIR/teleproxy.service" ]] && cp -a "$BACKUP_DIR/teleproxy.service" "$TELEPROXY_SERVICE"
  [[ -f "$BACKUP_DIR/teleproxy.binary" ]] && cp -a "$BACKUP_DIR/teleproxy.binary" "$TELEPROXY_BINARY"

  if [[ -d "$BACKUP_DIR/telemt-config" ]]; then
    rm -rf "$TELEMT_CONFIG_DIR"
    cp -a "$BACKUP_DIR/telemt-config" "$TELEMT_CONFIG_DIR"
  fi
  [[ -f "$BACKUP_DIR/telemt.service" ]] && cp -a "$BACKUP_DIR/telemt.service" "$TELEMT_SERVICE"
  [[ -f "$BACKUP_DIR/telemt.binary" ]] && cp -a "$BACKUP_DIR/telemt.binary" "$TELEMT_BINARY"

  [[ -f "$BACKUP_DIR/telemt-antidpi-mss.service" ]] && cp -a "$BACKUP_DIR/telemt-antidpi-mss.service" "$OLD_DPI_SERVICE"
  [[ -f "$BACKUP_DIR/telemt-antidpi-mss.helper" ]] && cp -a "$BACKUP_DIR/telemt-antidpi-mss.helper" "$OLD_DPI_HELPER"

  systemctl daemon-reload >/dev/null 2>&1 || true
  if (( TELEMT_WAS_ACTIVE == 1 )); then
    systemctl enable telemt >/dev/null 2>&1 || true
    systemctl restart telemt >/dev/null 2>&1 || true
  fi
  if (( OLD_DPI_WAS_ACTIVE == 1 )); then
    systemctl enable --now telemt-antidpi-mss.service >/dev/null 2>&1 || true
  fi
  warn "Откат завершён. Backup: $BACKUP_DIR"
}

on_error() {
  local exit_code=$?
  printf '\033[1;31m[FAIL]\033[0m Ошибка на строке %s: %s\n' "${1:-?}" "${2:-unknown}" >&2
  printf 'Лог: %s\n' "$LOG_FILE" >&2
  restore_previous_state
  exit "$exit_code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

stop_conflicting_services() {
  remove_old_antidpi_rule
  systemctl disable --now telemt >/dev/null 2>&1 || true
  systemctl disable --now teleproxy >/dev/null 2>&1 || true
  sleep 1

  local occupied
  occupied="$(ss -H -ltnp "sport = :${PORT}" 2>/dev/null || true)"
  [[ -z "$occupied" ]] || {
    printf '%s\n' "$occupied" >&2
    fail "TCP/${PORT} после остановки telemt/teleproxy занят другим процессом."
  }
}

install_teleproxy_from_official_installer() {
  local installer
  installer="$(mktemp /tmp/teleproxy-install.XXXXXX.sh)"
  curl -fL --retry 3 --connect-timeout 15 --max-time 60 -o "$installer" "$INSTALLER_URL"
  grep -q 'GITHUB_REPO="teleproxy/teleproxy"' "$installer" ||
    fail "Загруженный installer Teleproxy не прошёл минимальную проверку происхождения."

  # Do not let official installer retain an older trial config.
  rm -rf "$TELEPROXY_CONFIG_DIR"

  info "Устанавливаю закреплённый Teleproxy v${TELEPROXY_VERSION}, Direct, Fake-TLS domain=${DOMAIN}."
  env \
    PORT="$PORT" \
    STATS_PORT="$STATS_PORT" \
    EE_DOMAIN="$DOMAIN" \
    SECRET="$SECRET" \
    TELEPROXY_VERSION="$TELEPROXY_VERSION" \
    sh "$installer"
  rm -f "$installer"
}

verify_teleproxy() {
  systemctl is-active --quiet teleproxy ||
    fail "teleproxy.service не active после установки."

  ss -H -ltnp "sport = :${PORT}" 2>/dev/null | grep -q ":${PORT}" ||
    fail "Teleproxy не слушает TCP/${PORT}."

  [[ -f "$TELEPROXY_CONFIG_DIR/config.toml" ]] ||
    fail "Не создан конфиг Teleproxy."

  grep -Eq '^direct[[:space:]]*=[[:space:]]*true' "$TELEPROXY_CONFIG_DIR/config.toml" ||
    fail "В конфиге Teleproxy отсутствует direct=true."
  grep -Eq "^domain[[:space:]]*=[[:space:]]*\"${DOMAIN}\"" "$TELEPROXY_CONFIG_DIR/config.toml" ||
    fail "В конфиге Teleproxy отсутствует Fake-TLS domain=${DOMAIN}."

  ok "Teleproxy active: Direct-to-DC + Fake-TLS ${DOMAIN} на TCP/${PORT}."
  info "Teleproxy v4.14.1 включает automatic ClientHello fragmentation по умолчанию; отдельное старое TCPMSS-правило не используется."
}

hex_encode() {
  printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}

public_ipv4() {
  curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org | tr -d '[:space:]'
}

save_link() {
  local ip tls_secret link
  ip="$(public_ipv4)"
  tls_secret="ee${SECRET,,}$(hex_encode "$DOMAIN")"
  link="tg://proxy?server=${ip}&port=${PORT}&secret=${tls_secret}"

  cat > "$LINK_FILE" <<EOF
Teleproxy v${TELEPROXY_VERSION} — Direct-to-DC Fake-TLS DPI-hardening test
Server: ${ip}
Port: ${PORT}
Domain: ${DOMAIN}
Direct: true
Link:
${link}
EOF
  chmod 600 "$LINK_FILE"

  printf '\n====================================================================\n'
  printf ' TELEPROXY DIRECT DPI-HARDENING A/B TEST УСТАНОВЛЕН\n'
  printf '====================================================================\n'
  printf 'Engine:   Teleproxy v%s (pinned)\n' "$TELEPROXY_VERSION"
  printf 'Route:    Client -> Teleproxy -> Telegram DC (Direct)\n'
  printf 'Fake-TLS: %s\n' "$DOMAIN"
  printf 'Link:\n%s\n\n' "$link"
  printf 'Saved:    %s\n' "$LINK_FILE"
  printf 'Logs:     journalctl -u teleproxy -n 150 --no-pager\n'
  printf 'Config:   %s/config.toml\n' "$TELEPROXY_CONFIG_DIR"
  printf 'Backup:   %s\n' "$BACKUP_DIR"
  printf '\nЭто A/B-тест другого входного движка. Выключи WARP на клиенте,\n'
  printf 'удали старую MTProxy-запись и подключи именно новую ссылку.\n'
  printf '====================================================================\n'
}

main() {
  require_root
  validate_inputs

  if [[ "$ACTION" == "restore" ]]; then
    restore_from_backup
    return 0
  fi

  command -v curl >/dev/null 2>&1 || fail "Нужен curl."
  command -v ss >/dev/null 2>&1 || fail "Нужен ss (iproute2)."
  command -v openssl >/dev/null 2>&1 || fail "Нужен openssl для генерации secret."

  backup_existing_state
  MUTATED=1
  stop_conflicting_services
  install_teleproxy_from_official_installer
  verify_teleproxy
  save_link
  COMMITTED=1
}

main "$@"
