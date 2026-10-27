#!/usr/bin/env bash
# Mocked Quick Tunnel HTTPS checks: no live tunnel or network required.
set -Eeuo pipefail
TEST_CASE='preflight'
trap 'rc=$?; printf "FAIL: %s (line %s, exit %s)\n" "$TEST_CASE" "$LINENO" "$rc" >&2' ERR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
printf "Argo monitor HTTPS retry tests (200s total / 500ms interval)\n"
printf "Script: %s\n" "$ROOT/sing-box.sh"
[ -s "$ROOT/sing-box.sh" ] || { echo "FAIL: missing sing-box.sh (download both files from main)" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
awk '/^argo_monitor_wait_healthy_domain\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$ROOT/sing-box.sh" > "$TMP/function.sh"
grep -q '^argo_monitor_wait_healthy_domain() {' "$TMP/function.sh" || { echo 'FAIL: retry function missing; sing-box.sh is old or download cache is stale' >&2; exit 1; }
bash -n "$TMP/function.sh"
awk '/^argo_monitor_http_check\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$ROOT/sing-box.sh" > "$TMP/http-function.sh"
grep -q '^argo_monitor_http_check() {' "$TMP/http-function.sh"
bash -n "$TMP/http-function.sh"
source "$TMP/http-function.sh"
awk '/^argo_monitor_domain_healthy\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$ROOT/sing-box.sh" > "$TMP/domain-function.sh"
bash -n "$TMP/domain-function.sh"
source "$TMP/domain-function.sh"
# Validate the production default without waiting 200 seconds in a mock test.
grep -Fq 'WAIT_MS="${2:-200000}"' "$TMP/function.sh" || { echo "FAIL: expected 200s production HTTPS deadline" >&2; exit 1; }
source "$TMP/function.sh"
cat > "$TMP/curl" <<'MOCK'
#!/usr/bin/env bash
n=$(cat "$MOCK_COUNT" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$MOCK_COUNT"
OUT=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|--output) OUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
emit() {
  [ -z "$OUT" ] || printf '%s\n' "$2" > "$OUT"
  printf '%s' "$1"
}
case "$MOCK_MODE" in
  immediate) emit 200 '<html>Welcome to nginx!</html>'; exit 0 ;;
  transient)
    case "$n" in
      1) emit 000 ''; exit 6 ;;
      2) emit 530 '<html>Cloudflare error</html>'; exit 0 ;;
      *) emit 200 '<html>Welcome to nginx!</html>'; exit 0 ;;
    esac ;;
  failed) emit 530 '<html>Cloudflare error</html>'; exit 0 ;;
  pending) emit 000 ''; exit 6 ;;
  empty) exit 7 ;;
  gateway)
    if [ "$n" -eq 1 ]; then
      emit 504 '<html>nginx upstream error</html>'
    else
      emit 200 '<html>Welcome to nginx!</html>'
    fi ;;
  missing) emit 200 '<html>Other site</html>'; exit 0 ;;
  other2xx) emit 204 '<html>Welcome to nginx!</html>'; exit 0 ;;
  nginx504) emit 504 '<html>nginx is reporting an error</html>'; exit 0 ;;
  upper) emit 200 '<html>WELCOME TO NGINX!</html>'; exit 0 ;;
esac
MOCK
chmod +x "$TMP/curl"
export MOCK_COUNT="$TMP/count" MOCK_MODE='' PATH="$TMP:$PATH"
i18n_message() { printf '%s' "$1"; }

TEST_CASE='1/15 immediate HTTP 200'
printf '[1/15] Immediate 200... '
MOCK_MODE=immediate; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
argo_monitor_wait_healthy_domain sample.trycloudflare.com 1000 > "$TMP/log"
grep -q 'Welcome to nginx!' "$TMP/log"
[[ $(cat "$MOCK_COUNT") == 1 ]]
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == healthy ]]
echo "PASS immediate 200"

