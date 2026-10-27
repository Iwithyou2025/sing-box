#!/usr/bin/env bash
# Test Argo user toggle / monitor lifecycle without modifying real services.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
WORK_DIR="$ROOT/work"
mkdir -p "$WORK_DIR/conf"
ARGO_DAEMON_FILE="$WORK_DIR/argo.service"
printf 'ExecStart=/tmp/cloudflared tunnel --url http://localhost:8080\n' > "$ARGO_DAEMON_FILE"
printf '#!/bin/sh\nexit 0\n' > "$WORK_DIR/sb.sh"
chmod +x "$WORK_DIR/sb.sh"
printf 'saved.trycloudflare.com\n' > "$WORK_DIR/argo-domain"
printf 'saved subscription\n' > "$WORK_DIR/conf/keep"
printf '5\n' > "$WORK_DIR/argo-monitor.attempts"
printf '1000\n' > "$WORK_DIR/argo-monitor.last"

# Load project functions with monitor unit paths redirected to this sandbox.
sed -n '/^argo_monitor_pause() {/,/^argo_monitor_live_domain() {/p' sing-box.sh | sed '$d' |
  sed -e "s|/etc/systemd/system/argo-monitor.service|$ROOT/argo-monitor.service|g" \
      -e "s|/etc/init.d/argo-monitor|$ROOT/argo-monitor.init|g" > "$ROOT/functions.sh"
source "$ROOT/functions.sh"
SYSTEM=Ubuntu
printf '[Unit]\n' > "$ROOT/argo-monitor.service"

record() { printf '%s\n' "$*" >> "$ROOT/actions"; }
systemctl() {
  case "$*" in
    'is-enabled --quiet argo.service') test -e "$ROOT/argo-enabled" ;;
    'is-active --quiet argo.service') test -e "$ROOT/argo-active" ;;
    'is-enabled --quiet argo-monitor.service') test -e "$ROOT/monitor-enabled" ;;
    'is-active --quiet argo-monitor.service') test -e "$ROOT/monitor-active" ;;
    'disable --now argo-monitor.service')
      record "monitor-stop"
      rm -f "$ROOT/monitor-enabled" "$ROOT/monitor-active" ;;
    'enable --now argo-monitor.service')
      record "monitor-start"
      [ ! -e "$ROOT/monitor-start-fail" ] || return 1
      touch "$ROOT/monitor-enabled" "$ROOT/monitor-active" ;;
    'daemon-reload') record "daemon-reload" ;;
    *) echo "unexpected systemctl: $*" >&2; return 10 ;;
  esac
}
cmd_systemctl() {
  case "$*" in
    'status argo') test -e "$ROOT/argo-active" ;;
    'disable argo')
      record "argo-stop"
      [ ! -e "$ROOT/argo-stop-fail" ] || return 1
      rm -f "$ROOT/argo-enabled" "$ROOT/argo-active" ;;
    'enable argo')
      record "argo-start"
      [ ! -e "$ROOT/argo-start-fail" ] || return 1
      touch "$ROOT/argo-enabled" "$ROOT/argo-active" ;;
    *) echo "unexpected cmd_systemctl: $*" >&2; return 10 ;;
  esac
}
sleep() { :; }
rc-update() {
  case "$*" in
    'show default')
      [ ! -e "$ROOT/argo-enabled" ] || printf 'argo | default\n'
      [ ! -e "$ROOT/monitor-enabled" ] || printf 'argo-monitor | default\n'
      ;;
    'del argo-monitor default') record "monitor-disable"; rm -f "$ROOT/monitor-enabled" ;;
    'add argo-monitor default') record "monitor-enable"; touch "$ROOT/monitor-enabled" ;;
    *) echo "unexpected rc-update: $*" >&2; return 10 ;;
  esac
}
rc-service() {
  case "$*" in
    'argo-monitor stop') record "monitor-stop"; rm -f "$ROOT/monitor-active" ;;
    'argo-monitor status') test -e "$ROOT/monitor-active" ;;
    'argo-monitor start') record "monitor-start"; touch "$ROOT/monitor-active" ;;
    'argo-monitor restart') record "monitor-restart"; touch "$ROOT/monitor-active" ;;
    'argo status') test -e "$ROOT/argo-active" ;;
    *) echo "unexpected rc-service: $*" >&2; return 10 ;;
  esac
}
argo_monitor_remove() { record "monitor-remove"; }
assert_kept() {
  grep -qx saved.trycloudflare.com "$WORK_DIR/argo-domain"
  grep -qx 'saved subscription' "$WORK_DIR/conf/keep"
  grep -qx 5 "$WORK_DIR/argo-monitor.attempts"
  grep -qx 1000 "$WORK_DIR/argo-monitor.last"
}
reset_actions() { : > "$ROOT/actions"; }
touch "$ROOT/argo-enabled" "$ROOT/argo-active" "$ROOT/monitor-enabled" "$ROOT/monitor-active"

