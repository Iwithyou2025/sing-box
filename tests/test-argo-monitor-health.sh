#!/usr/bin/env bash
# Mocked Quick Tunnel HTTPS checks: no live tunnel or network required.
set -Eeuo pipefail
TEST_CASE='preflight'
trap 'rc=$?; printf "FAIL: %s (line %s, exit %s)\n" "$TEST_CASE" "$LINENO" "$rc" >&2' ERR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
printf "Argo monitor HTTPS retry tests (15s total / 500ms interval)\n"
printf "Script: %s\n" "$ROOT/sing-box.sh"
[ -s "$ROOT/sing-box.sh" ] || { echo "FAIL: missing sing-box.sh (download both files from main)" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
awk '/^argo_monitor_wait_healthy_domain\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$ROOT/sing-box.sh" > "$TMP/function.sh"
grep -q '^argo_monitor_wait_healthy_domain() {' "$TMP/function.sh" || { echo 'FAIL: retry function missing; sing-box.sh is old or download cache is stale' >&2; exit 1; }
bash -n "$TMP/function.sh"
source "$TMP/function.sh"
cat > "$TMP/curl" <<'MOCK'
#!/usr/bin/env bash
n=$(cat "$MOCK_COUNT" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$MOCK_COUNT"
case "$MOCK_MODE" in
  immediate) printf 200; exit 0 ;;
  transient)
    case "$n" in
      1) printf 000; exit 6 ;;
      2) printf 530; exit 0 ;;
      *) printf 200; exit 0 ;;
    esac ;;
  failed) printf 530; exit 0 ;;
esac
MOCK
chmod +x "$TMP/curl"
export MOCK_COUNT="$TMP/count" MOCK_MODE='' PATH="$TMP:$PATH"
i18n_message() { printf '%s' "$1"; }

TEST_CASE='1/4 immediate HTTP 200'
printf '[1/4] Immediate 200... '
MOCK_MODE=immediate; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
argo_monitor_wait_healthy_domain sample.trycloudflare.com 1000
[[ $(cat "$MOCK_COUNT") == 1 ]]
echo "PASS immediate 200"

TEST_CASE='2/4 DNS/530 recovery'
printf '[2/4] DNS error -> HTTP 530 -> 200... '
MOCK_MODE=transient; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
argo_monitor_wait_healthy_domain sample.trycloudflare.com 2200 > "$TMP/log"
[[ $(cat "$MOCK_COUNT") == 3 ]]
grep -q 'HTTP=000.*curl退出码=6' "$TMP/log"
grep -q 'HTTP=530.*curl退出码=0' "$TMP/log"
echo "PASS DNS error -> HTTP 530 -> 200"

TEST_CASE='3/4 repeated failures and deadline'
printf '[3/4] Repeated HTTP 530 until deadline... '
MOCK_MODE=failed; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
if argo_monitor_wait_healthy_domain sample.trycloudflare.com 1300 > "$TMP/log"; then exit 1; fi
n=$(cat "$MOCK_COUNT")
[[ $n -ge 2 && $n -le 3 ]]
grep -q 'HTTP=530.*curl退出码=0' "$TMP/log"
echo "PASS retries within deadline"

TEST_CASE='4/4 invalid domain'
printf '[4/4] Invalid hostname... '
echo 0 > "$MOCK_COUNT"
if argo_monitor_wait_healthy_domain example.org 1000; then exit 1; fi
[[ $(cat "$MOCK_COUNT") == 0 ]]
echo "PASS rejects invalid domain"
echo "RESULT: 4/4 PASS. Tests are mocked; no live Argo restart."
