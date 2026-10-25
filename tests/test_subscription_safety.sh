#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source <(python3 - <<'PY'
from pathlib import Path
import re
s=Path("sing-box.sh").read_text()
for name in ["subscription_template_valid","subscription_prepare_templates","subscription_lock_acquire","subscription_lock_release","subscription_stage_valid","subscription_publish"]:
    m=re.search(r'^'+name+r'\(\) \{',s,re.M); assert m,name
    e=re.search(r'^[a-zA-Z_][\w-]*\(\) \{',s[m.end():],re.M)
    print(s[m.start():m.end()+e.start()] if e else s[m.start():])
PY
)
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
WORK_DIR="$ROOT/work"; TEMP_DIR="$ROOT/tmp"; mkdir -p "$WORK_DIR/subscribe" "$TEMP_DIR"
ln -s "$(command -v jq)" "$WORK_DIR/jq"
GH_PROXY='' SUBSCRIBE_TEMPLATE='https://invalid.local'
wget() { echo called >> "$ROOT/wget"; return 1; }
mkdir -p "$WORK_DIR/.subscription-templates"
cat > "$WORK_DIR/.subscription-templates/clash" <<'END'
proxy-providers:
  nodes:
    url: 'PROXY_PROVIDERS_URL'
END
printf 'proxies:\nproxy-groups: []\nrules: []\n' > "$WORK_DIR/.subscription-templates/clash2"
printf '{"outbounds":["<OUTBOUND_REPLACE>"],"select":["<NODE_REPLACE>"]}\n' > "$WORK_DIR/.subscription-templates/sing-box-template"
STAGE="$ROOT/stage"; mkdir -p "$STAGE"
subscription_prepare_templates "$STAGE"
[ ! -f "$ROOT/wget" ]
subscription_template_valid clash "$STAGE/templates/clash"
# Missing/corrupted template must fail, never substitute an empty download.
rm -f "$WORK_DIR/.subscription-templates/clash" "$STAGE/templates/clash"
if subscription_prepare_templates "$STAGE"; then echo 'unexpected template success' >&2; exit 1; fi
printf 'junk' > "$STAGE/templates/clash"
if subscription_template_valid clash "$STAGE/templates/clash"; then exit 1; fi

OUT="$STAGE/output"; mkdir -p "$OUT"
for name in proxies clash clash2 sing-box v2rayn throne shadowrocket list; do
    printf 'new %s\n' "$name" > "$OUT/$name"
    printf 'old %s\n' "$name" > "$WORK_DIR/subscribe/$name"
done
printf '{"outbounds":[]}\n' > "$OUT/sing-box"
printf 'proxy-providers:\n  providers: {}\n' > "$OUT/clash"
printf 'proxy-groups:\n  - name: hello\n' > "$OUT/clash2"
printf 'old list\n' > "$WORK_DIR/list"
printf 'new list\n' > "$OUT/list"
subscription_stage_valid "$OUT"
: > "$OUT/clash"
if subscription_stage_valid "$OUT"; then echo 'empty clash accepted' >&2; exit 1; fi
printf 'proxy-providers:\n' > "$OUT/clash"
printf '{ invalid }\n' > "$OUT/sing-box"
if subscription_stage_valid "$OUT"; then echo 'invalid sing-box JSON accepted' >&2; exit 1; fi
printf '{"outbounds":[]}\n' > "$OUT/sing-box"
# Inject a failure halfway through live renames. Every previously published file must be restored.
(
  mv() {
    if [[ "${3:-}" == "$WORK_DIR/subscribe/clash2" ]]; then return 1; fi
    command mv "$@"
  }
  if subscription_publish "$OUT" "$STAGE"; then echo 'publish failure undetected' >&2; exit 1; fi
)
for name in proxies clash clash2 sing-box v2rayn throne shadowrocket; do
    grep -qx "old $name" "$WORK_DIR/subscribe/$name"
done
grep -qx 'old list' "$WORK_DIR/list"
# Successful publication now replaces every file, preserving nonempty data.
subscription_publish "$OUT" "$STAGE"
for name in proxies clash clash2 sing-box v2rayn throne shadowrocket; do
    [ -s "$WORK_DIR/subscribe/$name" ]
done
grep -qx 'new list' "$WORK_DIR/list"
subscription_lock_acquire
if flock -n "$WORK_DIR/.subscription-export.lock" -c ':'; then
  echo 'concurrent subscription writer acquired a held lock' >&2
  exit 1
fi
subscription_lock_release
flock -n "$WORK_DIR/.subscription-export.lock" -c ':'
echo 'PASS: cached templates, missing/invalid templates, zero-byte prevention, JSON validation, rollback and publish'
