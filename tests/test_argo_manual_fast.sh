#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source <(python3 - <<'PY'
from pathlib import Path
import re
s=Path("sing-box.sh").read_text()
for name in ["argo_manual_live_domain","argo_manual_domain_healthy","argo_manual_publish_domain"]:
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
wget() {
  [[ " $* " == *" --timeout=1 "* && " $* " == *" --tries=1 "* ]] || {
    echo "manual lookup is not capped at 1s: $*" >&2; return 1;
  }
  printf '{"hostname":"new.trycloudflare.com"}\n'
}
curl() {
  [[ " $* " == *" --connect-timeout 1 "* && " $* " == *" --max-time 1 "* ]] || {
    echo "HTTPS request not capped at 1s: $*" >&2; return 1;
  }
  printf '%s' "$HTTP"
}
HTTP=200
[ "$(argo_manual_live_domain)" = new.trycloudflare.com ]
argo_manual_domain_healthy new.trycloudflare.com
HTTP=503
if argo_manual_domain_healthy new.trycloudflare.com; then echo 'HTTP 503 accepted' >&2; exit 1; fi
HTTP=200
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
echo 'PASS: one-shot 1s lookup/HTTPS, no monitor calls, failed export rollback'
