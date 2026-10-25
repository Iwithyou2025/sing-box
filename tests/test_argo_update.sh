#!/usr/bin/env bash
# Exercise real updater functions with isolated files and mocked network/services.
set -eo pipefail
cd "$(dirname "$0")/.."
source <(sed -n '/^download_cloudflared() {/,/^# Sing-box 的最新版本/{ /^# Sing-box 的最新版本/d; p; }' sing-box.sh)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
info() { :; }
warning() { :; }
text() { echo "$1"; }
check_arch() { ARGO_ARCH=arm64; }
sleep() { :; }
reading() { printf -v "$2" '%s' "$ANSWER"; }
fetch_quicktunnel_domain() { echo domain >> "$EVENTS"; [ "$DOMAIN_FAIL" != 1 ]; }
export_list() {
  echo export >> "$EVENTS"
  argo_refresh_domain_for_export
}
cmd_systemctl() {
  echo "$*" >> "$EVENTS"
  case "$1" in
    status) [ "$ACTIVE" = 1 ] ;;
    restart) [ "$FAIL_START" != 1 ] || [ "$("$WORK_DIR/cloudflared" --version | awk '{print $3}')" = 2026.1.0 ] ;;
    enable) [ "${ARGO_UPDATE_PRESERVE_SERVICE_STATE:-0}" != 1 ] || { echo 'unexpected enable during update' >&2; return 1; } ;;
    *) echo 'unexpected service mutation' >&2; return 1 ;;
  esac
}
wget() {
  local target url="${@: -1}"
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -qO ]; then target="$2"; shift; fi
    shift
  done
  echo "download $url" >> "$EVENTS"
  [[ "$PROXY_FAIL" != 1 || "$url" != https://proxy/* ]] || return 1
  [ "$DOWNLOAD_FAIL" != 1 ] || return 1
  if [ "$INVALID" = 1 ]; then echo invalid > "$target"; else
    printf '#!/usr/bin/env bash\necho "cloudflared version %s (built test)"\n' "$NEW_VERSION" > "$target"
  fi
}
reset_case() {
  WORK_DIR=$(mktemp -d "$ROOT/case.XXXXXX")
  ARGO_DAEMON_FILE="$WORK_DIR/argo.service"
  EVENTS="$WORK_DIR/events"; : > "$EVENTS"
  printf '#!/usr/bin/env bash\necho "cloudflared version 2026.1.0 (built test)"\n' > "$WORK_DIR/cloudflared"
  chmod +x "$WORK_DIR/cloudflared"
  echo "ExecStart=$WORK_DIR/cloudflared tunnel run --token test" > "$ARGO_DAEMON_FILE"
  GH_PROXY=https://proxy/ ANSWER=y ACTIVE=1 FAIL_START=0 DOWNLOAD_FAIL=0 INVALID=0 NEW_VERSION=2026.10.0 DOMAIN_FAIL=0 PROXY_FAIL=0
}
assert_version() { [ "$("$WORK_DIR/cloudflared" --version | awk '{print $3}')" = "$1" ]; }
assert_clean() { [ -z "$(find "$WORK_DIR" -name '.cloudflared-*' -print)" ]; }
reset_case; argo_version; assert_version 2026.10.0; grep -qx 'restart argo' "$EVENTS"; ! grep -qx export "$EVENTS"; assert_clean
reset_case; ACTIVE=0; argo_version; assert_version 2026.10.0; ! grep -qx 'restart argo' "$EVENTS"; assert_clean
reset_case; ANSWER=n; argo_version; assert_version 2026.1.0; ! grep -qx 'restart argo' "$EVENTS"; assert_clean
reset_case; NEW_VERSION=2026.1.0; argo_version; assert_version 2026.1.0; ! grep -qx 'restart argo' "$EVENTS"; assert_clean
reset_case; DOWNLOAD_FAIL=1; if argo_version; then exit 1; fi; assert_version 2026.1.0; assert_clean
reset_case; INVALID=1; if argo_version; then exit 1; fi; assert_version 2026.1.0; assert_clean
reset_case; FAIL_START=1; if argo_version; then exit 1; fi; assert_version 2026.1.0; [ "$(grep -c '^restart argo$' "$EVENTS")" = 2 ]; assert_clean
reset_case; STATUS[1]=$(text 28); echo "ExecStart=$WORK_DIR/cloudflared tunnel --url http://localhost:8888" > "$ARGO_DAEMON_FILE"; argo_version; grep -qx domain "$EVENTS"; grep -qx export "$EVENTS"; ! grep -qx 'enable argo' "$EVENTS"; [ "$(grep -c '^domain$' "$EVENTS")" = 1 ]; assert_clean
reset_case; rm "$ARGO_DAEMON_FILE"; argo_version; [ ! -s "$EVENTS" ]; assert_version 2026.1.0
reset_case; echo 'ExecStart=/other/cloudflared' > "$ARGO_DAEMON_FILE"; if argo_version; then exit 1; fi; [ ! -s "$EVENTS" ]
reset_case; FAIL_START=1; echo "ExecStart=$WORK_DIR/cloudflared tunnel --url http://localhost:8888" > "$ARGO_DAEMON_FILE"; if argo_version; then exit 1; fi; assert_version 2026.1.0; grep -qx domain "$EVENTS"; grep -qx export "$EVENTS"; assert_clean
reset_case; DOMAIN_FAIL=1; echo "ExecStart=$WORK_DIR/cloudflared tunnel --url http://localhost:8888" > "$ARGO_DAEMON_FILE"; if argo_version; then exit 1; fi; assert_version 2026.10.0; ! grep -qx export "$EVENTS"; assert_clean
reset_case; PROXY_FAIL=1; argo_version; assert_version 2026.10.0; [ "$(grep -c '^download ' "$EVENTS")" = 2 ]; grep -q '^download https://github.com/' "$EVENTS"; assert_clean
echo 'PASS: Argo update, stopped service, decline, same version, download/validation failure, rollback, Quick Tunnel refresh and ownership checks'
