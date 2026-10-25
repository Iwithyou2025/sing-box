#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
python3 - <<'PY' > "$ROOT/func.sh"
import re
from pathlib import Path
s=Path("sing-box.sh").read_text()
for name in ["argo_change_type","argo_change_lock","argo_change_valid_domain","argo_change_healthy","argo_change_rollback","argo_change_run","change_argo","export_argo_json_file"]:
 m=re.search(r'^'+name+r'\(\) [\{\(]',s,re.M);assert m,name
 n=re.search(r'^[A-Za-z_][\w-]*\(\) \{',s[m.end():],re.M)
 print(s[m.start():m.end()+n.start()] if n else s[m.start():])
PY
source "$ROOT/func.sh"
text() { echo 'not installed'; }
info() { :; }; hint() { :; }; warning() { :; }
error() { echo "Unexpected fatal" >&2; exit 1; }
check_install() { :; }
fetch_nodes_value() { ARGO_DOMAIN=old.example.com; PORT_NGINX=8000; }
sleep() { :; }; systemctl() { :; }
curl() { if [ "$HTTPS" = 1 ]; then echo 200; else echo 503; fi; }
argo_monitor_wait_domain() { echo new.trycloudflare.com; }
argo_monitor_publish_domain() { [ "$ARGO_CHANGE_ALLOW_PUBLISH" = 1 ] && echo "$1" > "$WORK_DIR/argo-domain"; }
create_argo_tunnel() { echo API >> "$EVENTS"; ARGO_TOKEN=$TOKEN_NEW; ARGO_JSON=$JSON_NEW; }
export_list() { [ "$EXPORT" = 1 ] || return 1; echo updated > "$WORK_DIR/subscribe/output"; }
cmd_systemctl() {
 echo "$*" >> "$EVENTS"
 case "$1" in
 status) [ "$ACTIVE" = 1 ];;
 restart)
  [ "$RESTART" = 1 ] || ! grep -Fq "$TOKEN_NEW" "$ARGO_DAEMON_FILE";;
 enable|disable) echo "Unexpected enable/disable" >&2; return 1;;
 esac
}
reading() {
 printf -v "$2" '%s' "${INPUTS[POSITION]:-}"
 POSITION=$((POSITION+1))
}
TOKEN_OLD=$(printf 'A%.0s' {1..140})
TOKEN_NEW=$(printf 'B%.0s' {1..140})
JSON_NEW='{"AccountTag":"account","TunnelSecret":"secret","TunnelID":"12345678-1234-1234-1234-123456789abc"}'
NODE_TAG=(xtls-reality hysteria2 tuic ShadowTLS shadowsocks trojan vmess-ws vless-ws-tls)
COUNT=0
setup() {
 local TYPE=$1
 COUNT=$((COUNT+1)); WORK_DIR="$ROOT/case-$COUNT"
 mkdir -p "$WORK_DIR/conf" "$WORK_DIR/subscribe"
 ARGO_DAEMON_FILE="$WORK_DIR/argo.service"; EVENTS="$WORK_DIR/events"; : > "$EVENTS"
 ln -s "$(command -v jq)" "$WORK_DIR/jq"
 printf '{"VMESS_HOST_DOMAIN":"old.example.com","test":1}\n' > "$WORK_DIR/conf/17_vmess-ws_inbounds.json"
 printf '{"server_name":"old.example.com","test":1}\n' > "$WORK_DIR/conf/18_vless-ws-tls_inbounds.json"
 echo original > "$WORK_DIR/subscribe/output"
 echo origin > "$WORK_DIR/list"
 SYSTEM=Ubuntu ACTIVE=1 RESTART=1 HTTPS=1 EXPORT=1 POSITION=0
 STATUS=(running running); INPUTS=()
 case "$TYPE" in
  Try) printf 'ExecStart=%s/cloudflared tunnel --url http://localhost:8000\n' "$WORK_DIR" > "$ARGO_DAEMON_FILE";;
  Token) printf 'ExecStart=%s/cloudflared tunnel run --token %s\n' "$WORK_DIR" "$TOKEN_OLD" > "$ARGO_DAEMON_FILE";;
  Json) printf 'ExecStart=%s/cloudflared tunnel --config %s/tunnel.yml run\n' "$WORK_DIR" "$WORK_DIR" > "$ARGO_DAEMON_FILE"
   echo '{"TunnelID":"original"}' > "$WORK_DIR/tunnel.json"
   echo 'hostname: old.example.com' > "$WORK_DIR/tunnel.yml";;
 esac
}
clean() {
 [ ! -d "$WORK_DIR/.argo-change.lock" ]
 [ -z "$(find "$WORK_DIR" -maxdepth 1 -name '.argo-change.*' -print)" ]
}
setup Try; [ "$(argo_change_type)" = Try ]
setup Token; [ "$(argo_change_type)" = Token ]
setup Json; [ "$(argo_change_type)" = Json ]
setup Try; INPUTS=(n); change_argo; ! grep -q restart "$EVENTS"; clean
setup Try; INPUTS=(y); change_argo; grep -qx 'restart argo' "$EVENTS"; grep -qx new.trycloudflare.com "$WORK_DIR/argo-domain"; clean
setup Token; INPUTS=(1); change_argo; grep -Fq "$TOKEN_OLD" "$ARGO_DAEMON_FILE"; grep -qx 'restart argo' "$EVENTS"; clean
setup Token; INPUTS=(2 new.example.com "$TOKEN_NEW"); change_argo
grep -Fq "$TOKEN_NEW" "$ARGO_DAEMON_FILE"; grep -q -- --token "$ARGO_DAEMON_FILE"
python3 -m json.tool "$WORK_DIR/conf/17_vmess-ws_inbounds.json" >/dev/null
python3 -m json.tool "$WORK_DIR/conf/18_vless-ws-tls_inbounds.json" >/dev/null
grep -Fq new.example.com "$WORK_DIR/conf/17_vmess-ws_inbounds.json"; clean
setup Token; INPUTS=(2 new.example.com short)
if change_argo; then echo 'bad credential accepted' >&2; exit 1; fi
grep -Fq "$TOKEN_OLD" "$ARGO_DAEMON_FILE"; clean
for F in restart https export; do
 setup Token
 case "$F" in restart) RESTART=0;; https) HTTPS=0;; export) EXPORT=0;; esac
 INPUTS=(2 new.example.com "$TOKEN_NEW")
 if change_argo; then echo "failed to rollback: $F" >&2; exit 1; fi
 grep -Fq "$TOKEN_OLD" "$ARGO_DAEMON_FILE"
 grep -qx original "$WORK_DIR/subscribe/output"; clean
