#!/usr/bin/env bash
#
# Verifies the routing relay (supabase/functions/route) end to end, without a
# vendor key: a stub stands in for AMap, so the assertions cover the parts we
# wrote — auth, quota, input validation, and what the relay actually asks the
# vendor for.
#
# Requires the local stack (scripts/local-stack.sh). It starts:
#
#   scripts/amap_stub.py                        a canned AMap
#   supabase functions serve --env-file <tmp>   the relay, pointed at the stub
#
# and stops both when it exits. The stub's request log is the interesting
# artefact: it shows the key being added server-side, which is the whole point
# of the relay existing.
#
# Usage: scripts/verify-routing-relay.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The CLI resolves `supabase/` from the working directory.
cd "$REPO_ROOT"
STUB_PORT="${STUB_PORT:-8799}"
LIMIT="${LIMIT:-3}"
WORK="$(mktemp -d)"
STUB_PID=""
SERVE_PID=""

cleanup() {
  [ -n "$SERVE_PID" ] && kill "$SERVE_PID" >/dev/null 2>&1 || true
  [ -n "$STUB_PID" ] && kill "$STUB_PID" >/dev/null 2>&1 || true
  # Reap them so the shell does not print "Terminated" notices on exit.
  [ -n "$SERVE_PID" ] && wait "$SERVE_PID" 2>/dev/null || true
  [ -n "$STUB_PID" ] && wait "$STUB_PID" 2>/dev/null || true
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

fail() { echo "  ✗ $1" >&2; exit 1; }
ok() { echo "  ✓ $1"; }

command -v supabase >/dev/null 2>&1 || fail "没有 supabase CLI"

# ---------------------------------------------------------------------------
# The stack this runs against
# ---------------------------------------------------------------------------

API_URL="$(supabase status -o env 2>/dev/null |
  sed -n 's/^API_URL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')"
ANON_KEY="$(supabase status -o env 2>/dev/null |
  sed -n 's/^ANON_KEY="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')"
[ -n "$API_URL" ] && [ -n "$ANON_KEY" ] ||
  fail "本地栈没有运行。先跑 scripts/local-stack.sh"

DB_CONTAINER="${DB_CONTAINER:-$(docker ps --filter 'name=supabase_db_' \
  --format '{{.Names}}' | head -1)}"
[ -n "$DB_CONTAINER" ] || fail "找不到 Supabase 数据库容器"

psql_db() {
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q \
    -v ON_ERROR_STOP=1 "$@"
}

# The relay consumes a quota that the migrations create. A missing function
# makes every request look like an exhausted quota, which is a confusing way
# to spend ten minutes.
RATE_LIMIT_EXISTS="$(psql_db -tAc \
  "select count(*) from pg_proc where proname = 'consume_rate_limit'")"
[ "$RATE_LIMIT_EXISTS" = "1" ] ||
  fail "数据库里没有 consume_rate_limit —— 先跑 supabase migration up"

# Already-running runtimes would answer for the wrong environment. The check
# is the process, not an HTTP probe: Kong answers 401 for the route whether or
# not anything is behind it, because the JWT check happens at the gateway.
if pgrep -f "supabase functions serve" >/dev/null 2>&1; then
  fail "已经有 supabase functions serve 在跑，先停掉它，避免测到另一份环境"
fi

# ---------------------------------------------------------------------------
# A canned AMap, and the relay pointed at it
# ---------------------------------------------------------------------------

echo "==> starting the AMap stub on port $STUB_PORT"
python3 "$REPO_ROOT/scripts/amap_stub.py" "$STUB_PORT" "$WORK/requests.log" &
STUB_PID=$!
sleep 1

cat >"$WORK/functions.env" <<EOF
AMAP_KEY=stub-key-not-a-real-credential
AMAP_BASE_URL=http://host.docker.internal:$STUB_PORT
ROUTE_DAILY_LIMIT=$LIMIT
EOF

