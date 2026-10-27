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
  pending) printf 000; exit 6 ;;
  empty) exit 7 ;;
  gateway)
    if [ "$n" -eq 1 ]; then printf 504; else printf 200; fi ;;
esac
MOCK
chmod +x "$TMP/curl"
export MOCK_COUNT="$TMP/count" MOCK_MODE='' PATH="$TMP:$PATH"
i18n_message() { printf '%s' "$1"; }

TEST_CASE='1/7 immediate HTTP 200'
printf '[1/7] Immediate 200... '
MOCK_MODE=immediate; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
argo_monitor_wait_healthy_domain sample.trycloudflare.com 1000
[[ $(cat "$MOCK_COUNT") == 1 ]]
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == healthy ]]
echo "PASS immediate 200"

TEST_CASE='2/7 DNS/530 recovery'
printf '[2/7] DNS error -> HTTP 530 -> 200... '
MOCK_MODE=transient; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
argo_monitor_wait_healthy_domain sample.trycloudflare.com 2200 > "$TMP/log"
[[ $(cat "$MOCK_COUNT") == 3 ]]
grep -q '重建中.*HTTP=000.*curl退出码=6' "$TMP/log"
! grep -q '检查失败.*HTTP=000' "$TMP/log"
grep -q '检查失败.*HTTP=530.*curl退出码=0' "$TMP/log"
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == healthy ]]
echo "PASS HTTP 000 is rebuilding, 530 failed, then 200 recovered"

TEST_CASE='3/7 repeated failures and deadline'
printf '[3/7] Repeated HTTP 530 until deadline... '
MOCK_MODE=failed; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
if argo_monitor_wait_healthy_domain sample.trycloudflare.com 1300 > "$TMP/log"; then exit 1; fi
n=$(cat "$MOCK_COUNT")
[[ $n -ge 2 && $n -le 3 ]]
grep -q '检查失败.*HTTP=530.*curl退出码=0' "$TMP/log"
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == error ]]
echo "PASS HTTP 530 remains a failure until deadline"

TEST_CASE='4/7 invalid domain'
printf '[4/7] Invalid hostname... '
echo 0 > "$MOCK_COUNT"
if argo_monitor_wait_healthy_domain example.org 1000; then exit 1; fi
[[ $(cat "$MOCK_COUNT") == 0 ]]
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == error ]]
echo "PASS rejects invalid domain"

TEST_CASE='5/7 only HTTP 000 until deadline'
printf '[5/7] Repeated HTTP 000 while rebuilding... '
MOCK_MODE=pending; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
if argo_monitor_wait_healthy_domain sample.trycloudflare.com 1300 > "$TMP/log"; then exit 1; fi
n=$(cat "$MOCK_COUNT")
[[ $n -ge 2 && $n -le 3 ]]
grep -q '重建中.*HTTP=000.*curl退出码=6' "$TMP/log"
! grep -q 'HTTPS 检查失败' "$TMP/log"
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == pending ]]
echo "PASS only 000 stays pending until deadline"

TEST_CASE='6/7 HTTP 504 failure then 200 recovery'
printf '[6/7] HTTP 504 -> 200... '
MOCK_MODE=gateway; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
argo_monitor_wait_healthy_domain sample.trycloudflare.com 1500 > "$TMP/log"
[[ $(cat "$MOCK_COUNT") == 2 ]]
grep -q '检查失败.*HTTP=504.*curl退出码=0' "$TMP/log"
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == healthy ]]
echo "PASS 504 is an HTTPS check failure; later 200 recovers"

TEST_CASE='7/7 empty response without status'
printf '[7/7] Empty HTTP response... '
MOCK_MODE=empty; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
if argo_monitor_wait_healthy_domain sample.trycloudflare.com 1100 > "$TMP/log"; then exit 1; fi
grep -q '重建中.*HTTP=000.*curl退出码=7' "$TMP/log"
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == pending ]]
echo "PASS empty response treated as rebuilding"

echo "RESULT: 7/7 PASS. Tests are mocked; no live Argo restart."