echo '[1/7] systemd: stop monitor before stopping Argo, preserve data'
reset_actions
argo_toggle_service disable
[[ "$(cat "$ROOT/actions")" == $'monitor-stop\nargo-stop' ]]
test ! -e "$ROOT/argo-enabled" && test ! -e "$ROOT/argo-active"
test ! -e "$ROOT/monitor-enabled" && test ! -e "$ROOT/monitor-active"
assert_kept

echo '[2/7] repeat disable: remain stopped; generic sync must not re-enable'
reset_actions
argo_toggle_service disable
argo_monitor_sync
test ! -e "$ROOT/monitor-active" && test ! -e "$ROOT/monitor-enabled"
! grep -q monitor-start "$ROOT/actions"
assert_kept

echo '[3/7] systemd: enable Argo first, restore monitor afterward'
reset_actions
argo_toggle_service enable
[[ "$(cat "$ROOT/actions")" == $'argo-start\nmonitor-start' ]]
test -e "$ROOT/argo-enabled" && test -e "$ROOT/monitor-active"
assert_kept
reset_actions
argo_toggle_service enable
! grep -q 'monitor-start' "$ROOT/actions"
assert_kept

echo '[4/7] failed Argo start: do not start monitor'
argo_toggle_service disable
touch "$ROOT/argo-start-fail"
reset_actions
if argo_toggle_service enable; then echo 'unexpected Argo start success' >&2; exit 1; fi
! grep -q monitor-start "$ROOT/actions"
test ! -e "$ROOT/monitor-active"
rm -f "$ROOT/argo-start-fail"

echo '[5/7] failed monitor start returns error and preserves Argo state'
touch "$ROOT/monitor-start-fail"
reset_actions
if argo_toggle_service enable; then echo 'unexpected monitor start success' >&2; exit 1; fi
test -e "$ROOT/argo-active"
test ! -e "$ROOT/monitor-active"
rm -f "$ROOT/monitor-start-fail"
argo_toggle_service disable

echo '[6/7] fixed tunnel: no Quick Tunnel monitor startup'
printf 'ExecStart=/tmp/cloudflared tunnel run --token abc\n' > "$ARGO_DAEMON_FILE"
reset_actions
argo_toggle_service enable
! grep -q monitor-start "$ROOT/actions"
! grep -q 'monitor-remove' "$ROOT/actions"
assert_kept

echo '[7/7] OpenRC: stop/start exact Quick Tunnel monitor'
SYSTEM=Alpine
printf '#!/sbin/openrc-run\n' > "$ROOT/argo-monitor.init"
printf 'ExecStart=/tmp/cloudflared tunnel --url http://localhost:8080\n' > "$ARGO_DAEMON_FILE"
touch "$ROOT/monitor-enabled" "$ROOT/monitor-active"
reset_actions
argo_toggle_service disable
[[ "$(cat "$ROOT/actions")" == $'monitor-stop\nmonitor-disable\nargo-stop' ]]
test ! -e "$ROOT/monitor-enabled"
# A leftover argo-monitor name alone must NOT count as an enabled Argo.
touch "$ROOT/monitor-enabled"
reset_actions
argo_monitor_sync
! grep -q monitor-start "$ROOT/actions"
rm -f "$ROOT/monitor-enabled"
reset_actions
argo_toggle_service enable
grep -qx 'monitor-enable' "$ROOT/actions"
grep -qx 'monitor-start' "$ROOT/actions"
assert_kept

# Both entry points must use exactly the same toggle helper.
grep -q 'ACTION\[3\]() {' sing-box.sh
[ "$(grep -c 'argo_toggle_service disable && info' sing-box.sh)" -eq 2 ]
[ "$(grep -c 'argo_toggle_service enable && info' sing-box.sh)" -eq 2 ]
echo 'PASS: 7/7 Argo toggle lifecycle cases (systemd/OpenRC, failure, data preservation)'
