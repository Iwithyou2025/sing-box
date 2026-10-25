#!/usr/bin/env bash
# Verify actual Argo prompts honor the selected language.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
WORK_DIR="$ROOT"
mkdir -p "$WORK_DIR/conf" "$WORK_DIR/subscribe"
python3 - <<'PY' > "$ROOT/i18n-functions.sh"
import re
from pathlib import Path
s = Path("sing-box.sh").read_text()
for name in ["i18n_message", "select_language", "argo_change_run"]:
    m = re.search(r'^' + name + r'\(\) [\{\(]', s, re.M)
    assert m, name
    n = re.search(r'^[A-Za-z_][\w-]*\(\) [\{\(]', s[m.end():], re.M)
    assert n, name
    print(s[m.start():m.end()+n.start()])
PY
source "$ROOT/i18n-functions.sh"
info() { printf '%s\n' "$*"; }
warning() { printf '%s\n' "$*"; }
hint() { printf '%s\n' "$*"; }
reading() { :; }
cmd_systemctl() { return 0; }
argo_change_lock() {
  mkdir "$WORK_DIR/.argo-change.lock"
  printf '%s\n' "$BASHPID" > "$WORK_DIR/.argo-change.lock/pid"
}
argo_manual_wait_domain() {
  [ "$1" = old.trycloudflare.com ]
  printf '%s\n' new.trycloudflare.com
}
argo_manual_publish_domain() {
  [ "$1" = new.trycloudflare.com ] && [ "$2" = old.trycloudflare.com ]
}
printf C > "$WORK_DIR/language"
L=''
select_language
[ "$L" = C ]
CHINESE=$(argo_change_run Try rebuild old.trycloudflare.com '' '')
grep -Fq '正在重启 Argo' <<< "$CHINESE"
grep -Fq '新的 Argo 域名' <<< "$CHINESE"
grep -Fq '订阅已同步' <<< "$CHINESE"
if grep -Eq 'Restarting Argo|New Argo domain|Argo changed and subscriptions updated' <<< "$CHINESE"; then
  echo 'Chinese mode leaked English prompts' >&2; exit 1
fi
printf E > "$WORK_DIR/language"
L=''
select_language
[ "$L" = E ]
ENGLISH=$(argo_change_run Try rebuild old.trycloudflare.com '' '')
grep -Fq 'Restarting Argo' <<< "$ENGLISH"
grep -Fq 'New Argo domain' <<< "$ENGLISH"
grep -Fq 'Argo changed and subscriptions updated' <<< "$ENGLISH"
if grep -Eq '正在重启|新的 Argo 域名|订阅已同步' <<< "$ENGLISH"; then
  echo 'English mode leaked Chinese prompts' >&2; exit 1
fi
python3 - <<'PY'
from pathlib import Path
s=Path('sing-box.sh').read_text()
assert """[ "$IS_ARGO_MONITOR" = '1' ] && [ ! -s "${WORK_DIR}/language" ] && L=${L:-E}""" in s
assert 'value_label=$(i18n_message' in s
assert """printf "$(i18n_message '[argo-monitor] 已完成""" in s
assert """printf "$(i18n_message '[subscription] 生成文件为空""" in s
PY
echo 'PASS: selected Chinese and English Argo prompts and localized monitor/subscription output'
