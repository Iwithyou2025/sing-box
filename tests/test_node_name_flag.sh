#!/usr/bin/env bash
# Regression: preserve/replace country flags in node renames, and update subscriptions safely.
set -euo pipefail
cd "$(dirname "$0")/.."
source <(sed -n \
  -e '/^node_name_keep_flag() {/,/^}/p' \
  -e '/^node_name_replace_files() {/,/^}/p' sing-box.sh)

assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'FAIL: expected [%s], got [%s]\n' "$2" "$1" >&2
    exit 1
  fi
}

for LANG_TEST in C C.UTF-8; do
  (
    export LC_ALL="$LANG_TEST"
    unset EMOJI4 EMOJI6
    assert_eq "$(node_name_keep_flag '🇺🇸 94ssh' 'Home & Office')" '🇺🇸 Home & Office'
    assert_eq "$(node_name_keep_flag '🇺🇸 94ssh' '🇩🇪 Berlin')" '🇩🇪 Berlin'
    assert_eq "$(node_name_keep_flag '🇺🇸 94ssh' '🇺🇸 Texas')" '🇺🇸 Texas'
    assert_eq "$(node_name_keep_flag '94ssh' 'Name')" 'Name'
    EMOJI4=🇺🇸
    assert_eq "$(node_name_keep_flag '94ssh' 'Recovered')" '🇺🇸 Recovered'
    assert_eq "$(node_name_keep_flag '94ssh' '🇯🇵 Tokyo')" '🇯🇵 Tokyo'
  )
done

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/conf" "$WORK_DIR/subscribe" "$WORK_DIR/cert"

cat > "$WORK_DIR/conf/12_hysteria2_inbounds.json" <<'EOF_JSON'
{"inbounds":[{"type":"hysteria2","tag":"🇺🇸 94ssh hysteria2","listen_port":8881,"users":[{"password":"fake"}]}]}
EOF_JSON
cat > "$WORK_DIR/conf/03_route.json" <<'EOF_JSON'
{"route":{"rules":[{"inbound":["🇺🇸 94ssh hysteria2"],"action":"route","outbound":"direct"}]}}
EOF_JSON
printf "u: &u '🇺🇸 94ssh'\n" > "$WORK_DIR/subscribe/clash"
printf '🇺🇸 94ssh unrelated binary contents\n' > "$WORK_DIR/sing-box"
printf '🇺🇸 94ssh unrelated key contents\n' > "$WORK_DIR/cert/private.key"

node_name_replace_files '🇺🇸 94ssh' '🇺🇸 New & Group | 42'
grep -Fq '🇺🇸 New & Group | 42 hysteria2' "$WORK_DIR/conf/12_hysteria2_inbounds.json"
grep -Fq '🇺🇸 New & Group | 42 hysteria2' "$WORK_DIR/conf/03_route.json"
grep -Fq "u: &u '🇺🇸 New & Group | 42'" "$WORK_DIR/subscribe/clash"
grep -Fq '🇺🇸 94ssh unrelated binary contents' "$WORK_DIR/sing-box"
grep -Fq '🇺🇸 94ssh unrelated key contents' "$WORK_DIR/cert/private.key"
! grep -Fq '🇺🇸 94ssh' "$WORK_DIR/conf/12_hysteria2_inbounds.json"
python3 - "$WORK_DIR/conf/12_hysteria2_inbounds.json" "$WORK_DIR/conf/03_route.json" <<'PY'
import json, sys
for file in sys.argv[1:]:
    with open(file, encoding="utf-8") as f:
        json.load(f)
PY

# Old names can contain regular-expression metacharacters.
printf '{"inbounds":[{"tag":"🇺🇸 old[1].node hysteria2"}]}\n' > "$WORK_DIR/conf/12_hysteria2_inbounds.json"
node_name_replace_files '🇺🇸 old[1].node' '🇺🇸 New (QA)'
grep -Fq '🇺🇸 New (QA) hysteria2' "$WORK_DIR/conf/12_hysteria2_inbounds.json"

echo 'PASS: country flag preservation, explicit replacement, recovered flag, safe config/subscription rename'