echo "==> serving the relay against the stub"
# Started as a direct child, not in a subshell: killing a subshell leaves the
# CLI (and its edge runtime) alive, and the next run then refuses to start.
supabase functions serve --env-file "$WORK/functions.env" \
  >"$WORK/serve.log" 2>&1 &
SERVE_PID=$!

# Wait for the function to be routed. An unauthenticated POST must come back
# 401: that means Kong has the route and verify_jwt is doing its job.
for _ in $(seq 1 60); do
  STATUS="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' \
    -X POST "$API_URL/functions/v1/route" \
    -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo 000)"
  [ "$STATUS" = "401" ] && break
  sleep 2
done
[ "${STATUS:-000}" = "401" ] || {
  tail -20 "$WORK/serve.log" >&2
  fail "relay 没有起来（最后一次 HTTP ${STATUS:-000}）"
}
ok "relay 就绪，未登录被拒（HTTP 401）"

# ---------------------------------------------------------------------------
# A real session, because the quota is per account
# ---------------------------------------------------------------------------

stamp="$(date +%s)"
EMAIL="relay-${stamp}@example.com"
PASSWORD="relay-${stamp}"
USER_ID="$(curl -sS -X POST "$API_URL/auth/v1/signup" \
  -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" |
  jq -r '.user.id // empty')"
[ -n "$USER_ID" ] || fail "测试账号注册失败"
eval "cleanup_user() { psql_db -c \"delete from auth.users where id = '$USER_ID'\" >/dev/null 2>&1 || true; }"
trap 'cleanup_user; cleanup' EXIT

TOKEN="$(curl -sS -X POST "$API_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" | jq -r '.access_token')"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "测试账号登录失败"

relay() {
  curl -sS -m 20 -X POST "$API_URL/functions/v1/route" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -d "$1"
}

echo "==> planning a route through the relay"

BODY="$(relay '{"origin":"116.4074,39.9042","destination":"116.4174,39.9142"}')"
echo "$BODY" | jq -e '.status == "1"' >/dev/null ||
  fail "relay 没有返回可用的路线：$BODY"
echo "$BODY" | jq -e '.route.paths[0].steps | length >= 2' >/dev/null ||
  fail "响应里没有转向步骤"
ok "relay 返回了路线与转向步骤"

# What the relay asked the vendor for: the key it holds, and the fields the
# app's parser needs. If the key ever appears here from the client's side,
# something has gone wrong with the whole design.
REQUESTS="$(cat "$WORK/requests.log")"
case "$REQUESTS" in
  *"key=stub-key-not-a-real-credential"*) ok "Key 由服务端附加" ;;
  *) fail "上游请求里没有 Key：$REQUESTS" ;;
esac
case "$REQUESTS" in
  *"show_fields=cost%2Cpolyline%2Cnavi"*) ok "带了 show_fields（否则没有几何数据）" ;;
  *) fail "上游请求缺少 show_fields：$REQUESTS" ;;
esac

echo "==> the quota"

for _ in $(seq 2 "$LIMIT"); do
  relay '{"origin":"116.4074,39.9042","destination":"116.4174,39.9142"}' \
    >/dev/null
done

STATUS="$(curl -sS -m 20 -o "$WORK/limited.json" -w '%{http_code}' \
  -X POST "$API_URL/functions/v1/route" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"origin":"116.4074,39.9042","destination":"116.4174,39.9142"}')"
[ "$STATUS" = "429" ] || fail "超出配额后返回了 HTTP $STATUS，应该是 429"
jq -e '.infocode == "relay_429"' "$WORK/limited.json" >/dev/null ||
  fail "配额用尽的响应不是 relay 信封格式"
ok "配额用尽后拒绝，且理由是「次数已用完」而不是别的"

echo "==> input validation"

STATUS="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' \
  -X POST "$API_URL/functions/v1/route" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"origin":"不是坐标","destination":"116.4174,39.9142"}')"
[ "$STATUS" = "400" ] || fail "坏输入返回了 HTTP $STATUS，应该是 400"
ok "坏输入被拒（HTTP 400）"

echo "==> routing relay OK"