TEST_CASE='2/15 DNS/530 recovery'
printf '[2/15] DNS error -> HTTP 530 -> 200... '
MOCK_MODE=transient; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
argo_monitor_wait_healthy_domain sample.trycloudflare.com 2200 > "$TMP/log"
[[ $(cat "$MOCK_COUNT") == 3 ]]
grep -q '重建中.*HTTP=000.*curl退出码=6' "$TMP/log"
grep -q 'Welcome to nginx!' "$TMP/log"
! grep -q '检查失败.*HTTP=000' "$TMP/log"
grep -q '检查失败.*HTTP=530.*curl退出码=0' "$TMP/log"
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == healthy ]]
echo "PASS HTTP 000 is rebuilding, 530 failed, then 200 recovered"

TEST_CASE='3/15 repeated failures and deadline'
printf '[3/15] Repeated HTTP 530 until deadline... '
MOCK_MODE=failed; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
if argo_monitor_wait_healthy_domain sample.trycloudflare.com 1300 > "$TMP/log"; then exit 1; fi
n=$(cat "$MOCK_COUNT")
[[ $n -ge 2 && $n -le 3 ]]
grep -q '检查失败.*HTTP=530.*curl退出码=0' "$TMP/log"
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == error ]]
echo "PASS HTTP 530 remains a failure until deadline"

TEST_CASE='4/15 invalid domain'
printf '[4/15] Invalid hostname... '
echo 0 > "$MOCK_COUNT"
if argo_monitor_wait_healthy_domain example.org 1000; then exit 1; fi
[[ $(cat "$MOCK_COUNT") == 0 ]]
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == error ]]
echo "PASS rejects invalid domain"

TEST_CASE='5/15 only HTTP 000 until deadline'
printf '[5/15] Repeated HTTP 000 while rebuilding... '
MOCK_MODE=pending; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
if argo_monitor_wait_healthy_domain sample.trycloudflare.com 1300 > "$TMP/log"; then exit 1; fi
n=$(cat "$MOCK_COUNT")
[[ $n -ge 2 && $n -le 3 ]]
grep -q '重建中.*HTTP=000.*curl退出码=6' "$TMP/log"
! grep -q 'HTTPS 检查失败' "$TMP/log"
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == pending ]]
echo "PASS only 000 stays pending until deadline"

TEST_CASE='6/15 HTTP 504 failure then 200 recovery'
printf '[6/15] HTTP 504 -> 200... '
MOCK_MODE=gateway; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
argo_monitor_wait_healthy_domain sample.trycloudflare.com 1500 > "$TMP/log"
[[ $(cat "$MOCK_COUNT") == 2 ]]
grep -q '检查失败.*HTTP=504.*curl退出码=0' "$TMP/log"
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == healthy ]]
echo "PASS 504 is an HTTPS check failure; later 200 recovers"

TEST_CASE='7/15 empty response without status'
printf '[7/15] Empty HTTP response... '
MOCK_MODE=empty; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
if argo_monitor_wait_healthy_domain sample.trycloudflare.com 1100 > "$TMP/log"; then exit 1; fi
grep -q '重建中.*HTTP=000.*curl退出码=7' "$TMP/log"
[[ "$ARGO_MONITOR_HTTPS_WAIT_RESULT" == pending ]]
echo "PASS empty response treated as rebuilding"

# Publisher tests: replace real publication and health checking with mocks.
awk '/^argo_monitor_publish_domain\(\) \{/{p=1} p{print} p && /^\}$/{exit}' "$ROOT/sing-box.sh" > "$TMP/publish-function.sh"
grep -q '^argo_monitor_publish_domain() {' "$TMP/publish-function.sh"
bash -n "$TMP/publish-function.sh"
source "$TMP/publish-function.sh"
WORK_DIR="$TMP/work"
mkdir -p "$WORK_DIR"
argo_manual_publish_domain() {
  echo "$1" > "$WORK_DIR/argo-domain"
  touch "$WORK_DIR/published"
  return 0
}

TEST_CASE='8/15 000 timeout must not publish'
printf '[8/15] HTTP 000 timeout: subscriptions unchanged... '
argo_monitor_wait_healthy_domain() { ARGO_MONITOR_HTTPS_WAIT_RESULT='pending'; return 1; }
if argo_monitor_publish_domain sample.trycloudflare.com old.trycloudflare.com > "$TMP/log"; then exit 1; fi
grep -q '重建等待超时' "$TMP/log"
[[ ! -e "$WORK_DIR/published" ]]
echo "PASS still rebuilding, no domain/subscription publication"

