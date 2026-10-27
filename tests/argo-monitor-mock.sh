#!/usr/bin/env bash
# Mock Argo Quick Tunnel: changed-domain sync, two-failure rebuild, HTTP rejection, and cooldown.
set -euo pipefail
cd "$(dirname "$0")/.."
source <(sed -n \
  -e '/^i18n_message() {/,/^}/p' \
  -e '/^argo_manual_publish_domain() {/,/^}/p' \
  -e '/^argo_monitor_live_domain() {/,/^}/p' \
  -e '/^argo_monitor_domain_healthy() {/,/^}/p' \
  -e '/^argo_monitor_http_check() {/,/^}/p' \
  -e '/^argo_monitor_wait_healthy_domain() {/,/^}/p' \
  -e '/^argo_monitor_wait_domain() {/,/^}/p' \
  -e '/^argo_monitor_publish_domain() {/,/^}/p' \
  -e '/^argo_monitor_code_refresh() {/,/^}/p' \
  -e '/^argo_monitor_loop() {/,/^}/p' sing-box.sh)

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
ARGO_DAEMON_FILE="$WORK_DIR/argo.service"
mkdir -p "$WORK_DIR/conf"
ARGO_MONITOR_NEXT_CODE_CHECK=0
SB_RUNNING_SCRIPT_SHA=''
SYSTEM=Ubuntu
warning() { :; }
printf 'ExecStart=/etc/sing-box/cloudflared tunnel --url http://localhost:8080\n' > "$ARGO_DAEMON_FILE"

# Mock executable/process/services; all state isolated under WORK_DIR.
ps() { printf '1234 %s/cloudflared tunnel --url http://localhost:8080\n' "$WORK_DIR"; }
ss() { printf 'LISTEN 0 4096 127.0.0.1:20243 0.0.0.0:* users:(("cloudflared",pid=1234,fd=3))\n'; }
wget() { printf '{"hostname":"%s"}\n' "$(cat "$WORK_DIR/live")"; }
curl() {
  local URL="${!#}" BAD CODE OUT='' BODY=''
  BAD=$(cat "$WORK_DIR/bad_http" 2>/dev/null || true)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o|--output) OUT=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ "$URL" == *"$BAD"* && -n "$BAD" ]]; then
    CODE=503; BODY='<html><h1>nginx upstream error</h1></html>'
  else
    CODE=200; BODY='<html><h1>Welcome to nginx!</h1></html>'
  fi
  [ -z "$OUT" ] || printf '%s\n' "$BODY" > "$OUT"
  printf '%s' "$CODE"
}
# Keep mock failures fast; production code still defaults to 200 seconds.
eval "$(declare -f argo_monitor_wait_healthy_domain | sed '1 s/argo_monitor_wait_healthy_domain/argo_monitor_wait_healthy_domain_real/')"
argo_monitor_wait_healthy_domain() {
  argo_monitor_wait_healthy_domain_real "$1" 40
}
systemctl() { return 0; }
cmd_systemctl() {
  if [ "$1" = restart ] && [ "$2" = argo ]; then
    printf 'restart\n' >> "$WORK_DIR/restarts"
    cat "$WORK_DIR/recovery_domain" > "$WORK_DIR/live"
  fi
  return 0
}
fetch_quicktunnel_domain() {
  [[ "$ARGO_MONITOR_VERIFIED_DOMAIN" =~ ^[a-zA-Z0-9-]+[.]trycloudflare[.]com$ ]] || return 1
  printf '%s\n' "$ARGO_MONITOR_VERIFIED_DOMAIN" > "$WORK_DIR/argo-domain"
  printf 'current=%s\n' "$ARGO_MONITOR_VERIFIED_DOMAIN" > "$WORK_DIR/conf/ws.json"
}
export_list() {
  printf 'export\n' >> "$WORK_DIR/exports"
  [ ! -e "$WORK_DIR/export_fail" ]
}
sleep() {
  if [ "$1" = 54 ]; then
    local T
    T=$(cat "$WORK_DIR/ticks" 2>/dev/null || echo 0)
    T=$((T+1))
    printf '%s\n' "$T" > "$WORK_DIR/ticks"
    if [ "$T" -gt "$(cat "$WORK_DIR/tick_limit")" ]; then exit 0; fi
  fi
  return 0
}
new_case() {
  rm -f "$WORK_DIR"/ticks "$WORK_DIR"/exports "$WORK_DIR"/restarts "$WORK_DIR"/argo-monitor.last "$WORK_DIR"/argo-monitor.attempts "$WORK_DIR"/export_fail
  echo 2 > "$WORK_DIR/tick_limit"
  echo old-value.trycloudflare.com > "$WORK_DIR/argo-domain"
  echo 'current=old-value.trycloudflare.com' > "$WORK_DIR/conf/ws.json"
  echo old-value.trycloudflare.com > "$WORK_DIR/live"
  echo new-value.trycloudflare.com > "$WORK_DIR/recovery_domain"
  : > "$WORK_DIR/bad_http"
}
assert_count() {
  local FILE=$1 WANT=$2 NUM=0
  if [ -f "$FILE" ]; then NUM=$(wc -l < "$FILE"); fi
  if [ "$NUM" -ne "$WANT" ]; then
    printf 'FAIL: %s expected %s lines, got %s\n' "$FILE" "$WANT" "$NUM" >&2
    exit 1
  fi
}
run_monitor() { ( argo_monitor_loop > "$WORK_DIR/output.log" ); }

