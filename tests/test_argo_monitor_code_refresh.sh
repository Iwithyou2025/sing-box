#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source <(sed -n '/^argo_monitor_code_refresh() {/,/^}/p' sing-box.sh)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
WORK_DIR="$ROOT"
SYSTEM=Ubuntu
SB_SCRIPT_REF=main
SB_RUNNING_SCRIPT_SHA=$(printf original | sha256sum | awk '{print $1}')
REMOTE_SOURCE=original
FAKE_NOW=1000
CALLS=0
RESTARTS=0
WGET_FAIL=0
date() { [ "$1" = +%s ] && printf '%s\n' "$FAKE_NOW"; }
wget() {
  CALLS=$((CALLS+1))
  local out='' old='' arg
  for arg in "$@"; do
    [ "$old" = -O ] && out="$arg"
    old="$arg"
  done
  [ -n "$out" ] || return 1
  [ "$WGET_FAIL" = 0 ] || return 1
  printf '%s' "$REMOTE_SOURCE" > "$out"
}
systemctl() {
  [ "$*" = '--no-block restart argo-monitor.service' ] || { echo "Unexpected service action: $*" >&2; return 1; }
  RESTARTS=$((RESTARTS+1))
}
rc-service() { echo "OpenRC should not run in systemd case" >&2; return 1; }
argo_monitor_code_refresh
[ "$CALLS" -eq 1 ] && [ "$RESTARTS" -eq 0 ]
FAKE_NOW=1200
REMOTE_SOURCE=changed
argo_monitor_code_refresh
[ "$CALLS" -eq 1 ] && [ "$RESTARTS" -eq 0 ]
FAKE_NOW=1300
STATUS=0
argo_monitor_code_refresh || STATUS=$?
[ "$STATUS" -eq 2 ] && [ "$RESTARTS" -eq 1 ]
[ "$CALLS" -eq 2 ]
# Ignore transient download failures.
ARGO_MONITOR_NEXT_CODE_CHECK=0
WGET_FAIL=1
argo_monitor_code_refresh
[ "$RESTARTS" -eq 1 ]
# When launched without a digest (legacy/manual), avoid unsafe self-restarts.
SB_RUNNING_SCRIPT_SHA=''
ARGO_MONITOR_NEXT_CODE_CHECK=0
argo_monitor_code_refresh
[ "$RESTARTS" -eq 1 ]
# Alpine restarts only argo-monitor via OpenRC.
SYSTEM=Alpine
SB_RUNNING_SCRIPT_SHA=$(printf original | sha256sum | awk '{print $1}')
WGET_FAIL=0
ARGO_MONITOR_NEXT_CODE_CHECK=0
rc-service() {
  [ "$*" = 'argo-monitor restart' ] || return 1
  printf openrc >> "$ROOT/openrc"
}
STATUS=0
argo_monitor_code_refresh || STATUS=$?
[ "$STATUS" -eq 2 ]
[ "$(cat "$ROOT/openrc")" = openrc ]

# Validate launcher: the digest represents the SAME downloaded script.
mkdir -p "$ROOT/bin"
sed -n '/^create_shortcut() {/,/^}/p' sing-box.sh |
  sed -e "s|/usr/bin/sb|$ROOT/sb|g" > "$ROOT/shortcut.sh"
source "$ROOT/shortcut.sh"
text() { :; }; info() { :; }
REFRESH_CALLS=0
argo_monitor_sync() {
  [ "$SB_MONITOR_FORCE_REFRESH" = 1 ] || return 1
  REFRESH_CALLS=$((REFRESH_CALLS+1))
}
cat > "$ROOT/bin/wget" <<'EOF'
#!/usr/bin/env bash
output=''
previous=''
for a in "$@"; do
  [ "$previous" = -qO ] && output="$a"
  previous="$a"
done
[ -n "$output" ] || exit 1
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s|%s|%s\n" "$SB_SCRIPT_REF" "$SB_RUNNING_SCRIPT_SHA" "$1"' > "$output"
EOF
chmod +x "$ROOT/bin/wget"
SYSTEM=Ubuntu
WORK_DIR="$ROOT"
SB_SCRIPT_REF=main
create_shortcut
[ "$REFRESH_CALLS" -eq 1 ]
bash -n "$ROOT/sb.sh"
SHA=$(printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s|%s|%s\n" "$SB_SCRIPT_REF" "$SB_RUNNING_SCRIPT_SHA" "$1"' | sha256sum | awk '{print $1}')
ACTUAL=$(PATH="$ROOT/bin:$PATH" bash "$ROOT/sb.sh" verified)
[ "$ACTUAL" = "main|$SHA|verified" ] || { echo "Launcher digest/arguments were wrong: $ACTUAL" >&2; exit 1; }
echo 'PASS: monitor refresh on changed upstream code; safe launcher digest and service-only restarts'
