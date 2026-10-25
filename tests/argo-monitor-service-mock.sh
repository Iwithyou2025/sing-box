#!/usr/bin/env bash
# Exercise the existing-unit repair path without touching system services.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
ARGO_DAEMON_FILE="$WORK_DIR/argo.service"
printf 'ExecStart=/tmp/cloudflared tunnel --url http://localhost:8080\n' > "$ARGO_DAEMON_FILE"
: > "$WORK_DIR/sb.sh"
chmod +x "$WORK_DIR/sb.sh"

# Load the actual current function with only hardcoded filesystem paths sandboxed.
sed -n '/^argo_monitor_sync() {/,/^argo_monitor_live_domain() {/p' sing-box.sh | sed '$d' |
  sed -e "s|/etc/systemd/system/argo-monitor.service|$WORK_DIR/argo-monitor.service|g" \
      -e "s|/etc/init.d/argo-monitor|$WORK_DIR/argo-monitor.init|g" > "$WORK_DIR/func.sh"
source "$WORK_DIR/func.sh"

systemctl() {
  case "$*" in
    'is-enabled --quiet argo-monitor.service') test -e "$WORK_DIR/enabled" ;;
    'is-active --quiet argo-monitor.service') test -e "$WORK_DIR/active" ;;
    'daemon-reload') printf 'daemon-reload\n' >> "$WORK_DIR/commands" ;;
    'enable argo-monitor.service')
      printf 'enable\n' >> "$WORK_DIR/commands"
      : > "$WORK_DIR/enabled"
      ;;
    'restart argo-monitor.service')
      printf 'restart\n' >> "$WORK_DIR/commands"
      test ! -e "$WORK_DIR/force_fail" || return 1
      : > "$WORK_DIR/active"
      ;;
    'enable --now argo-monitor.service')
      printf 'enable-now\n' >> "$WORK_DIR/commands"
      test ! -e "$WORK_DIR/force_fail" || return 1
      : > "$WORK_DIR/enabled"
      : > "$WORK_DIR/active"
      ;;
    *) printf 'Unexpected systemctl: %s\n' "$*" >&2; return 99 ;;
  esac
}
rc-update() {
  case "$*" in
    'show default') test -e "$WORK_DIR/enabled" && printf 'argo-monitor | default\n' || return 1 ;;
    'add argo-monitor default') printf 'rc-add\n' >> "$WORK_DIR/commands"; : > "$WORK_DIR/enabled" ;;
    *) printf 'Unexpected rc-update: %s\n' "$*" >&2; return 99 ;;
  esac
}
rc-service() {
  case "$*" in
    'argo-monitor status') test -e "$WORK_DIR/active" ;;
    'argo-monitor start') printf 'rc-start\n' >> "$WORK_DIR/commands"; : > "$WORK_DIR/active" ;;
    'argo-monitor restart') printf 'rc-restart\n' >> "$WORK_DIR/commands"; : > "$WORK_DIR/active" ;;
    *) printf 'Unexpected rc-service: %s\n' "$*" >&2; return 99 ;;
  esac
}
argo_monitor_remove() { printf 'removed\n' >> "$WORK_DIR/commands"; }

reset_case() {
  rm -f "$WORK_DIR"/enabled "$WORK_DIR"/active "$WORK_DIR"/commands "$WORK_DIR"/force_fail
}
count_commands() {
  local want=$1 num=0
  if [ -s "$WORK_DIR/commands" ]; then num=$(wc -l < "$WORK_DIR/commands"); fi
  if [ "$num" -ne "$want" ]; then
    printf 'Expected %s commands, got %s\n' "$want" "$num" >&2
    cat "$WORK_DIR/commands" >&2
    exit 1
  fi
}

SYSTEM=Ubuntu
printf '[Unit]\n' > "$WORK_DIR/argo-monitor.service"

# Fully active & enabled: avoid needless service restart.
reset_case
: > "$WORK_DIR/enabled"
: > "$WORK_DIR/active"
argo_monitor_sync
count_commands 0

# Existing file, service stopped: start and preserve enabled state.
reset_case
: > "$WORK_DIR/enabled"
argo_monitor_sync
count_commands 1
test -e "$WORK_DIR/active"

# Existing file, service disabled: enable without restart.
reset_case
: > "$WORK_DIR/active"
argo_monitor_sync
count_commands 1
test -e "$WORK_DIR/enabled"

# Existing file, disabled and stopped: repair both.
reset_case
argo_monitor_sync
count_commands 1
test -e "$WORK_DIR/enabled" && test -e "$WORK_DIR/active"

# A failed start must propagate failure, not report success.
reset_case
: > "$WORK_DIR/force_fail"
if argo_monitor_sync; then
  echo 'ERROR: failed systemd start was ignored' >&2
  exit 1
fi

# Existing systemd unit with the old conflicting executable is migrated and restarted.
SYSTEM=Ubuntu
printf '[Unit]\nExecStart=/usr/bin/sb -H\n' > "$WORK_DIR/argo-monitor.service"
reset_case
: > "$WORK_DIR/enabled"
: > "$WORK_DIR/active"
argo_monitor_sync
count_commands 3
grep -qx "ExecStart=$WORK_DIR/sb.sh -H" "$WORK_DIR/argo-monitor.service"

# Fresh systemd unit points directly at the project-owned wrapper.
rm -f "$WORK_DIR/argo-monitor.service"
reset_case
argo_monitor_sync
count_commands 2
grep -qx "ExecStart=$WORK_DIR/sb.sh -H" "$WORK_DIR/argo-monitor.service"

# Alpine/OpenRC: migrate the same old command path.
SYSTEM=Alpine
printf '#!/sbin/openrc-run\ncommand="/usr/bin/sb"\n' > "$WORK_DIR/argo-monitor.init"
reset_case
: > "$WORK_DIR/enabled"
: > "$WORK_DIR/active"
argo_monitor_sync
count_commands 2
grep -qx "command=\"$WORK_DIR/sb.sh\"" "$WORK_DIR/argo-monitor.init"

# Alpine/OpenRC: existing init script must be enabled and started.
printf '#!/sbin/openrc-run\n' > "$WORK_DIR/argo-monitor.init"
reset_case
argo_monitor_sync
count_commands 2
test -e "$WORK_DIR/enabled" && test -e "$WORK_DIR/active"

# Alpine/OpenRC: already healthy, no redundant action.
rm -f "$WORK_DIR/commands"
argo_monitor_sync
count_commands 0

# Fixed tunnel: monitor is removed instead of being enabled.
SYSTEM=Ubuntu
printf 'ExecStart=/tmp/cloudflared tunnel run --token test\n' > "$ARGO_DAEMON_FILE"
rm -f "$WORK_DIR/commands"
argo_monitor_sync
grep -qx 'removed' "$WORK_DIR/commands"

echo 'PASS: existing Argo monitor service repair checks'
