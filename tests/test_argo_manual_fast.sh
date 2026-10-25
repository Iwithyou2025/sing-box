#!/usr/bin/env bash
# Manual Try: a new local Quick Tunnel hostname is enough. No public DNS/HTTPS
# verification and no overall elapsed-time limit. Keep subscription rollback.
set -euo pipefail
cd "$(dirname "$0")/.."
source <(python3 - <<'PY'
from pathlib import Path
import re
s=Path("sing-box.sh").read_text()
for name in ["argo_manual_live_domain", "argo_manual_wait_domain", "argo_manual_publish_domain"]:
    m=re.search(r'^'+name+r'\(\) \{',s,re.M); assert m,name
    e=re.search(r'^[A-Za-z_][\w-]*\(\) \{',s[m.end():],re.M)
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
SERVICE_POLLS=0
STOP_AFTER=1000
METRICS_MODE=ready
cmd_systemctl() {
  [ "$*" = 'status argo' ] || { echo "Unexpected action: $*" >&2; return 1; }
  SERVICE_POLLS=$((SERVICE_POLLS+1))
  [ "$SERVICE_POLLS" -lt "$STOP_AFTER" ]
}
curl() {
  [[ " $* " == *" http://127.0.0.1:12345/quicktunnel "* ]] || {
    echo "Manual path called public DNS/HTTPS: $*" >&2; return 90;
  }
  [[ " $* " == *" --noproxy * "* && " $* " == *" --max-time 1 "* ]] || {
    echo "Local metrics request must be bounded: $*" >&2; return 1;
  }
  printf 'lookup\n' >> "$ROOT/lookups"
  local n
  n=$(wc -l < "$ROOT/lookups")
  case "$METRICS_MODE" in
    ready) printf '{"hostname":"new.trycloudflare.com"}\n' ;;
    old_then_new)
      if [ "$n" -le 3 ]; then printf '{"hostname":"old.trycloudflare.com"}\n'
      else printf '{"hostname":"new.trycloudflare.com"}\n'; fi ;;
    late)
      if [ "$n" -lt 65 ]; then return 6; fi
      printf '{"hostname":"new.trycloudflare.com"}\n' ;;
    no_domain) return 6 ;;
    *) return 1 ;;
  esac
}
sleep() { printf 'sleep:%s\n' "$1" >> "$ROOT/sleeps"; }
# Immediately accept a new hostname on the first probe.
: > "$ROOT/lookups"
METRICS_MODE=ready
[ "$(argo_manual_wait_domain old.trycloudflare.com)" = new.trycloudflare.com ]
[ "$(wc -l < "$ROOT/lookups")" -eq 1 ]
[ ! -f "$ROOT/sleeps" ]

# Don't accept the old hostname after a restart.
: > "$ROOT/lookups"
METRICS_MODE=old_then_new
[ "$(argo_manual_wait_domain old.trycloudflare.com)" = new.trycloudflare.com ]
[ "$(wc -l < "$ROOT/lookups")" -eq 4 ]

# The result arrives well after the former 5s and 10s deadlines.
: > "$ROOT/lookups"
METRICS_MODE=late
[ "$(argo_manual_wait_domain old.trycloudflare.com)" = new.trycloudflare.com ]
[ "$(wc -l < "$ROOT/lookups")" -eq 65 ]

# Stop waiting only if the Argo service itself becomes inactive.
: > "$ROOT/lookups"
METRICS_MODE=no_domain
SERVICE_POLLS=0; STOP_AFTER=4
if argo_manual_wait_domain old.trycloudflare.com > "$ROOT/no-domain"; then
  echo 'Polling succeeded despite an inactive Argo service' >&2; exit 1
fi
[ ! -s "$ROOT/no-domain" ]
[ "$SERVICE_POLLS" -eq 4 ]
grep -qx old.trycloudflare.com "$WORK_DIR/argo-domain"
grep -qx old "$WORK_DIR/conf/node.json"
SERVICE_POLLS=0; STOP_AFTER=1000

# Subscription export failure still restores the previous domain and configuration.
fetch_quicktunnel_domain() {
  [ "$ARGO_MONITOR_VERIFIED_DOMAIN" = new.trycloudflare.com ]
  echo "$ARGO_MONITOR_VERIFIED_DOMAIN" > "$WORK_DIR/argo-domain"
  echo new > "$WORK_DIR/conf/node.json"
}
export_list() { [ "$EXPORT_OK" = 1 ]; }
EXPORT_OK=0
if argo_manual_publish_domain new.trycloudflare.com old.trycloudflare.com; then
  echo 'Failed export accepted' >&2; exit 1
fi
grep -qx old.trycloudflare.com "$WORK_DIR/argo-domain"
grep -qx old "$WORK_DIR/conf/node.json"
EXPORT_OK=1
argo_manual_publish_domain new.trycloudflare.com old.trycloudflare.com
grep -qx new.trycloudflare.com "$WORK_DIR/argo-domain"
grep -qx new "$WORK_DIR/conf/node.json"
echo 'PASS: new hostname without deadline, no DNS/HTTPS, old hostname ignored, stopped service and rollback'
