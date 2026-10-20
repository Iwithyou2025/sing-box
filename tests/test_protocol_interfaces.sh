#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/conf"
NODE_TAG=(xtls-reality hysteria2 tuic ShadowTLS shadowsocks trojan vmess-ws vless-ws-tls h2-reality grpc-reality anytls naive)
jq_exec() { jq "$@"; }
# Only load the independently testable functions, not the installer entry point.
sed -n '/^# Per-protocol egress settings\./,/^generate_sing_box_base_conf() {/p' "$ROOT/sing-box.sh" | sed '$d' > "$WORK_DIR/functions.sh"
# shellcheck disable=SC1091
source "$WORK_DIR/functions.sh"
cat > "$WORK_DIR/conf/01_outbounds.json" <<'JSON'
{"outbounds":[{"type":"direct","tag":"direct","bind_interface":"tun0"}]}
JSON
cat > "$WORK_DIR/conf/03_route.json" <<'JSON'
{"route":{"rules":[{"action":"sniff"},{"inbound":["legacy"],"action":"route","outbound":"warp-ep"}]}}
JSON
printf '%s\n' '{"inbounds":[{"tag":"demo vmess-ws"}]}' > "$WORK_DIR/conf/17_vmess-ws_inbounds.json"
printf '%s\n' '{"inbounds":[{"tag":"demo vless-ws-tls"}]}' > "$WORK_DIR/conf/18_vless-ws-tls_inbounds.json"

# The installer may append non-JSON metadata to WS inbound files. The real
# sing-box runtime accepts this style, but jq on the complete file fails.
printf '%s\n' 'WS_SERVER_IP_SHOW=example.invalid' >> "$WORK_DIR/conf/17_vmess-ws_inbounds.json"
printf '%s\n' 'WS_SERVER_IP_SHOW=example.invalid' >> "$WORK_DIR/conf/18_vless-ws-tls_inbounds.json"
if jq -e . "$WORK_DIR/conf/17_vmess-ws_inbounds.json" >/dev/null 2>&1; then
  echo "FAIL: WS regression fixture must be non-JSON" >&2
  exit 1
fi

# Legacy globally bound direct must be migrated for both installed protocols.
iface_migrate
jq -e '."vmess-ws"=="tun0" and ."vless-ws-tls"=="tun0"' "$(iface_state)" >/dev/null
iface_sync
jq -e '[.outbounds[]|select(.tag=="sb-if-tun0")]|length==1' "$WORK_DIR/conf/01_outbounds.json" >/dev/null
jq -e '[.outbounds[]|select(.tag=="direct")|has("bind_interface")]|any|not' "$WORK_DIR/conf/01_outbounds.json" >/dev/null
jq -e '[.route.rules[]|select(.outbound=="sb-if-tun0")]|length==2' "$WORK_DIR/conf/03_route.json" >/dev/null
jq -e '.route.rules|any(.outbound=="warp-ep")' "$WORK_DIR/conf/03_route.json" >/dev/null

# Removing one protocol must retain the shared tun0 outbound for the other.
rm "$WORK_DIR/conf/17_vmess-ws_inbounds.json"
iface_sync
jq -e 'has("vmess-ws")|not' "$(iface_state)" >/dev/null
jq -e '[.outbounds[]|select(.tag=="sb-if-tun0")]|length==1' "$WORK_DIR/conf/01_outbounds.json" >/dev/null
jq -e '[.route.rules[]|select(.outbound=="sb-if-tun0")]|length==1' "$WORK_DIR/conf/03_route.json" >/dev/null

# Adding it back must not inherit old settings.
printf '%s\n' '{"inbounds":[{"tag":"new vmess-ws"}]}' > "$WORK_DIR/conf/17_vmess-ws_inbounds.json"
iface_sync
jq -e 'has("vmess-ws")|not' "$(iface_state)" >/dev/null
jq -e '[.route.rules[]|select(.outbound=="sb-if-tun0")]|length==1' "$WORK_DIR/conf/03_route.json" >/dev/null

# Explicitly assigning another interface creates a separate outbound.
jq '."vmess-ws"="eth0"' "$(iface_state)" > "$WORK_DIR/state.new"
mv "$WORK_DIR/state.new" "$(iface_state)"
iface_sync
jq -e '[.outbounds[]|select(.tag=="sb-if-eth0")]|length==1' "$WORK_DIR/conf/01_outbounds.json" >/dev/null
jq -e '[.route.rules[]|select(.outbound=="sb-if-eth0")]|length==1' "$WORK_DIR/conf/03_route.json" >/dev/null

# Invalid state must not modify existing generated outbounds or route rules.
cp "$WORK_DIR/conf/01_outbounds.json" "$WORK_DIR/outbound.before"
cp "$WORK_DIR/conf/03_route.json" "$WORK_DIR/route.before"
printf '%s\n' '{"vmess-ws":42}' > "$(iface_state)"
if iface_sync; then
  echo "FAIL: invalid interface state accepted" >&2
  exit 1
fi
cmp -s "$WORK_DIR/outbound.before" "$WORK_DIR/conf/01_outbounds.json"
cmp -s "$WORK_DIR/route.before" "$WORK_DIR/conf/03_route.json"
printf '%s\n' '{"vmess-ws":"eth0","vless-ws-tls":"tun0"}' > "$(iface_state)"

# Reverting both to default removes all dedicated objects without touching WARP.
printf '{}\n' > "$(iface_state)"
iface_sync
jq -e '[.outbounds[]|select(.tag|startswith("sb-if-"))]|length==0' "$WORK_DIR/conf/01_outbounds.json" >/dev/null
jq -e '[.route.rules[]|select(.outbound=="warp-ep")]|length==1' "$WORK_DIR/conf/03_route.json" >/dev/null
echo "PASS: per-protocol interface lifecycle regression tests"

# Static guard for the protocol-change transaction: the snapshot must remain
# available until after reload health verification, and failure must restore it.
awk '
  /# Apply the new protocol set. Keep a restorable snapshot until healthy./ { in_reload=1 }
  in_reload && /cmd_systemctl status sing-box/ { health=NR }
  in_reload && /cp -a.*IFACE_SNAPSHOT_DIR.*conf/ { restore=NR }
  in_reload && /rm -rf "\$IFACE_SNAPSHOT_DIR"/ { cleanup=NR; if (health && restore && cleanup>restore) good=1 }
  END { exit !good }
' "$ROOT/sing-box.sh"
echo "PASS: protocol reload rollback guard"