# 1) New valid hostname; sync without restarting.
new_case
echo new-value.trycloudflare.com > "$WORK_DIR/live"
run_monitor
grep -q 'completed: HTTP verified' "$WORK_DIR/output.log"
assert_count "$WORK_DIR/exports" 1
assert_count "$WORK_DIR/restarts" 0
test "$(cat "$WORK_DIR/argo-domain")" = new-value.trycloudflare.com

# 2) Old hostname fails twice; restart, validate candidate, then export.
new_case
echo old-value.trycloudflare.com > "$WORK_DIR/bad_http"
run_monitor
grep -q 'failed 2 times; restarting Argo (1/10)' "$WORK_DIR/output.log"
grep -q 'completed: HTTP verified' "$WORK_DIR/output.log"
assert_count "$WORK_DIR/restarts" 1
assert_count "$WORK_DIR/exports" 1
test "$(cat "$WORK_DIR/argo-domain")" = new-value.trycloudflare.com
test "$(cat "$WORK_DIR/argo-monitor.attempts")" = 1

# 3) New hostname returns HTTP 503; no publish/completion.
new_case
echo old-value.trycloudflare.com > "$WORK_DIR/bad_http"
echo old-value.trycloudflare.com > "$WORK_DIR/recovery_domain"
run_monitor
grep -q 'new domain did not pass HTTP health check within 200s' "$WORK_DIR/output.log"
assert_count "$WORK_DIR/restarts" 1
assert_count "$WORK_DIR/exports" 0
test "$(cat "$WORK_DIR/argo-domain")" = old-value.trycloudflare.com

# 4) 10 attempts recorded within 600 seconds: cooldown blocks restart.
new_case
echo old-value.trycloudflare.com > "$WORK_DIR/bad_http"
echo 10 > "$WORK_DIR/argo-monitor.attempts"
date +%s > "$WORK_DIR/argo-monitor.last"
run_monitor
grep -q '10 rebuild attempts reached; cooldown' "$WORK_DIR/output.log"
assert_count "$WORK_DIR/restarts" 0

# 5) Cooldown elapsed: new round starts with attempt 1.
new_case
echo old-value.trycloudflare.com > "$WORK_DIR/bad_http"
echo 10 > "$WORK_DIR/argo-monitor.attempts"
echo "$(( $(date +%s) - 601 ))" > "$WORK_DIR/argo-monitor.last"
run_monitor
grep -q 'restarting Argo (1/10)' "$WORK_DIR/output.log"
assert_count "$WORK_DIR/restarts" 1

# 6) Export failure must restore BOTH the domain pointer and WS configuration,
# leaving the originally published subscription untouched.
new_case
touch "$WORK_DIR/export_fail"
echo new-value.trycloudflare.com > "$WORK_DIR/live"
printf 'original subscription\n' > "$WORK_DIR/subscribe-original"
run_monitor
grep -q 'subscription refresh failed' "$WORK_DIR/output.log"
test "$(cat "$WORK_DIR/argo-domain")" = old-value.trycloudflare.com
grep -qx 'current=old-value.trycloudflare.com' "$WORK_DIR/conf/ws.json"
grep -qx 'original subscription' "$WORK_DIR/subscribe-original"
assert_count "$WORK_DIR/exports" 2

echo 'PASS: Argo Quick Tunnel mock health, sync, rebuild and cooldown tests'
