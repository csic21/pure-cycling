#!/usr/bin/env bash
#
# Verifies self-service account deletion end to end: a real account deletes
# itself through the real function, and the assertions are the two ways that
# can go wrong — leaving something behind, or reaching too far.
#
# Requires the local stack (scripts/local-stack.sh). It starts
# `supabase functions serve` itself and stops it on exit.
#
#   scripts/verify-account-deletion.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The CLI resolves `supabase/` from the working directory.
cd "$REPO_ROOT"
WORK="$(mktemp -d)"
SERVE_PID=""

cleanup() {
  [ -n "$SERVE_PID" ] && kill "$SERVE_PID" >/dev/null 2>&1 || true
  [ -n "$SERVE_PID" ] && wait "$SERVE_PID" 2>/dev/null || true
  if [ -n "${DB_CONTAINER:-}" ] && [ -n "${DOOMED_ID:-}" ]; then
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q \
      -c "delete from auth.users where id in ('$DOOMED_ID', '${BYSTANDER_ID:-}')" \
      >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

fail() { echo "  ✗ $1" >&2; exit 1; }
ok() { echo "  ✓ $1"; }

command -v supabase >/dev/null 2>&1 || fail "没有 supabase CLI"

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

if pgrep -f "supabase functions serve" >/dev/null 2>&1; then
  fail "已经有 supabase functions serve 在跑，先停掉它，避免测到另一份环境"
fi

echo "==> serving the functions"
supabase functions serve >"$WORK/serve.log" 2>&1 &
SERVE_PID=$!

for _ in $(seq 1 60); do
  STATUS="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' \
    -X POST "$API_URL/functions/v1/delete-account" \
    -H 'Content-Type: application/json' -d '{}' 2>/dev/null || echo 000)"
  [ "$STATUS" = "401" ] && break
  sleep 2
done
[ "${STATUS:-000}" = "401" ] || {
  tail -20 "$WORK/serve.log" >&2
  fail "delete-account 没有起来（最后一次 HTTP ${STATUS:-000}）"
}
ok "delete-account 就绪，未登录被拒（HTTP 401）"

# ---------------------------------------------------------------------------
# One account to delete, one to leave alone
# ---------------------------------------------------------------------------

stamp="$(date +%s)"
DOOMED_EMAIL="doomed-${stamp}@example.com"
BYSTANDER_EMAIL="bystander-${stamp}@example.com"
PASSWORD="delete-${stamp}"

signup() {
  curl -sS -X POST "$API_URL/auth/v1/signup" \
    -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$2\"}" | jq -r '.user.id // empty'
}
signin() {
  curl -sS -X POST "$API_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$2\"}" | jq -r '.access_token // empty'
}

echo "==> seeding two accounts"
DOOMED_ID="$(signup "$DOOMED_EMAIL" "$PASSWORD")"
BYSTANDER_ID="$(signup "$BYSTANDER_EMAIL" "$PASSWORD")"
[ -n "$DOOMED_ID" ] && [ -n "$BYSTANDER_ID" ] || fail "注册测试账号失败"

DOOMED_TOKEN="$(signin "$DOOMED_EMAIL" "$PASSWORD")"
BYSTANDER_TOKEN="$(signin "$BYSTANDER_EMAIL" "$PASSWORD")"
DOOMED_RIDE="$(uuidgen | tr 'A-Z' 'a-z')"
BYSTANDER_RIDE="$(uuidgen | tr 'A-Z' 'a-z')"
upload_path() {
  curl -fsS -X POST "$API_URL/rest/v1/rpc/new_gpx_upload_path" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $DOOMED_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg ride "$DOOMED_RIDE" --arg attempt "$(uuidgen | tr 'A-Z' 'a-z')" \
      '{p_ride_id:$ride,p_attempt_id:$attempt}')" | jq -er '.'
}
DOOMED_OBJECT="$(upload_path)"
ORPHAN_OBJECT="$(upload_path)"

