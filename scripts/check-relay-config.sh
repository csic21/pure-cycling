#!/usr/bin/env bash
#
# The relay's deployed configuration, checked where a mistake is silent.
#
# `verify_jwt = true` is the only thing standing between the routing relay and
# a free routing API for the internet: the per-account quota is keyed on a
# verified identity, so an open relay has no quota at all — it is just the
# project's AMap key, exposed to whoever finds the URL. Nothing else in the
# repository would notice the difference; a request would still succeed.
#
# Usage: scripts/check-relay-config.sh
set -euo pipefail

CONFIG="${CONFIG:-supabase/config.toml}"

fail() { echo "  ✗ $1" >&2; exit 1; }
ok() { echo "  ✓ $1"; }

[ -f "$CONFIG" ] || fail "找不到 $CONFIG"

# Prints the body of a TOML section, without the header.
section() {
  awk -v want="[$1]" '
    $0 == want { inside = 1; next }
    /^\[/      { inside = 0 }
    inside     { print }
  ' "$CONFIG"
}

value_of() { # value_of <section> <key>
  section "$1" | sed -n "s/^$2[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" |
    head -1 | tr -d ' '
}

echo "==> checking the relay's deployed configuration"

edge_enabled="$(value_of edge_runtime enabled)"
[ "$edge_enabled" = "true" ] || fail "[edge_runtime] enabled 不是 true（是 ${edge_enabled:-空}）"
ok "edge runtime 已启用"

verify_jwt="$(value_of functions.route verify_jwt)"
[ "$verify_jwt" = "true" ] ||
  fail "[functions.route] verify_jwt 不是 true（是 ${verify_jwt:-空}）—— 那是一个对全网开放的算路接口"
ok "route 函数要求会话（verify_jwt = true）"

# The function reads the key from its own environment; if it ever grows a
# request parameter that forwards a caller's key or endpoint, this is the wrong
# place to catch it — handler_test.ts is.
echo "==> relay config OK"
