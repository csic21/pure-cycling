#!/usr/bin/env bash
#
# Verifies the admin boundary through the real API layer: the local stack's
# GoTrue issues the tokens, PostgREST serves the RPC, and the assertions are
# the product promise — an admin can list accounts, and still cannot read a
# ride.
#
# ## Why this needs the full stack
#
# `verify-migrations.sh` covers the policies against a bare Postgres, and
# `verify-auth-flow.sh` covers two accounts against GoTrue. Neither exercises
# the path the admin console actually uses: a real token on a real PostgREST
# request to `admin_list_users`, with RLS evaluated as the calling user.
#
# Requires the local stack (see scripts/local-stack.sh):
#
#   scripts/local-stack.sh --reset      # or: supabase start
#   scripts/verify-admin-flow.sh
#
# Usage: scripts/verify-admin-flow.sh
set -euo pipefail

API="${API_URL:-}"
ANON_KEY="${ANON_KEY:-}"
DB_CONTAINER="${DB_CONTAINER:-}"

fail() { echo "  ✗ $1" >&2; exit 1; }
ok() { echo "  ✓ $1"; }

# Resolve the running stack unless the caller provided the values. `supabase
# status -o env` prints shell assignments, so eval is the intended reader.
if [ -z "$API" ] || [ -z "$ANON_KEY" ]; then
  eval "$(supabase status -o env 2>/dev/null | grep -E '^(API_URL|ANON_KEY)=' || true)"
  API="${API:-${API_URL:-}}"
  ANON_KEY="${ANON_KEY:-${ANON_KEY:-}}"
fi
[ -n "$API" ] || fail "本地栈没有运行。先跑 scripts/local-stack.sh，或 supabase start"
[ -n "$ANON_KEY" ] || fail "拿不到 anon key（本地栈起来了吗？）"

if [ -z "$DB_CONTAINER" ]; then
  DB_CONTAINER="$(docker ps --filter 'name=supabase_db_' --format '{{.Names}}' | head -1)"
fi
[ -n "$DB_CONTAINER" ] || fail "找不到 Supabase 数据库容器（可以 DB_CONTAINER=... 指定）"

psql_db() {
  docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q -v ON_ERROR_STOP=1 "$@"
}

stamp="$(date +%s)"
ADMIN_EMAIL="admin-${stamp}@example.com"
RIDER_EMAIL="rider-${stamp}@example.com"
PASSWORD="verify-admin-${stamp}"

signup() {
  curl -sS -X POST "${API}/auth/v1/signup" \
    -H "apikey: ${ANON_KEY}" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg e "$1" --arg p "$2" '{email:$e,password:$p}')"
}

echo "==> registering two throwaway accounts"
admin_id="$(signup "$ADMIN_EMAIL" "$PASSWORD" | jq -r '.user.id // .id // empty')"
rider_id="$(signup "$RIDER_EMAIL" "$PASSWORD" | jq -r '.user.id // .id // empty')"
[ -n "$admin_id" ] || fail "管理员账号注册失败"
[ -n "$rider_id" ] || fail "骑手账号注册失败"

cleanup() {
  psql_db -c "delete from auth.users where id in ('$admin_id','$rider_id')" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> promoting one account (membership is not a Data API operation)"
psql_db -c "insert into public.admins (user_id, note)
            values ('$admin_id', 'verify-admin-flow')" >/dev/null

signin() {
  curl -sS -X POST "${API}/auth/v1/token?grant_type=password" \
    -H "apikey: ${ANON_KEY}" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg e "$1" --arg p "$2" '{email:$e,password:$p}')" \
    | jq -r '.access_token // empty'
}

echo "==> signing in as both"
admin_token="$(signin "$ADMIN_EMAIL" "$PASSWORD")"
rider_token="$(signin "$RIDER_EMAIL" "$PASSWORD")"
[ -n "$admin_token" ] || fail "管理员登录失败"
[ -n "$rider_token" ] || fail "骑手登录失败"

# rpc <token> <function> [body] -> body on stdout, HTTP status on the last line
rpc() {
  curl -sS -X POST "${API}/rest/v1/rpc/$2" \
    -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -d "${3:-'{}'}" \
    -w '\n%{http_code}'
}

echo "==> syncing one ride as the rider (the thing an admin must not see)"
curl -sS -X POST "${API}/rest/v1/rpc/push_ride" \
  -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${rider_token}" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc '{p_ride:{
        id:"77777777-7777-7777-8777-777777777777",
        name:"Admin boundary ride",
        started_at:"2026-09-24T06:00:00Z",
        distance_meters:12345,
        updated_at:"2026-09-24T07:00:00Z"}}')" >/dev/null

echo "==> asserting the boundary"

admin_out="$(rpc "$admin_token" admin_list_users '{"p_limit":50,"p_offset":0}')"
admin_status="$(printf '%s' "$admin_out" | tail -1)"
admin_body="$(printf '%s' "$admin_out" | sed '$d')"
[ "$admin_status" = "200" ] || fail "管理员调用 admin_list_users 失败（HTTP ${admin_status}）"
printf '%s' "$admin_body" |
  jq -e --arg email "$RIDER_EMAIL" 'any(.[]; .email == $email)' >/dev/null ||
  fail "账号列表里没有骑手账号"
ok "管理员能看到账号列表（含邮箱）"

rider_out="$(rpc "$rider_token" admin_list_users '{"p_limit":50,"p_offset":0}')"
rider_status="$(printf '%s' "$rider_out" | tail -1)"
[ "$rider_status" != "200" ] || fail "非管理员竟然能调用 admin_list_users"
ok "非管理员被 admin_list_users 拒绝（HTTP ${rider_status}）"

rider_rides="$(curl -sS "${API}/rest/v1/rides?select=id" \
  -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${rider_token}")"
printf '%s' "$rider_rides" | jq -e 'length == 1' >/dev/null ||
  fail "骑手看不到自己的骑行"
ok "骑手能读到自己的骑行"

admin_rides="$(curl -sS "${API}/rest/v1/rides?select=id" \
  -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${admin_token}")"
printf '%s' "$admin_rides" | jq -e 'length == 0' >/dev/null ||
  fail "隐私泄漏：管理员读到了骑行"
ok "管理员读不到任何骑行（产品承诺，不是配置遗漏）"

admin_table="$(curl -sS -o /dev/null -w '%{http_code}' \
  "${API}/rest/v1/admins?select=user_id" \
  -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${admin_token}")"
[ "$admin_table" != "200" ] || fail "public.admins 竟然可以通过 Data API 读取"
ok "public.admins 不通过 Data API 暴露（HTTP ${admin_table}）"

echo "==> admin flow OK"
