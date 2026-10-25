#!/usr/bin/env bash
# VPS country is global; exercise real install/name/fetch/export functions offline.
set -eo pipefail
cd "$(dirname "$0")/.."
source <(python3 - <<'PY'
import re
from pathlib import Path
s=Path('sing-box.sh').read_text()
for name in ['input_node_name','node_country_flag_valid','node_country_flag_from_name',
             'node_country_flag_load','node_name_with_flag','node_names_apply_country',
             'node_name_replace_files','change_config','check_system_ip','system_ip_field',
             'is_valid_server_addr','sing-box_json','fetch_nodes_value','export_list','export_list_impl',
             'subscription_template_valid','subscription_prepare_templates','subscription_lock_acquire',
             'subscription_lock_release','subscription_stage_valid','subscription_publish',
             'sync_hy2_warp_route','asc','format_uri_host','format_ports_display','jq_exec','multiplex_json','load_multiplex_state']:
    match=re.search(r'^'+re.escape(name)+r'\(\) \{',s,re.M)
    if not match: raise SystemExit('Missing function: '+name)
    end=re.search(r'^[a-zA-Z_][\w-]*\(\) \{',s[match.end():],re.M)
    print(s[match.start():match.end()+end.start()] if end else s[match.start():])
PY
)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
# External effects are replaced: GeoIP transport, service manager and template downloads.
# The installer, config reader, renamer, GeoIP parser and subscription exporter are real.
ip() { :; }
wget() {
  printf '%s\n' "$*" >> "$ROOT/lookups"
  case " $* " in
    *ipdata.free*)
      case " $* " in
        *' -4 '*) printf '%s\n' "${GEO4_IPDATA:-$GEO4}" ;;
        *' -6 '*) printf '%s\n' "${GEO6_IPDATA:-$GEO6}" ;;
      esac ;;
    *ip.cloudflare.now.cc*)
      case " $* " in
        *' -4 '*) printf '%s\n' "$GEO4" ;;
        *' -6 '*) printf '%s\n' "$GEO6" ;;
      esac ;;
    *) echo "Unexpected network request: $*" >&2; return 1 ;;
  esac
}
text() { printf 'text-%s' "$1"; }
hint() { printf '%s\n' "$*"; }; info() { printf '%s\n' "$*"; }; warning() { printf '%s\n' "$*"; }
error() { printf '%s\n' "$*" >&2; exit 1; }
cmd_systemctl() { printf '%s\n' "$*" >> "$ROOT/services"; }
check_port_hopping_nat() { :; }
ensure_stats_data() { return 1; }
statistics_of_run_times() { :; }
argo_monitor_sync() { :; }
fetch_quicktunnel_domain() { ARGO_DOMAIN=example.trycloudflare.com; }
reading() {
  case "$2" in
    NODE_NAME_INPUT|NEW_VAL) printf -v "$2" '%s' "$TEST_INPUT" ;;
    CHOOSE_NODE_INFO)
      local i
      for i in "${!MENU_KEY[@]}"; do
        if [[ "${MENU_KEY[i]}" == name ]]; then printf -v "$2" '%s' "$((i+1))"; break; fi
      done ;;
    *) echo "Unexpected prompt: $2" >&2; exit 1 ;;
  esac
}
check_install() {
  cat > "$TEMP_DIR/clash" <<'YAML'
u: &u 'NODE_NAME'
proxy-providers:
  nodes:
    type: http
    url: 'PROXY_PROVIDERS_URL'
YAML
  printf 'proxies:\nproxy-groups: []\nrules: []\n' > "$TEMP_DIR/clash2"
  cat > "$TEMP_DIR/sing-box-template" <<'JSON'
{"outbounds":["<OUTBOUND_REPLACE>", {"type":"selector","tag":"proxy","outbounds":["<NODE_REPLACE>"]}]}
JSON
}
generate_sing_box_base_conf() {
  printf '{"route":{"rules":[]}}\n' > "$WORK_DIR/conf/03_route.json"
  printf '{"experimental":{"clash_api":{}}}\n' > "$WORK_DIR/conf/04_experimental.json"
}
assert_eq() {
  if [[ "$1" != "$2" ]]; then printf 'FAIL: expected [%s], got [%s]\n' "$2" "$1" >&2; exit 1; fi
}
assert_files() {
  python3 - "$WORK_DIR" "$1" <<'PY'
import sys,json,base64
from pathlib import Path
p=Path(sys.argv[1]);name=sys.argv[2]
# Actual generated formats, including base64-wrapped subscriptions.
for f in ['proxies','clash2','sing-box','v2rayn','throne','shadowrocket']:
    data=(p/'subscribe'/f).read_text()
    if f in ['v2rayn','throne','shadowrocket']:
        data=base64.b64decode(data).decode()
    expected=name.replace(' ','%20') if f in ['v2rayn','throne','shadowrocket'] else name
    assert expected+'%20vless-ws-tls' in data if f in ['v2rayn','throne','shadowrocket'] else expected+' vless-ws-tls' in data, (f,data[:200])
    assert '🇺🇸' not in data and '🇯🇵' not in data and '🇬🇧' not in data, f
js=json.loads((p/'subscribe/sing-box').read_text())
assert {o['tag'] for o in js['outbounds'] if o['type']!='selector'} == {name+' '+t for t in ['hysteria2','vmess-ws','vless-ws-tls']}
assert name in (p/'subscribe/clash').read_text()
assert name+' vless-ws-tls' in (p/'list').read_text()
PY
}
setup() {
  WORK_DIR="$ROOT/case-$((CASE_NO++))"
  TEMP_DIR="$WORK_DIR/tmp"
  mkdir -p "$WORK_DIR"/{conf,subscribe,cert} "$TEMP_DIR"
  ln -s "$(command -v jq)" "$WORK_DIR/jq"
  ln -s "$(command -v jq)" "$TEMP_DIR/jq"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=example.com -addext subjectAltName=DNS:example.com -keyout "$WORK_DIR/cert/private.key" -out "$WORK_DIR/cert/cert.pem" >/dev/null 2>&1
  cat > "$TEMP_DIR/sing-box" <<'SH'
#!/usr/bin/env bash
printf 'PrivateKey: fixture-private\nPublicKey: fixture-public\n'
SH
  chmod +x "$TEMP_DIR/sing-box"
  cp "$TEMP_DIR/sing-box" "$WORK_DIR/sing-box"
  NODE_TAG=(xtls-reality hysteria2 tuic ShadowTLS shadowsocks trojan vmess-ws vless-ws-tls h2-reality grpc-reality anytls naive)
  INSTALL_PROTOCOLS=(c h i)
  GEO4='{"ip":"192.0.2.44","country":"Germany","emoji":"🇩🇪","isp":"Test ISP"}'
  GEO6=''
  unset SYSTEM_IP_CHECKED NODE_COUNTRY_FLAG NODE_NAME_CONFIRM NODE_NAME WAN4 WAN6 EMOJI4 EMOJI6 ASNORG4 ASNORG6
  unset PORT_HYSTERIA2 PORT_VMESS_WS PORT_VLESS_WS REALITY_PRIVATE REALITY_PUBLIC UUID WS_SERVER_IP CDN_PORT
  IS_ARGO_MONITOR='' IS_INSTALL='' IS_FAST_INSTALL='' NONINTERACTIVE_INSTALL='' IS_ARGO=no_argo IS_SUB=no_sub IS_BRUTAL=false IS_TUN=no_tun
  STATUS=('text-28' direct) L=C C=() STEP_NUM=0
  SERVER_IP=192.0.2.44 START_PORT=8881 CDN=example.com UUID_CONFIRM=00000000-0000-4000-8000-000000000000
  VMESS_HOST_DOMAIN=example.com VLESS_HOST_DOMAIN=example.com PORT_NGINX=8000 ARGO_TYPE='' FINGER_PRINT=chrome
  ARGO_DAEMON_FILE="$WORK_DIR/argo.service"
  : > "$ARGO_DAEMON_FILE"
  : > "$ROOT/lookups"; : > "$ROOT/services"
}
CASE_NO=0
for LOCALE_TEST in C C.UTF-8; do
  export LC_ALL="$LOCALE_TEST"
  setup
  # Fresh interactive install: a hand-entered US flag cannot override the German VPS.
  TEST_INPUT='🇺🇸94vps'
  input_node_name
  assert_eq "$NODE_NAME_CONFIRM" '🇩🇪 94vps'
  assert_eq "$(cat "$WORK_DIR/vps-country-flag")" $'🇩🇪\n192.0.2.44'
  sing-box_json
  export_list install > "$ROOT/output"
  assert_files '🇩🇪 94vps'
  assert_eq "$(wc -l < "$ROOT/lookups")" 2
  # Old configs may have missing/doubled/incorrect flags: all export formats must use VPS country.
  sed -i 's/🇩🇪 94vps/🇺🇸 94vps/g' "$WORK_DIR/conf/12_hysteria2_inbounds.json"
  sed -i 's/🇩🇪 94vps/94vps/g' "$WORK_DIR/conf/17_vmess-ws_inbounds.json"
  sed -i 's/🇩🇪 94vps/🇯🇵 🇺🇸94vps/g' "$WORK_DIR/conf/18_vless-ws-tls_inbounds.json"
  printf '🇺🇸\n' > "$WORK_DIR/node-country-flag"
  NODE_NAME_CONFIRM='🇺🇸 94vps'
  for MODE in direct argo; do
    STATUS[1]=direct IS_ARGO=no_argo
    [[ "$MODE" == argo ]] && STATUS[1]=text-28 && IS_ARGO=is_argo
    export_list > "$ROOT/output"
    assert_files '🇩🇪 94vps'
  done
  STATUS[1]=direct IS_ARGO=no_argo
  # -d shortcut: no main-loop IP detection; changing only text corrects old US labels.
  unset SYSTEM_IP_CHECKED
  printf '{"route":{"rules":[{"inbound":["🇺🇸 94vps hysteria2","94vps vmess-ws","🇯🇵 🇺🇸94vps vless-ws-tls"],"outbound":"direct"}]}}\n' > "$WORK_DIR/conf/03_route.json"
  for TEST_INPUT in '94949' '🇯🇵Tokyo' '🇺🇸 🇬🇧Berlin'; do
    change_config > "$ROOT/output"
    EXPECTED='🇩🇪 94949'
    [[ "$TEST_INPUT" == '🇯🇵Tokyo' ]] && EXPECTED='🇩🇪 Tokyo'
    [[ "$TEST_INPUT" == '🇺🇸 🇬🇧Berlin' ]] && EXPECTED='🇩🇪 Berlin'
    assert_files "$EXPECTED"
    for SUFFIX in hysteria2 vmess-ws vless-ws-tls; do
      grep -Fq "\"tag\":\"$EXPECTED $SUFFIX\"" "$WORK_DIR"/conf/*_"$SUFFIX"_inbounds.json
      grep -Fq "\"$EXPECTED $SUFFIX\"" "$WORK_DIR/conf/03_route.json"
    done
  done
  # Refresh with the API unavailable uses only the global IP-derived cache.
  GEO4='' GEO6=''
  unset SYSTEM_IP_CHECKED
  TEST_INPUT=offline
  change_config > "$ROOT/output"
  assert_files '🇩🇪 offline'
  # Invalid/empty input must not change config or trigger a service reload.
  BEFORE=$(cat "$WORK_DIR/conf/18_vless-ws-tls_inbounds.json")
  SERVICE_BEFORE=$(cat "$ROOT/services")
  for TEST_INPUT in 'bad"name' "bad'name" 'bad\name' $'bad\nname' $'bad\rname' $'bad\tname' '🇩🇪' '   '; do
    if change_config > "$ROOT/output" 2>/dev/null; then echo 'FAIL: invalid name accepted' >&2; exit 1; fi
    assert_eq "$(cat "$WORK_DIR/conf/18_vless-ws-tls_inbounds.json")" "$BEFORE"
    assert_eq "$(cat "$ROOT/services")" "$SERVICE_BEFORE"
  done
  TEST_INPUT=''
  change_config > "$ROOT/output"
  assert_eq "$(cat "$WORK_DIR/conf/18_vless-ws-tls_inbounds.json")" "$BEFORE"
  # Background Argo export uses the same cache without redoing GeoIP.
  IS_ARGO_MONITOR=1
  unset SYSTEM_IP_CHECKED
  LOOKUPS_BEFORE=$(cat "$ROOT/lookups")
  export_list > "$ROOT/output"
  assert_files '🇩🇪 offline'
  assert_eq "$(cat "$ROOT/lookups")" "$LOOKUPS_BEFORE"
  # All protocol names share the same country, independent of bind-interface choices.
  NODE_NAME=()
  for I in {11..22}; do NODE_NAME[I]='🇺🇸 old'; done
  node_names_apply_country
  for I in {11..22}; do assert_eq "${NODE_NAME[I]}" '🇩🇪 old'; done
  # Noninteractive names and defaults are normalized as well.
  IS_ARGO_MONITOR=''; NONINTERACTIVE_INSTALL=noninteractive_install
  NODE_NAME_CONFIRM='🇺🇸 automatic'
  input_node_name
  assert_eq "$NODE_NAME_CONFIRM" '🇩🇪 automatic'
  unset NODE_NAME_CONFIRM
  input_node_name
  assert_eq "$NODE_NAME_CONFIRM" "🇩🇪 $(hostname)"
  # Failed lookup without trusted cache must leave the old configuration untouched.
  mv "$WORK_DIR/vps-country-flag" "$WORK_DIR/cache.saved"
  TEST_INPUT=no-cache
  if change_config > "$ROOT/output" 2>/dev/null; then echo 'FAIL: guessed country from old node name' >&2; exit 1; fi
  assert_eq "$(cat "$WORK_DIR/conf/18_vless-ws-tls_inbounds.json")" "$BEFORE"
  # A corrupt cache must not revive the old manual cache either.
  printf '🇺\n192.0.2.44\n' > "$WORK_DIR/vps-country-flag"
  if node_country_flag_load 2>/dev/null; then echo 'FAIL: corrupt cache accepted' >&2; exit 1; fi
  # No reuse of a stale transient response after failure.
  printf '%s\n' '{"ip":"198.51.100.2","emoji":"🇺🇸"}' > "$TEMP_DIR/ip4.json"
  check_system_ip
  assert_eq "${WAN4:-}${EMOJI4:-}" ''
  # Dual-provider disagreement: ipdata country_code/flag wins for the same IPv4.
  GEO4='{"ip":"192.0.2.44","country":"United States","emoji":"🇺🇸","isp":"Primary ISP"}'
  GEO4_IPDATA='{"ip":"192.0.2.44","country_code":"DE","country_name":"Germany","flag":{"emoji":"🇩🇪"},"organisation":"Secondary ISP"}'
  unset SYSTEM_IP_CHECKED
  check_system_ip
  assert_eq "$WAN4" '192.0.2.44'
  assert_eq "$EMOJI4" '🇩🇪'
  assert_eq "$COUNTRY4" 'DE'
  # When the providers agree, retain the primary response.
  GEO4='{"ip":"192.0.2.44","country":"Germany","emoji":"🇩🇪","isp":"Primary ISP"}'
  GEO4_IPDATA='{"ip":"192.0.2.44","country_code":"DE","country_name":"Germany","flag":{"emoji":"🇩🇪"},"organisation":"Secondary ISP"}'
  unset SYSTEM_IP_CHECKED
  check_system_ip
  assert_eq "$EMOJI4" '🇩🇪'
  # If the primary source fails, use a valid ipdata response.
  GEO4=''
  GEO4_IPDATA='{"ip":"192.0.2.44","country_code":"DE","country_name":"Germany","flag":{"emoji":"🇩🇪"},"organisation":"Secondary ISP"}'
  unset SYSTEM_IP_CHECKED
  check_system_ip
  assert_eq "$WAN4" '192.0.2.44'
  assert_eq "$EMOJI4" '🇩🇪'
  GEO4='{"ip":"192.0.2.44","country":"Germany","emoji":"🇩🇪","isp":"Primary ISP"}'
  unset GEO4_IPDATA
  # IPv6-only + pretty JSON; new GeoIP beats an old global cache.
  mv "$WORK_DIR/cache.saved" "$WORK_DIR/vps-country-flag"
  GEO6=$'{\n "emoji": "🇫🇷",\n "isp": "Native",\n "country": "France",\n "ip": "2001:db8::44"\n}'
  unset SYSTEM_IP_CHECKED
  node_country_flag_load
  assert_eq "$NODE_COUNTRY_FLAG" '🇫🇷'
  # Explicitly selected IPv6 and native address selection on WARP match VPS-wide country.
  GEO4='{"ip":"192.0.2.44","emoji":"🇺🇸","isp":"Cloudflare"}'
  check_system_ip
  node_country_flag_load
  assert_eq "$NODE_COUNTRY_FLAG" '🇫🇷'
  ASNORG4=Native SERVER_IP=2001:db8::44
  node_country_flag_load
  assert_eq "$NODE_COUNTRY_FLAG" '🇫🇷'
  # Known changed IP with no valid flag cannot fall back to a different VPS cache.
  GEO4='{"ip":"203.0.113.8","emoji":"broken"}' GEO6=''
  check_system_ip
  if node_country_flag_load 2>/dev/null; then echo 'FAIL: cache reused for changed IP' >&2; exit 1; fi
  echo "PASS: $LOCALE_TEST — real install, mixed old configs, rename, all exports, cache, IPv6, WARP, malformed input and lookup failure"
done
# Rebuilding configs / adding a protocol applies the same country to tags and route references.
(
  setup
  TEST_INPUT=94vps
  input_node_name
  sing-box_json
  printf '{"route":{"rules":[{"inbound":["🇩🇪 94vps hysteria2","🇩🇪 94vps vmess-ws","🇩🇪 94vps vless-ws-tls"],"outbound":"direct"}]}}\n' > "$WORK_DIR/conf/03_route.json"
  GEO4='{"ip":"192.0.2.44","emoji":"🇫🇷","isp":"Native"}'
  unset SYSTEM_IP_CHECKED
  fetch_nodes_value
  sing-box_json change
  export_list > "$ROOT/output"
  assert_files '🇫🇷 94vps'
  for SUFFIX in hysteria2 vmess-ws vless-ws-tls; do
    grep -Fq "\"🇫🇷 94vps $SUFFIX\"" "$WORK_DIR/conf/03_route.json"
  done
  INSTALL_PROTOCOLS+=(l)
  sing-box_json change
  grep -Fq '"tag":"🇫🇷 94vps anytls"' "$WORK_DIR/conf/21_anytls_inbounds.json"
  export_list > "$ROOT/output"
  grep -Fq 'name: "🇫🇷 94vps anytls"' "$WORK_DIR/subscribe/proxies"
)
echo 'PASS: regeneration updates route references; newly added protocol uses the same VPS flag'
