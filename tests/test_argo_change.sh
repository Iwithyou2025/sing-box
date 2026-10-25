#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source <(sed -n '/^argo_current_type() {/,/^check_root() {/p' sing-box.sh | sed '$d')
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
text() { [ "$1" = 26 ] && echo 'Not installed' || echo "$1"; }
hint() { :; }
warning() { printf 'warning: %s\n' "$*" >&2; }
info() { :; }
check_install() { :; }
reading() {
  local value=''
  case "$2" in
    OPTION) value="${SELECT:-y}" ;;
    NEW_AUTH) value="${CREDS:-}" ;;
    NEW_DOMAIN) value="${DOMAIN:-}" ;;
    *) return 77 ;;
  esac
  printf -v "$2" '%s' "$value"
}
systemctl() {
  printf 'systemctl %s\n' "$*" >> "$EVENTS"
  case "$*" in
    'is-active --quiet argo-monitor.service') return 1 ;;
    *) return 0 ;;
  esac
}
cmd_systemctl() {
  printf 'cmd %s\n' "$*" >> "$EVENTS"
  if [ "$1" = status ]; then [ "${ACTIVE:-1}" = 1 ]; return; fi
  if [ "$1" = restart ] && [ "${FAIL_RESTART:-0}" = 1 ]; then
    FAIL_RESTART=0
    return 1
  fi
}
argo_monitor_wait_domain() { echo 'new.trycloudflare.com'; }
argo_monitor_publish_domain() { printf 'publish %s\n' "$1" >> "$EVENTS"; }
export_list() { echo 'export' >> "$EVENTS"; }
reset_case() {
  WORK_DIR=$(mktemp -d "$ROOT/case.XXXXXX")
  ARGO_DAEMON_FILE="$WORK_DIR/argo.service"
  EVENTS="$WORK_DIR/events"
  : > "$EVENTS"
  STATUS=('running' 'running') SYSTEM=Ubuntu PORT_NGINX=8080 ACTIVE=1
  SELECT=y CREDS='' DOMAIN='' FAIL_RESTART=0
  ln -s "$(command -v jq)" "$WORK_DIR/jq"
}
# Auto-detect by command, unknown types must be rejected.
reset_case
printf 'ExecStart=/etc/sing-box/cloudflared tunnel --url http://localhost:8080\n' > "$ARGO_DAEMON_FILE"
[ "$(argo_current_type)" = Try ]
change_argo
grep -qx 'cmd restart argo' "$EVENTS"
grep -qx 'publish new.trycloudflare.com' "$EVENTS"
! grep -q 'enable argo\|disable argo' "$EVENTS"
reset_case
printf 'ExecStart=/etc/sing-box/cloudflared tunnel --config /etc/sing-box/tunnel.yml run\n' > "$ARGO_DAEMON_FILE"
[ "$(argo_current_type)" = Json ]
reset_case
printf 'ExecStart=/etc/sing-box/cloudflared tunnel --token old\n' > "$ARGO_DAEMON_FILE"
[ "$(argo_current_type)" = Token ]
SELECT=1
change_argo
grep -qx 'cmd restart argo' "$EVENTS"
! grep -q '^export$' "$EVENTS"
reset_case
printf 'ExecStart=unrecognized\n' > "$ARGO_DAEMON_FILE"
if change_argo; then echo 'unknown type incorrectly accepted' >&2; exit 1; fi
[ ! -s "$EVENTS" ]
# Invalid token must be rejected before touching the unit.
reset_case
printf 'ExecStart=/etc/sing-box/cloudflared tunnel --token old\n' > "$ARGO_DAEMON_FILE"
SELECT=2 CREDS=bad
if change_argo; then echo 'invalid token accepted' >&2; exit 1; fi
grep -q '^ExecStart=.*--token old$' "$ARGO_DAEMON_FILE"
[ ! -s "$EVENTS" ]
echo 'PASS: Argo type detection, Try rebuild, fixed reconnection, unknown mode, invalid credentials'
