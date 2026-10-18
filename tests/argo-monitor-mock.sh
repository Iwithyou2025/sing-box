#!/usr/bin/env bash
# Isolated mock: verify changed cloudflared domain refreshes subscriptions, not the tunnel.
set -uxo pipefail
cd "$(dirname "$0")/.."
# Extract functions only; do not execute the installer or modify the runner.
source <(sed -n \
  -e '/^argo_monitor_live_domain() {/,/^}/p' \
  -e '/^argo_monitor_domain_healthy() {/,/^}/p' \
  -e '/^argo_monitor_loop() {/,/^}/p' sing-box.sh)

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
ARGO_DAEMON_FILE="$WORK_DIR/argo.service"
SYSTEM='Ubuntu'
printf 'ExecStart=/etc/sing-box/cloudflared tunnel --url http://localhost:8080\n' > "$ARGO_DAEMON_FILE"
printf 'old-value.trycloudflare.com\n' > "$WORK_DIR/argo-domain"

ps() { printf '1234 /etc/sing-box/cloudflared tunnel --url http://localhost:8080\n'; }
ss() { printf 'LISTEN 0 4096 127.0.0.1:20243 0.0.0.0:* users:(("cloudflared",pid=1234,fd=3))\n'; }
wget() { printf '{"hostname":"new-value.trycloudflare.com"}\n'; }
curl() { printf '200'; }
systemctl() { return 0; }
cmd_systemctl() { echo "$*" > "$WORK_DIR/unexpected-restart"; return 0; }
export_list() {
  printf 'new-value.trycloudflare.com\n' > "$WORK_DIR/argo-domain"
  printf 'updated\n' >> "$WORK_DIR/exports"
}
sleep() {
  if [ -e "$WORK_DIR/first-tick" ]; then exit 0; fi
  : > "$WORK_DIR/first-tick"
  return 0
}

[[ "$(argo_monitor_live_domain)" == "new-value.trycloudflare.com" ]] || exit 1
argo_monitor_domain_healthy 'new-value.trycloudflare.com' || exit 1
( argo_monitor_loop > "$WORK_DIR/monitor.log" )

test "$(cat "$WORK_DIR/argo-domain")" = "new-value.trycloudflare.com"
test "$(wc -l < "$WORK_DIR/exports")" -eq 1
test ! -f "$WORK_DIR/unexpected-restart"
grep -q 'no tunnel restart' "$WORK_DIR/monitor.log"

# Unchanged and healthy: do not export a second time.
rm -f "$WORK_DIR/first-tick"
( argo_monitor_loop >> "$WORK_DIR/monitor.log" )
test "$(wc -l < "$WORK_DIR/exports")" -eq 1
test ! -f "$WORK_DIR/unexpected-restart"
echo 'Argo monitor mock tests passed'