push_ride() { # push_ride <token> <ride-id> [gpx-path]
  local body
  body="$(jq -nc --arg id "$2" --arg gpx "${3:-}" '{p_ride:{
    id:$id,
    started_at:"2026-09-25T06:00:00Z",
    distance_meters:5000,
    updated_at:"2026-09-25T07:00:00Z",
    gpx_path:(if $gpx == "" then null else $gpx end)}}')"
  curl -fsS -o /dev/null -X POST "$API_URL/rest/v1/rpc/push_ride" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H 'Content-Type: application/json' -d "$body"
}


printf '<?xml version="1.0"?><gpx version="1.1"><trk><name>t</name></trk></gpx>' \
  >"$WORK/ride.gpx"
# Bucket `rides`, object name also starting with `rides/` — the layout the
# storage policies check. The redundancy is in the format.
STATUS="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' \
  -X POST "$API_URL/storage/v1/object/rides/$DOOMED_OBJECT" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $DOOMED_TOKEN" \
  -H 'Content-Type: application/gpx+xml' --data-binary @"$WORK/ride.gpx")"
[ "$STATUS" = "200" ] || fail "上传测试 GPX 失败（HTTP ${STATUS}）"
# An upload whose push_ride never committed is still location data to remove.
STATUS="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' \
  -X POST "$API_URL/storage/v1/object/rides/$ORPHAN_OBJECT" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $DOOMED_TOKEN" \
  -H 'Content-Type: application/gpx+xml' --data-binary @"$WORK/ride.gpx")"
[ "$STATUS" = "200" ] || fail "上传孤立 GPX 失败（HTTP ${STATUS}）"
push_ride "$DOOMED_TOKEN" "$DOOMED_RIDE" "$DOOMED_OBJECT"
push_ride "$BYSTANDER_TOKEN" "$BYSTANDER_RIDE"
ok "两个账号各有数据，待删除账号有一个引用 GPX 和一个孤立 GPX"

# ---------------------------------------------------------------------------
# The deletion
# ---------------------------------------------------------------------------

echo "==> deleting one account through the function"
STATUS="$(curl -sS -m 30 -o "$WORK/result.json" -w '%{http_code}' \
  -X POST "$API_URL/functions/v1/delete-account" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $DOOMED_TOKEN" \
  -H 'Content-Type: application/json' -d '{}')"
[ "$STATUS" = "200" ] || {
  cat "$WORK/result.json" >&2
  fail "删除返回 HTTP ${STATUS}"
}
jq -e '.deleted == true' "$WORK/result.json" >/dev/null ||
  fail "响应没有确认删除：$(cat "$WORK/result.json")"
FILES="$(jq -r '.files' "$WORK/result.json")"
[ "$FILES" = "2" ] || fail "删除的文件数应为 2，实际 $FILES"
ok "账号删除成功，并带走了 $FILES 个 GPX"

echo "==> asserting what is gone, and what is not"

count() { psql_db -tAc "$1"; }

[ "$(count "select count(*) from auth.users where id = '$DOOMED_ID'")" = "0" ] ||
  fail "账号还在"
ok "auth.users 行已删除"

[ "$(count "select count(*) from public.rides where user_id = '$DOOMED_ID'")" = "0" ] ||
  fail "骑行行还在（级联没生效？）"
ok "骑行行随级联删除"

[ "$(count "select count(*) from storage.objects where name like 'rides/$DOOMED_ID/%'")" = "0" ] ||
  fail "GPX 还留在存储里——一条没人能看、也没人能删的位置轨迹"
ok "GPX 已从存储删除"

[ "$(count "select count(*) from public.rides where id = '$BYSTANDER_RIDE'")" = "1" ] ||
  fail "删到了别人的数据"
ok "另一个账号的数据原样保留"

STATUS="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
  -X POST "$API_URL/functions/v1/delete-account" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $DOOMED_TOKEN" \
  -H 'Content-Type: application/json' -d '{}')"
[ "$STATUS" = "401" ] || fail "已删除账号的旧令牌仍然可用（HTTP ${STATUS}）"
ok "旧会话立即失效（HTTP 401）"

echo "==> account deletion OK"
