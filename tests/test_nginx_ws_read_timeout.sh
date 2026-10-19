#!/usr/bin/env bash
# Regression: VMess/VLESS WebSocket reverse proxies must survive idle SSH sessions.
# The same export_nginx_conf_file() is used for initial installation and re-generation.
set -euo pipefail
cd "$(dirname "$0")/.."

# Extract the real generator without starting the installer or changing the host.
source <(sed -n '/^export_nginx_conf_file() {/,/^}/p' sing-box.sh)
declare -F export_nginx_conf_file >/dev/null

# Pretend nginx is installed: the test only generates a configuration.
nginx() { :; }
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
PORT_NGINX=18080
UUID_CONFIRM=regression-id
IS_SUB=no_sub

assert_config() {
  python3 - "$WORK_DIR/nginx.conf" "$@" <<'PY'
import pathlib
import re
import sys

config = pathlib.Path(sys.argv[1]).read_text()
expected = set(sys.argv[2:])
locations = {
    "vmess": "regression-id-vmess",
    "vless": "regression-id-vless",
}
for kind, location in locations.items():
    match = re.search(r"(?m)^\s*location /" + re.escape(location) + r"\s*\{", config)
    if kind in expected:
        assert match, f"missing {kind} WebSocket location"
        # Stop at the end of the location; there is also a nested 'if' block.
        depth = 1
        start = match.end()
        end = start
        while depth and end < len(config):
            if config[end] == "{":
                depth += 1
            elif config[end] == "}":
                depth -= 1
            end += 1
        assert depth == 0, f"unclosed {kind} location"
        block = config[start:end-1]
        assert len(re.findall(r"(?m)^\s*proxy_read_timeout\s+3600s;", block)) == 1, (
            f"{kind} location must contain exactly one 3600s read timeout"
        )
        assert "proxy_pass" in block, f"missing {kind} upstream"
    else:
        assert not match, f"unexpected {kind} WebSocket location"

assert len(re.findall(r"(?m)^\s*proxy_read_timeout\s+3600s;", config)) == len(expected), (
    "read timeout should be added only to generated WebSocket locations"
)
PY
}

IS_ARGO=is_argo
PORT_VMESS_WS=18081
PORT_VLESS_WS=18082
export_nginx_conf_file
assert_config vmess vless

# Re-generated configurations (e.g. after protocol/port changes or updates) retain both.
printf '\n# discarded stale configuration\n' >> "$WORK_DIR/nginx.conf"
export_nginx_conf_file
assert_config vmess vless
if grep -q 'discarded stale configuration' "$WORK_DIR/nginx.conf"; then
  echo 'FAIL: nginx configuration was not regenerated cleanly' >&2
  exit 1
fi

PORT_VMESS_WS=18081
PORT_VLESS_WS=
export_nginx_conf_file
assert_config vmess

PORT_VMESS_WS=
PORT_VLESS_WS=18082
export_nginx_conf_file
assert_config vless

# Do not affect non-Argo mode or unrelated listeners.
IS_ARGO=no_argo
PORT_VMESS_WS=18081
PORT_VLESS_WS=18082
export_nginx_conf_file
assert_config

echo 'PASS: Nginx WebSocket read timeout for VMess/VLESS, regeneration and non-Argo mode'
