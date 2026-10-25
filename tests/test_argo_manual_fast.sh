#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source <(python3 - <<'PY'
from pathlib import Path
import re
s=Path("sing-box.sh").read_text()
for name in ["argo_manual_live_domain","argo_manual_clock_us","argo_manual_wait_domain","argo_manual_domain_healthy","argo_manual_publish_domain"]:
    m=re.search(r'^'+name+r'\(\) \{',s,re.M); assert m,name
    e=re.search(r'^[a-zA-Z_][\w-]*\(\) \{',s[m.end():],re.M)
    print(s[m.start():m.end()+e.start()] if e else s[m.start():])
PY
)
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
WORK_DIR="$ROOT/work"
mkdir -p "$WORK_DIR/conf"
printf 'old.trycloudflare.com\n' > "$WORK_DIR/argo-domain"
printf 'old\n' > "$WORK_DIR/conf/node.json"
info() { :; }; warning() { :; }
ps() { echo "1234 $WORK_DIR/cloudflared tunnel --url http://localhost:8000"; }
ss() { echo 'LISTEN 0 128 127.0.0.1:12345 0.0.0.0:* users:(("cloudflared",pid=1234,fd=7))'; }
curl() {
  if [[ "${!#}" == */quicktunnel ]]; then
    [[ " $* " == *" --noproxy * "* && " $* " == *" --max-time "* ]] || {
      echo "metrics request must bypass proxies and have a timeout: $*" >&2; return 1;
    }
    [[ " $* " == *" --connect-timeout "* ]] || return 1
    printf 'lookup\n' >> "$ROOT/lookups"
    case "${METRICS_MODE:-ready}" in
      ready) printf '{"hostname":"new.trycloudflare.com"}\n' ;;
      delay)
        if [ "$(wc -l < "$ROOT/lookups")" -lt 3 ]; then return 1; fi
        printf '{"hostname":"new.trycloudflare.com"}\n' ;;
      fail) return 1 ;;
      *) return 1 ;;
    esac
  else
    [[ " $* " == *" --connect-timeout "* && " $* " == *" --max-time "* ]] || {
      echo "HTTPS request missing bounded timeout: $*" >&2; return 1;
    }
    [[ " $* " != *" -L "* ]] || { echo "HTTP redirects must be terminal failures" >&2; return 1; }
    printf 'request\n' >> "$ROOT/https-calls"
    local COUNT
    COUNT=$(wc -l < "$ROOT/https-calls")
    case "${HTTPS_MODE:-code}" in
      code) printf '%s' "$HTTP" ;;
      dns_then_200)
        if [ "$COUNT" -le 2 ]; then printf 000; return 6; fi
        printf 200 ;;
      dns_then_530)
        if [ "$COUNT" -eq 1 ]; then printf 000; return 6; fi
        printf 530 ;;
      dns_timeout) printf 000; return 6 ;;
      transfer_error) printf 200; return 28 ;;
      *) return 1 ;;
    esac
  fi
}
HTTP=200
[ "$(argo_manual_live_domain)" = new.trycloudflare.com ]
argo_manual_domain_healthy new.trycloudflare.com
HTTP=503
if argo_manual_domain_healthy new.trycloudflare.com; then echo 'HTTP 503 accepted' >&2; exit 1; fi
HTTP=200
# Ready immediately: no fixed sleep and exactly one hostname probe.
: > "$ROOT/lookups"
METRICS_MODE=ready
[ "$(argo_manual_wait_domain)" = new.trycloudflare.com ]
[ "$(wc -l < "$ROOT/lookups")" -eq 1 ]

# Simulated wall clock verifies retry logic and the complete 5s budget without slow CI tests.
printf '0\n' > "$ROOT/fake-us"
argo_manual_clock_us() { cat "$ROOT/fake-us"; }
sleep() {
  local current delta
  current=$(cat "$ROOT/fake-us")
  delta=$(awk -v x="$1" 'BEGIN{printf "%.0f",x*1000000}')
  printf '%s\n' "$((current+delta))" > "$ROOT/fake-us"
}
: > "$ROOT/lookups"
METRICS_MODE=delay
[ "$(argo_manual_wait_domain)" = new.trycloudflare.com ]
[ "$(wc -l < "$ROOT/lookups")" -eq 3 ]
[ "$(cat "$ROOT/fake-us")" -lt 5000000 ]