TEST_CASE='9/15 real HTTP error must not publish'
printf '[9/15] HTTP error timeout: subscriptions unchanged... '
argo_monitor_wait_healthy_domain() { ARGO_MONITOR_HTTPS_WAIT_RESULT='error'; return 1; }
if argo_monitor_publish_domain sample.trycloudflare.com old.trycloudflare.com > "$TMP/log"; then exit 1; fi
grep -q '未通过 HTTP 健康检查' "$TMP/log"
[[ ! -e "$WORK_DIR/published" ]]
echo "PASS HTTPS failed, no domain/subscription publication"

TEST_CASE='10/15 2xx success can publish'
printf '[10/15] Verified HTTP 200: publish allowed... '
argo_monitor_wait_healthy_domain() { ARGO_MONITOR_HTTPS_WAIT_RESULT='healthy'; return 0; }
argo_monitor_publish_domain sample.trycloudflare.com old.trycloudflare.com > "$TMP/log"
[[ -e "$WORK_DIR/published" ]]
[[ "$(cat "$WORK_DIR/argo-domain")" == 'sample.trycloudflare.com' ]]
grep -q 'HTTP 验证通过，订阅已同步' "$TMP/log"
echo "PASS healthy candidate published"

TEST_CASE='11/15 HTTP 200 without nginx keyword'
printf '[11/15] HTTP 200 without nginx keyword... '
MOCK_MODE=missing; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
if argo_monitor_http_check sample.trycloudflare.com 1 > "$TMP/log"; then exit 1; fi
[[ "$ARGO_MONITOR_HTTP_CODE" == 200 && "$ARGO_MONITOR_HTTP_NGINX" == 0 ]]
grep -q 'Other site' "$TMP/log"
echo "PASS HTTP 200 alone does not prove healthy"

TEST_CASE='12/15 HTTP 204 with nginx keyword'
printf '[12/15] HTTP 204 with nginx keyword... '
MOCK_MODE=other2xx; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
if argo_monitor_http_check sample.trycloudflare.com 1 > "$TMP/log"; then exit 1; fi
[[ "$ARGO_MONITOR_HTTP_CODE" == 204 && "$ARGO_MONITOR_HTTP_NGINX" == 1 ]]
echo "PASS HTTP 204 is not HTTP 200"

TEST_CASE='13/15 HTTP 504 with nginx keyword'
printf '[13/15] HTTP 504 with nginx keyword... '
MOCK_MODE=nginx504; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
if argo_monitor_http_check sample.trycloudflare.com 1 > "$TMP/log"; then exit 1; fi
[[ "$ARGO_MONITOR_HTTP_CODE" == 504 && "$ARGO_MONITOR_HTTP_NGINX" == 1 ]]
grep -q 'nginx is reporting an error' "$TMP/log"
echo "PASS HTTP 504 rejected despite nginx keyword"

TEST_CASE='14/15 case-insensitive nginx keyword'
printf '[14/15] Uppercase NGINX keyword... '
MOCK_MODE=upper; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
argo_monitor_http_check sample.trycloudflare.com 1 > "$TMP/log"
[[ "$ARGO_MONITOR_HTTP_CODE" == 200 && "$ARGO_MONITOR_HTTP_NGINX" == 1 ]]
echo "PASS uppercase NGINX accepted with HTTP 200"

TEST_CASE='15/15 existing-domain uses same body verification'
printf '[15/15] Existing domain body verification... '
MOCK_MODE=missing; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
if argo_monitor_domain_healthy sample.trycloudflare.com > "$TMP/log"; then exit 1; fi
[[ "$ARGO_MONITOR_HTTP_NGINX" == 0 ]]
MOCK_MODE=immediate; export MOCK_MODE; echo 0 > "$MOCK_COUNT"
argo_monitor_domain_healthy sample.trycloudflare.com > "$TMP/log"
grep -q 'Welcome to nginx!' "$TMP/log"
echo "PASS running domain requires HTTP 200 and nginx"

echo "RESULT: 15/15 PASS. Tests are mocked; no live Argo restart."
