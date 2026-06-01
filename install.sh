#!/usr/bin/env bash
# Telemt Direct Telegram DC probe
# Version: 1.0
# Purpose: collect evidence for Direct egress failures without changing Telemt/WARP/config.

set -uo pipefail

readonly OUT="/root/telemt-direct-dc-probe-$(date -u +%Y%m%dT%H%M%SZ).log"
readonly CONFIG="/etc/telemt/telemt.toml"
readonly API="http://127.0.0.1:9091"
readonly -a DC4_ENDPOINTS=(
  "149.154.175.50:443:DC1"
  "149.154.167.51:443:DC2"
  "149.154.175.100:443:DC3"
  "149.154.167.91:443:DC4"
  "149.154.171.5:443:DC5"
  "91.105.192.100:443:DC203"
)
readonly -a DC6_ENDPOINTS=(
  "[2001:b28:f23d:f001::a]:443:DC1"
  "[2001:67c:4e8:f002::a]:443:DC2"
  "[2001:b28:f23d:f003::a]:443:DC3"
  "[2001:67c:4e8:f004::a]:443:DC4"
  "[2001:b28:f23f:f005::a]:443:DC5"
)

exec > >(tee "$OUT") 2>&1

header() { printf '\n===== %s =====\n' "$*"; }
run() {
  printf '\n$ %s\n' "$*"
  "$@" 2>&1 || true
}

tcp_probe() {
  local host="$1" port="$2" name="$3" family="$4" start end elapsed
  start="$(date +%s%3N)"
  if [[ "$family" == "4" ]]; then
    if timeout 4 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
      end="$(date +%s%3N)"; elapsed=$((end - start))
      printf '%-5s IPv4 %-25s OK   %4s ms\n' "$name" "${host}:${port}" "$elapsed"
    else
      printf '%-5s IPv4 %-25s FAIL timeout/refused\n' "$name" "${host}:${port}"
    fi
  else
    # curl connect-only is used for IPv6 parsing; HTTP response is irrelevant.
    if timeout 5 curl -6 -ksS --connect-timeout 4 --max-time 4 "https://[${host}]:${port}/" -o /dev/null 2>/dev/null; then
      end="$(date +%s%3N)"; elapsed=$((end - start))
      printf '%-5s IPv6 %-39s OK   %4s ms\n' "$name" "[${host}]:${port}" "$elapsed"
    else
      printf '%-5s IPv6 %-39s FAIL timeout/unreachable\n' "$name" "[${host}]:${port}"
    fi
  fi
}

redacted_config() {
  if [[ ! -f "$CONFIG" ]]; then
    echo "Config not found: $CONFIG"
    return
  fi
  sed -E \
    -e 's/^([[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=[[:space:]]*")[0-9a-fA-F]{32}(".*)$/\1<REDACTED_32HEX>\2/' \
    -e 's/^([[:space:]]*ad_tag[[:space:]]*=[[:space:]]*").*(".*)$/\1<REDACTED>\2/' \
    "$CONFIG"
}

header "Telemt Direct DC probe v1.0"
echo "Generated UTC: $(date -u --iso-8601=seconds)"
echo "IMPORTANT: run this while WARP/Cascade/VPN egress is OFF."

header "Public/network identity"
run uname -a
run ip -br addr
run ip -4 route
run ip -6 route
printf '\n$ curl public IPv4/IPv6\n'
curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo "IPv4 public IP unavailable"
printf '\n'
curl -6fsS --max-time 8 https://api64.ipify.org 2>/dev/null || echo "IPv6 public IP unavailable"
printf '\n'

header "WARP/WireGuard indicators"
run systemctl is-active warp-svc
run systemctl is-active wg-quick@wgcf
run systemctl is-active wg-quick@warp
run wg show
run ip rule show

header "Telemt unit/listeners"
run systemctl status telemt --no-pager -l
run ss -ltnp
run ss -lunp

header "Telemt config, secrets redacted"
redacted_config

header "Telemt local API with HTTP status"
for endpoint in \
  /v1/health/ready \
  /v1/runtime/gates \
  /v1/runtime/upstream_quality \
  /v1/stats/upstreams \
  /v1/users; do
  printf '\n--- %s ---\n' "$endpoint"
  curl -sS -i --connect-timeout 2 --max-time 5 "${API}${endpoint}" 2>&1 || true
  printf '\n'
done

header "Direct TCP probes to Telegram DC IPv4 :443"
for item in "${DC4_ENDPOINTS[@]}"; do
  IFS=: read -r host port name <<< "$item"
  tcp_probe "$host" "$port" "$name" 4
done

header "Direct TCP probes to Telegram DC IPv6 :443"
if ip -6 route show default 2>/dev/null | grep -q default; then
  for item in "${DC6_ENDPOINTS[@]}"; do
    tmp="${item#[}"; host="${tmp%%]*}"
    rest="${tmp#*]:}"; port="${rest%%:*}"; name="${rest##*:}"
    tcp_probe "$host" "$port" "$name" 6
  done
else
  echo "IPv6 default route absent; IPv6 direct fallback cannot be tested."
fi

header "Telemt connectivity/upstream logs"
journalctl -u telemt --no-pager -n 500 2>&1 | \
  grep -Ei 'Telegram DC Connectivity|via direct|DC[0-9]|upstream|connectivity|healthy|FAIL|timeout|Transport|Network capabilities|route|error|warn' || true

header "Saved"
echo "$OUT"
echo
echo "Send this log back for an exact Direct-only correction."
