#!/usr/bin/env bash
# Regression for menu-driven node renaming and generated client names.
set -euo pipefail
cd "$(dirname "$0")/.."
source <(sed -n \
  -e '/^input_node_name() {/,/^}/p' \
  -e '/^change_config() {/,/^}/p' \
  -e '/^node_country_flag_valid() {/,/^}/p' \
  -e '/^node_country_flag_from_name() {/,/^}/p' \
  -e '/^node_country_flag_resolve() {/,/^}/p' \
  -e '/^node_name_keep_flag() {/,/^}/p' \
  -e '/^node_name_replace_files() {/,/^}/p' sing-box.sh)

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/conf" "$WORK_DIR/subscribe" "$WORK_DIR/cert"

assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'FAIL: expected [%s], got [%s]\n' "$2" "$1" >&2
    exit 1
  fi
}
assert_json() {
  python3 - "$@" <<'PY'
import json, sys
for filename in sys.argv[1:]:
    with open(filename, encoding='utf-8') as file:
        json.load(file)
PY
}
reset_case() {
  rm -f "$WORK_DIR"/conf/*.json "$WORK_DIR"/node-country-flag "$WORK_DIR"/subscribe/*
  unset EMOJI4 EMOJI6
}
write_inbound() {
  local filename=$1 tag=$2
  printf '{"inbounds":[{"type":"vmess","tag":"%s","listen_port":8881}]}\n' "$tag" > "$WORK_DIR/conf/$filename"
}
read_menu_name() {
  awk '/"tag"/{gsub(/^.*"tag": *"/,""); gsub(/".*/,""); sub(/ [^ ]*$/,""); print; exit}' "$WORK_DIR"/conf/*_inbounds.json 2>/dev/null
}
read_vm_name() {
  local json
  json=$(cat "$WORK_DIR/conf/17_vmess-ws_inbounds.json")
  sed -n 's/.*"tag":"\(.*\) vmess-ws.*/\1/p' <<< "$json"
}

# Locale-neutral detection of actual regional-indicator flag bytes.
for LOCALE_TEST in C C.UTF-8; do
  (
    export LC_ALL="$LOCALE_TEST"
    reset_case
    assert_eq "$(node_name_keep_flag '🇺🇸 94ssh' '94949')" '🇺🇸 94949'
    assert_eq "$(node_name_keep_flag '🇺🇸 94ssh' '🇩🇪 Berlin')" '🇩🇪 Berlin'
    assert_eq "$(node_name_keep_flag '94ssh' '94949')" '94949'
    EMOJI4=🇺🇸
    assert_eq "$(node_name_keep_flag '94ssh' '94949')" '🇺🇸 94949'
  )
done

# End-to-end of actual change_config menu name extraction -> rename -> fetch_nodes_value extraction.
reset_case
write_inbound '17_vmess-ws_inbounds.json' '🇺🇸 94ssh vmess-ws'
printf "u: &u '🇺🇸 94ssh'\n" > "$WORK_DIR/subscribe/clash"
printf '🇺🇸 94ssh binary marker\n' > "$WORK_DIR/sing-box"
printf '🇺🇸 94ssh private marker\n' > "$WORK_DIR/cert/private.key"
OLD=$(read_menu_name)
assert_eq "$OLD" '🇺🇸 94ssh'
NEW=$(node_name_keep_flag "$OLD" '94949')
assert_eq "$NEW" '🇺🇸 94949'
node_name_replace_files "$OLD" "$NEW"
assert_eq "$(read_vm_name)" '🇺🇸 94949'
assert_eq "$(printf 'name: "%s vmess-ws"' "$(read_vm_name)")" 'name: "🇺🇸 94949 vmess-ws"'
grep -Fq "u: &u '🇺🇸 94949'" "$WORK_DIR/subscribe/clash"
grep -Fq '🇺🇸 94ssh binary marker' "$WORK_DIR/sing-box"
grep -Fq '🇺🇸 94ssh private marker' "$WORK_DIR/cert/private.key"
assert_json "$WORK_DIR/conf/17_vmess-ws_inbounds.json"

# Another inbound still has a flag even if first file lost it.
reset_case
write_inbound '12_hysteria2_inbounds.json' '94ssh hysteria2'
write_inbound '17_vmess-ws_inbounds.json' '🇺🇸 94ssh vmess-ws'
assert_eq "$(node_name_keep_flag '94ssh' '94949')" '🇺🇸 94949'

# Historical names all lost their flag, but persisted installation state remains.
reset_case
write_inbound '17_vmess-ws_inbounds.json' '94ssh vmess-ws'
printf '🇺🇸\n' > "$WORK_DIR/node-country-flag"
assert_eq "$(node_name_keep_flag '94ssh' '94949')" '🇺🇸 94949'

# Explicitly chosen new country must never become duplicated.
assert_eq "$(node_name_keep_flag '94ssh' '🇩🇪 Berlin')" '🇩🇪 Berlin'

# Special characters must not be treated as sed replacement expressions.
reset_case
write_inbound '17_vmess-ws_inbounds.json' '🇺🇸 old[1].node vmess-ws'
node_name_replace_files '🇺🇸 old[1].node' '🇺🇸 New & Group | 42'
assert_eq "$(read_vm_name)" '🇺🇸 New & Group | 42'
assert_json "$WORK_DIR/conf/17_vmess-ws_inbounds.json"
echo 'PASS: exact user VMess rename, country-flag recovery, locale neutrality, cache, and JSON integrity'

