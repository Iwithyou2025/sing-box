#!/usr/bin/env bash
# Isolated Argo and monitor toggle regression; no real systemd changes.
set -euo pipefail
cd "$(dirname "$0")/.."
source <(sed -n \
  -e '/^argo_monitor_pause() {/,/^}/p' \
  -e '/^argo_toggle_service() {/,/^}/p' sing-box.sh)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
WORK_DIR="$ROOT"
SYSTEM=Ubuntu
ARGO_DAEMON_FILE="$ROOT/argo.service"
mkdir -p "$ROOT"
printf 'retain this hostname\n' > "$ROOT/argo-domain"
printf 'retain this subscription\n' > "$ROOT/subscription"
MONITOR_FILE=/etc/systemd/system/argo-monitor.service
# Only testing in isolation: replace service file existence with a mock -s function
# by using Alpine path and a mock installed init file would require root.
# Instead test the pure helper with a temporary unit via a file-existence stub.
test_file() { :; }
cmd_systemctl() {
  case "$1:$2" in
    disable:argo-monitor) echo monitor-off >> "$ROOT/events";;
    disable:argo) echo argo-off >> "$ROOT/events";;
    enable:argo) echo argo-on >> "$ROOT/events";;
    status:argo) [ -f "$ROOT/argo-enabled" ]; return $?;;
    *) return 1;;
  esac
  case "$1:$2" in
    disable:argo) rm -f "$ROOT/argo-enabled";;
    enable:argo) touch "$ROOT/argo-enabled";;
  esac
}
argo_monitor_pause() { echo monitor-off >> "$ROOT/events"; }
argo_monitor_sync() { echo monitor-on >> "$ROOT/events"; }
fetch_quicktunnel_domain() { echo domain-refresh >> "$ROOT/events"; }
export_list() { echo subscription-refresh >> "$ROOT/events"; }

touch "$ROOT/argo-enabled"
printf 'ExecStart=/etc/sing-box/cloudflared tunnel --url http://localhost:9000\n' > "$ARGO_DAEMON_FILE"
argo_toggle_service off
[ "$(cat "$ROOT/events")" = "$(printf 'monitor-off\nargo-off')" ]
[ ! -f "$ROOT/argo-enabled" ]
[ "$(cat "$ROOT/argo-domain")" = 'retain this hostname' ]
[ "$(cat "$ROOT/subscription")" = 'retain this subscription' ]
: > "$ROOT/events"
argo_toggle_service on
[ "$(cat "$ROOT/events")" = "$(printf 'argo-on\nmonitor-on\ndomain-refresh\nsubscription-refresh')" ]
: > "$ROOT/events"
echo 'ExecStart=/etc/sing-box/cloudflared tunnel --token dummy' > "$ARGO_DAEMON_FILE"
argo_toggle_service off
argo_toggle_service on
! grep -q 'monitor-on' "$ROOT/events"
[ "$(cat "$ROOT/argo-domain")" = 'retain this hostname' ]
# Both entry points must call the shared helper, not manipulate Argo separately.
[ "$(grep -c 'argo_toggle_service off &&' sing-box.sh)" -eq 2 ]
[ "$(grep -c 'argo_toggle_service on &&' sing-box.sh)" -eq 2 ]
grep -q 'systemctl is-enabled --quiet argo.service || { argo_monitor_pause; return \$?; }' sing-box.sh
echo 'PASS: Argo/menu -a toggle and Quick Tunnel monitor linkage'