# Missing hostname: retries stop at the exact five-second deadline.
printf '0\n' > "$ROOT/fake-us"
: > "$ROOT/lookups"
METRICS_MODE=fail
if argo_manual_wait_domain > "$ROOT/no-domain"; then
  echo "hostname poll did not respect the 5s deadline" >&2; exit 1
fi
[ ! -s "$ROOT/no-domain" ]
[ "$(cat "$ROOT/fake-us")" -eq 5000000 ]
[ "$(wc -l < "$ROOT/lookups")" -gt 1 ]
METRICS_MODE=ready

# The HTTPS stage has a separate 5s budget, and only HTTP 200 is accepted.
reset_https() {
  printf '0\n' > "$ROOT/fake-us"
  : > "$ROOT/https-calls"
}
reset_https; HTTPS_MODE=code; HTTP=200
argo_manual_domain_healthy new.trycloudflare.com
[ "$(wc -l < "$ROOT/https-calls")" -eq 1 ]
[ "$(cat "$ROOT/fake-us")" -eq 0 ]

# A newly assigned hostname may initially fail DNS (curl 6/HTTP 000); retry until 200.
reset_https; HTTPS_MODE=dns_then_200
argo_manual_domain_healthy new.trycloudflare.com
[ "$(wc -l < "$ROOT/https-calls")" -eq 3 ]
[ "$(cat "$ROOT/fake-us")" -lt 5000000 ]

# Any actual non-200 HTTP response is terminal, even if the response is early.
for HTTP in 530 503 404 301 201 204; do
  reset_https; HTTPS_MODE=code
  if argo_manual_domain_healthy new.trycloudflare.com; then
    echo "non-200 HTTP $HTTP was accepted" >&2; exit 1
  fi
  [ "$(wc -l < "$ROOT/https-calls")" -eq 1 ]
  [ "$(cat "$ROOT/fake-us")" -eq 0 ]
done

# After one DNS failure, an HTTP 530 must abort immediately, not retry until 200.
reset_https; HTTPS_MODE=dns_then_530
if argo_manual_domain_healthy new.trycloudflare.com; then
  echo 'HTTP 530 after DNS recovery was accepted' >&2; exit 1
fi
[ "$(wc -l < "$ROOT/https-calls")" -eq 2 ]
[ "$(cat "$ROOT/fake-us")" -lt 5000000 ]

# Repeated DNS failures stop after 5s, never publish a hostname.
reset_https; HTTPS_MODE=dns_timeout
if argo_manual_domain_healthy new.trycloudflare.com; then
  echo 'DNS failures wrongly accepted' >&2; exit 1
fi
[ "$(cat "$ROOT/fake-us")" -eq 5000000 ]
[ "$(wc -l < "$ROOT/https-calls")" -gt 1 ]

# A 200 status with an incomplete transfer cannot be treated as a successful GET.
reset_https; HTTPS_MODE=transfer_error
if argo_manual_domain_healthy new.trycloudflare.com; then
  echo 'HTTP 200 with failed transfer was accepted' >&2; exit 1
fi
[ "$(wc -l < "$ROOT/https-calls")" -eq 1 ]

# Manual publication reuses safe exporter but never invokes monitoring wait/check routines.
argo_monitor_wait_domain() { echo 'monitor wait mistakenly called' >&2; return 1; }
argo_monitor_domain_healthy() { echo 'monitor health mistakenly called' >&2; return 1; }
argo_monitor_publish_domain() { echo 'monitor publish mistakenly called' >&2; return 1; }
fetch_quicktunnel_domain() {
  [ "$ARGO_MONITOR_VERIFIED_DOMAIN" = new.trycloudflare.com ]
  echo "$ARGO_MONITOR_VERIFIED_DOMAIN" > "$WORK_DIR/argo-domain"
  echo new > "$WORK_DIR/conf/node.json"
}
export_list() { [ "$EXPORT_OK" = 1 ]; }
EXPORT_OK=0
if argo_manual_publish_domain new.trycloudflare.com old.trycloudflare.com; then
  echo 'failed subscription export accepted' >&2; exit 1
fi
grep -qx old.trycloudflare.com "$WORK_DIR/argo-domain"
grep -qx old "$WORK_DIR/conf/node.json"
EXPORT_OK=1
argo_manual_publish_domain new.trycloudflare.com old.trycloudflare.com
grep -qx new.trycloudflare.com "$WORK_DIR/argo-domain"
grep -qx new "$WORK_DIR/conf/node.json"
echo 'PASS: 5s hostname/DNS polling, immediate 200, delayed DNS recovery, terminal 530/non-200, timeout, monitor isolation, rollback'