# Attached flags, flag-only names, invalid prefixes, and repeated edits.
for LOCALE_TEST in C C.UTF-8; do
  (
    export LC_ALL="$LOCALE_TEST"
    reset_case
    for NAME in '🇩🇪德国' '🇩🇪 Germany' '🇩🇪' '🇯🇵東京' '🇬🇧London'; do
      assert_eq "$(node_name_keep_flag '🇺🇸 old' "$NAME")" "$NAME"
    done
    for NAME in '🇩' '🏳️ name' '德国' 'DE Berlin'; do
      assert_eq "$(node_name_keep_flag '🇺🇸 old' "$NAME")" "🇺🇸 $NAME"
    done
    assert_eq "$(node_name_keep_flag '🇩🇪德国' 'Berlin')" '🇩🇪 Berlin'
    assert_eq "$(node_name_keep_flag '🇩🇪德国' '🇯🇵東京')" '🇯🇵東京'
    # Fresh installation uses the actual prompt path with conflicting GeoIP.
    set +u
    text() { :; }
    reading() { printf -v "$2" '%s' "$TEST_INPUT"; }
    EMOJI4=🇺🇸
    for TEST_INPUT in '🇩🇪德国' '🇩🇪 Germany' 'Berlin'; do
      unset NODE_NAME_CONFIRM
      input_node_name
      EXPECTED="$TEST_INPUT"
      [[ "$TEST_INPUT" == Berlin ]] && EXPECTED='🇺🇸 Berlin'
      assert_eq "$NODE_NAME_CONFIRM" "$EXPECTED"
      assert_eq "$(cat "$WORK_DIR/node-country-flag")" "$(node_country_flag_from_name "$EXPECTED")"
    done
    TEST_INPUT=''
    unset NODE_NAME_CONFIRM
    input_node_name
    assert_eq "$NODE_NAME_CONFIRM" "🇺🇸 $(hostname)"
    # Real menu path: old installation, route references, template and cache.
    hint() { :; }; info() { :; }; warning() { :; }
    format_ports_display() { printf '%s' "$*"; }
    cmd_systemctl() { RELOADED=yes; }
    export_list() { EXPORTED="$NODE_NAME_CONFIRM"; }
    reading() {
      case "$2" in
        CHOOSE_NODE_INFO)
          for i in "${!MENU_KEY[@]}"; do
            [[ "${MENU_KEY[i]}" == name ]] && printf -v "$2" '%s' "$((i+1))" && break
          done ;;
        NEW_VAL) printf -v "$2" '%s' "$TEST_INPUT" ;;
      esac
    }
    L=C
    declare -a C=()
    reset_case
    EMOJI4=🇺🇸
    write_inbound '17_vmess-ws_inbounds.json' '🇺🇸 old vmess-ws'
    printf "u: &u '🇺🇸 old'\n" > "$WORK_DIR/subscribe/clash"
    printf '{"rules":[{"inbound":["🇺🇸 old vmess-ws"]}]}\n' > "$WORK_DIR/conf/03_route.json"
    NODE_NAME_CONFIRM='🇺🇸 stale'
    for TEST_INPUT in '🇩🇪德国' 'Berlin' '🇯🇵Tokyo'; do
      change_config
      EXPECTED="$TEST_INPUT"
      [[ "$TEST_INPUT" == Berlin ]] && EXPECTED='🇩🇪 Berlin'
      assert_eq "$(read_vm_name)" "$EXPECTED"
      assert_eq "$EXPORTED" "$EXPECTED"
      assert_eq "$RELOADED" yes
      grep -Fq "$EXPECTED vmess-ws" "$WORK_DIR/conf/03_route.json"
      grep -Fq "$EXPECTED" "$WORK_DIR/subscribe/clash"
      assert_eq "$(cat "$WORK_DIR/node-country-flag")" "$(node_country_flag_from_name "$EXPECTED")"
      assert_json "$WORK_DIR/conf/17_vmess-ws_inbounds.json" "$WORK_DIR/conf/03_route.json"
    done
    # Rejected names must leave configs/cache unchanged and skip reload/export.
    BEFORE=$(cat "$WORK_DIR/conf/17_vmess-ws_inbounds.json")
    for TEST_INPUT in 'bad"name' "bad'name" 'bad\name' $'bad\nname'; do
      RELOADED=no; EXPORTED=no
      if change_config; then echo 'FAIL: invalid name accepted'; exit 1; fi
      assert_eq "$(cat "$WORK_DIR/conf/17_vmess-ws_inbounds.json")" "$BEFORE"
      assert_eq "$(cat "$WORK_DIR/node-country-flag")" '🇯🇵'
      assert_eq "$RELOADED" no
      assert_eq "$EXPORTED" no
    done
    TEST_INPUT=''
    change_config
    assert_eq "$(cat "$WORK_DIR/conf/17_vmess-ws_inbounds.json")" "$BEFORE"
  )
done
echo 'PASS: fresh install, actual rename menu, repeated country changes, stale export state, invalid input, and locale matrix'
