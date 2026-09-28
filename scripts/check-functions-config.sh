#!/usr/bin/env bash
#
# The edge functions' deployed configuration, checked where a mistake is
# silent.
#
# `verify_jwt = true` is what stands between each function and being usable by
# anyone who finds the URL:
#
#   route           the per-account quota is keyed on a verified identity, so
#                   an open relay has no quota at all — it is just the
#                   project's AMap key, exposed to the internet
#   delete-account  it deletes the *caller's* account, so an unverified caller
#                   is not a bypass — but the identity is the whole operation,
#                   and the platform check is one line of config
#
# `release` is the exception, and it is asserted here so that it reads as a
# decision rather than as something somebody forgot. It serves the latest
# Release of a public repository — public data, nothing to protect — and the
# update check has to work for signed-out riders. Flipping it to true would
# break that quietly: the requests would simply start failing for guests.
#
# Nothing else in the repository would notice either mistake; the requests
# would still succeed.
#
# Usage: scripts/check-functions-config.sh
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

echo "==> checking the functions' deployed configuration"

edge_enabled="$(value_of edge_runtime enabled)"
[ "$edge_enabled" = "true" ] || fail "[edge_runtime] enabled 不是 true（是 ${edge_enabled:-空}）"
ok "edge runtime 已启用"

verify_jwt="$(value_of functions.route verify_jwt)"
[ "$verify_jwt" = "true" ] ||
  fail "[functions.route] verify_jwt 不是 true（是 ${verify_jwt:-空}）—— 那是一个对全网开放的算路接口"
ok "route 函数要求会话（verify_jwt = true）"

verify_jwt="$(value_of functions.delete-account verify_jwt)"
[ "$verify_jwt" = "true" ] ||
  fail "[functions.delete-account] verify_jwt 不是 true（是 ${verify_jwt:-空}）"
ok "delete-account 函数要求会话（verify_jwt = true）"

verify_jwt="$(value_of functions.release verify_jwt)"
[ "$verify_jwt" = "false" ] ||
  fail "[functions.release] verify_jwt 是 ${verify_jwt:-空}，应为 false —— 它只转发公开的 Release 信息，要求会话会让退出登录的骑手查不到更新"
ok "release 函数不要求会话（verify_jwt = false，只转发公开数据）"

# The functions read their secrets from their own environment; if one ever
# grows a request parameter that forwards a caller's key or endpoint, this is
# the wrong place to catch it — handler_test.ts is.
echo "==> functions config OK"