done
setup Json; INPUTS=(2 new.example.com "$JSON_NEW"); change_argo
grep -q -- --config "$ARGO_DAEMON_FILE"
grep -q account "$WORK_DIR/tunnel.json"; grep -q new.example.com "$WORK_DIR/tunnel.yml"; clean
setup Json; INPUTS=(2 new.example.com '{"bad":true}')
if change_argo; then echo 'bad JSON accepted' >&2; exit 1; fi
grep -q original "$WORK_DIR/tunnel.json"; clean
setup Token; INPUTS=(2 new.example.com "$(printf 'C%.0s' {1..36})"); change_argo
grep -qx API "$EVENTS"; grep -q -- --token "$ARGO_DAEMON_FILE"; clean
setup Try; ACTIVE=0; INPUTS=(y)
if change_argo; then echo 'stopped Argo restarted' >&2; exit 1; fi
! grep -q '^restart' "$EVENTS"; clean
setup Try; mkdir "$WORK_DIR/.argo-change.lock"; echo "$BASHPID" > "$WORK_DIR/.argo-change.lock/pid"; INPUTS=(y)
if change_argo; then echo 'concurrent update was allowed' >&2; exit 1; fi
rm -rf "$WORK_DIR/.argo-change.lock"
setup Token; SYSTEM=Alpine
printf 'command="%s/cloudflared tunnel"\ncommand_args="run --token %s"\n' "$WORK_DIR" "$TOKEN_OLD" > "$ARGO_DAEMON_FILE"
[ "$(argo_change_type)" = Token ]; INPUTS=(1); change_argo; clean
grep -Fq '[ -d "$WORK_DIR/.argo-change.lock" ] && { FAILURES=0; continue; }' sing-box.sh
echo 'PASS: Argo tunnel Try/Token/Json, rollback, API, autostart, lock, OpenRC'
