#!/usr/bin/env bash
#
# Starts a complete Supabase stack on this machine and drives the app's real
# request path against it.
#
# ## Where this sits next to the other two harnesses
#
#   verify-migrations.sh  schema + policies, raw Postgres, no API layer
#   verify-auth-flow.sh   real GoTrue, but PostgREST and Storage are not in play
#   local-stack.sh        everything the app actually talks to: Kong routing,
#                         GoTrue, PostgREST (the `push_ride` RPC), Storage (the
#                         GPX bucket), with RLS enforced underneath all of it
#
# It is deliberately not in CI. `supabase start` pulls a dozen images and takes
# minutes; the two-container harnesses cover the same policies in seconds. This
# one is for the machine in front of you — it answers "does the app work
# against a backend", which is a question you ask while developing, not on
# every push.
#
# It leaves the stack running and prints the values to point the app at it.
#
# Usage: scripts/local-stack.sh [--reset]
#
#   --reset   `supabase db reset` first: drop the local database, replay every
#             migration on a fresh stack, and start from nothing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESET=false
[ "${1:-}" = "--reset" ] && RESET=true

WORK="$(mktemp -d)"
SERVE_PID=""
cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" >/dev/null 2>&1 || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

ok() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# The CLI
#
# Homebrew ships two binaries: `supabase`, a launcher, and `supabase-go`, the
# real CLI. On some machines the launcher is SIGKILLed before it can print its
# own version (Gatekeeper, an incomplete update) — so probe it rather than
# trusting `command -v`, and fall back to the binary beside it.
# ---------------------------------------------------------------------------

probe() {
  "$@" >/dev/null 2>&1 &
  local pid=$!
  local i
  for i in $(seq 1 10); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null
      return $?
    fi
    sleep 1
  done
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 1
}

CLI="${SUPABASE_CLI:-}"
if [ -z "$CLI" ]; then
  # `2>/dev/null` at the call site: when the launcher is SIGKILLed the shell
  # prints a "Killed: 9" notice of its own, which is noise, not diagnosis.
  if command -v supabase >/dev/null 2>&1 && probe supabase --version 2>/dev/null; then
    CLI=supabase
  elif command -v supabase-go >/dev/null 2>&1 &&
    probe supabase-go --version 2>/dev/null; then
    CLI=supabase-go
  else
    fail "no working supabase CLI on PATH (set SUPABASE_CLI to override)"
  fi
fi

echo "==> starting the local stack with $CLI"
"$CLI" start >"$WORK/start.log" 2>&1 || {
  tail -20 "$WORK/start.log" >&2
  fail "supabase start failed"
}
ok "stack is up"

if $RESET; then
  echo "==> resetting the database and replaying every migration"
  "$CLI" db reset >"$WORK/reset.log" 2>&1 || {
    tail -20 "$WORK/reset.log" >&2
    fail "db reset failed"
  }
  ok "migrations applied to an empty database"
fi

status_env() {
  "$CLI" status -o env 2>/dev/null |
    grep -E "^$1=" | head -1 | cut -d= -f2- | tr -d '"'
}

API_URL="$(status_env API_URL)"
ANON_KEY="$(status_env ANON_KEY)"
[ -n "$API_URL" ] && [ -n "$ANON_KEY" ] || fail "could not read the stack's URL and key"

# ---------------------------------------------------------------------------
# The app's request path, in the app's order
# ---------------------------------------------------------------------------

api() { curl -fsS -m 20 "$@"; }
code() { curl -s -m 20 -o /dev/null -w '%{http_code}' "$@"; }
auth_header() { printf 'apikey: %s\nAuthorization: Bearer %s\n' "$ANON_KEY" "$1"; }

echo "==> registering accounts"

EMAIL="local-stack-$(date +%s)@example.com"
api -X POST "$API_URL/auth/v1/signup" -H "apikey: $ANON_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"hunter2secret\"}" >"$WORK/email.json"
EMAIL_TOKEN="$(python3 - "$WORK/email.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if not d.get('access_token'):
    print('  ✗ email signup returned no session:', d, file=sys.stderr); sys.exit(1)
print(d['access_token'])
PY
)" || exit 1
ok "email signup returned a session"

api -X POST "$API_URL/auth/v1/signup" -H "apikey: $ANON_KEY" \
  -H 'Content-Type: application/json' -d '{}' >"$WORK/anon.json"
ANON_TOKEN="$(python3 - "$WORK/anon.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
u = d.get('user', {})
if not d.get('access_token') or not u.get('is_anonymous') or u.get('email'):
    print('  ✗ anonymous signup was not anonymous:', d, file=sys.stderr); sys.exit(1)
print(d['access_token'])
PY
)" || exit 1
ok "anonymous signup returned a session with no address"

echo "==> pushing a ride through PostgREST (the app's sync path)"

RIDE_ID="$(uuidgen | tr 'A-Z' 'a-z')"
api -X POST "$API_URL/rest/v1/rpc/push_ride" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"p_ride\":{\"id\":\"$RIDE_ID\",\"name\":\"Local stack ride\",
        \"started_at\":\"2026-09-24T06:00:00Z\",\"distance_meters\":12000,
        \"elapsed_seconds\":2400,\"moving_seconds\":2300,\"avg_speed_mps\":5.0,
        \"max_speed_mps\":9.0,\"elevation_gain_meters\":80,
        \"updated_at\":\"2026-09-24T07:00:00Z\"}}" >"$WORK/push.json"
grep -q '"code"' "$WORK/push.json" && {
  cat "$WORK/push.json" >&2
  fail "push_ride was rejected"
}
ok "push_ride accepted the row"

OWNER="$(api "$API_URL/rest/v1/rides?select=id,user_id&id=eq.$RIDE_ID" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_TOKEN" |
  python3 -c 'import json,sys; rows=json.load(sys.stdin); print(rows[0]["user_id"] if rows else "")')"
[ -n "$OWNER" ] || fail "the rider cannot read back their own ride"
ok "the rider reads back their own ride"

LEAK="$(api "$API_URL/rest/v1/rides?select=id&id=eq.$RIDE_ID" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $EMAIL_TOKEN" |
  python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
[ "$LEAK" = "0" ] || fail "RLS leak: a second account sees the ride"
ok "a second account sees nothing"

echo "==> uploading a GPX to the storage bucket"

# The bucket is `rides` and the object name also starts with `rides/` — the
# layout the storage policies check with `(storage.foldername(name))[1]`. It
# looks redundant in the URL, and it is, but the second segment is part of the
# policy, not a typo.
BUCKET=rides
OBJECT_NAME="$(api -X POST "$API_URL/rest/v1/rpc/new_gpx_upload_path" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"p_ride_id\":\"$RIDE_ID\",\"p_attempt_id\":\"$(uuidgen | tr 'A-Z' 'a-z')\"}" | \
  python3 -c 'import json,sys; value=json.load(sys.stdin); assert isinstance(value,str); print(value)')"
UPLOAD_URL="$API_URL/storage/v1/object/$BUCKET/$OBJECT_NAME"
DOWNLOAD_URL="$API_URL/storage/v1/object/authenticated/$BUCKET/$OBJECT_NAME"

printf '<?xml version="1.0"?><gpx version="1.1"><trk><name>t</name></trk></gpx>' \
  >"$WORK/ride.gpx"

STATUS="$(code -X POST "$UPLOAD_URL" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_TOKEN" \
  -H 'Content-Type: application/gpx+xml' --data-binary @"$WORK/ride.gpx")"
[ "$STATUS" = "200" ] || fail "uploading into the rider's own prefix returned $STATUS"
ok "the rider uploads under their own prefix"

STATUS="$(code "$DOWNLOAD_URL" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $EMAIL_TOKEN")"
[ "$STATUS" = "400" ] || fail "a second account downloaded the GPX (HTTP $STATUS)"
ok "a second account cannot download it"

STATUS="$(code "$DOWNLOAD_URL" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_TOKEN")"
[ "$STATUS" = "200" ] || fail "the rider could not download their own GPX (HTTP $STATUS)"
ok "the rider downloads their own GPX"

# The app's order at ride end: upload the object, then write the path into the
# row. The row is what indexes the bucket, which is why the deletion below can
# find the object at all.
api -X POST "$API_URL/rest/v1/rpc/push_ride" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"p_ride\":{\"id\":\"$RIDE_ID\",\"started_at\":\"2026-09-24T06:00:00Z\",
        \"distance_meters\":12000,\"gpx_path\":\"$OBJECT_NAME\",
        \"updated_at\":\"2026-09-24T07:01:00Z\"}}" >/dev/null
ok "the row now points at the uploaded GPX"

# ---------------------------------------------------------------------------
# The public key
#
# This is what a decompiled binary hands over: the URL and the anon key. Both
# are meant to be public; what must hold is that they cannot reach anybody's
# data. The SQL-level version of this check lives in verify-migrations.sh —
# this one proves it through PostgREST and Storage, which is how an attacker
# would actually ask.
# ---------------------------------------------------------------------------

echo "==> the public key (anon) against the API"

for spec in rides:id routes:id profiles:id user_settings:user_id; do
  table="${spec%%:*}"
  column="${spec##*:}"
  BODY="$(api "$API_URL/rest/v1/$table?select=$column" -H "apikey: $ANON_KEY")"
  [ "$BODY" = "[]" ] || fail "anon can read $table: $BODY"
done
ok "anon reads no tables"

STATUS="$(code "$DOWNLOAD_URL" -H "apikey: $ANON_KEY")"
[ "$STATUS" != "200" ] || fail "anon downloaded the rider's GPX"
ok "anon cannot download files (HTTP ${STATUS})"

STATUS="$(code -X POST "$API_URL/rest/v1/rpc/push_ride" \
  -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
  -d '{"p_ride":{"id":"00000000-0000-7000-8000-000000000000",
        "started_at":"2026-09-24T06:00:00Z"}}')"
case "$STATUS" in
  200 | 201 | 204) fail "anon executed push_ride" ;;
  *) ok "anon cannot execute push_ride (HTTP ${STATUS})" ;;
esac

STATUS="$(code -X POST "$API_URL/rest/v1/rpc/admin_list_users" \
  -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' -d '{}')"
case "$STATUS" in
  200) fail "anon executed admin_list_users" ;;
  *) ok "anon cannot execute admin_list_users (HTTP ${STATUS})" ;;
esac

# ---------------------------------------------------------------------------
# Deleting the cloud copy
#
# The app invokes a fenced server endpoint; direct row-index-only wipes are
# denied so older clients cannot report false success while leaving orphans.
# ---------------------------------------------------------------------------

echo "==> deleting the cloud copy (rides, routes, settings, GPX)"

# A second account's data, to prove the wipe does not reach beyond its owner.
EMAIL_RIDE_ID="$(uuidgen | tr 'A-Z' 'a-z')"
api -X POST "$API_URL/rest/v1/rpc/push_ride" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $EMAIL_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"p_ride\":{\"id\":\"$EMAIL_RIDE_ID\",\"name\":\"Other account ride\",
        \"started_at\":\"2026-09-24T06:00:00Z\",\"distance_meters\":1,
        \"updated_at\":\"2026-09-24T07:00:00Z\"}}" >/dev/null
api -X POST "$API_URL/rest/v1/rpc/push_route" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"p_route":{"id":"'"$(uuidgen | tr 'A-Z' 'a-z')"'","name":"待删路线",
        "distance_meters":1000,"updated_at":"2026-09-24T07:00:00Z"}}' >/dev/null
ok "seeded a route for the rider and a ride for the other account"

# The object path, read back the way the app reads it before deleting rows.
GPX_PATH="$(api "$API_URL/rest/v1/rides?select=gpx_path&gpx_path=not.is.null" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_TOKEN" |
  python3 -c 'import json,sys; rows=json.load(sys.stdin); print(rows[0]["gpx_path"] if rows else "")')"
[ "$GPX_PATH" = "$OBJECT_NAME" ] || fail "could not read the GPX path back before deleting"

STATUS="$(code -X DELETE "$API_URL/storage/v1/object/$BUCKET/$OBJECT_NAME" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $EMAIL_TOKEN")"
[ "$STATUS" != "200" ] || fail "a second account deleted the rider's GPX"
ok "a second account cannot delete the object (HTTP $STATUS)"

# Legacy direct hard-delete must fail instead of pretending it was a wipe.
STATUS="$(code -X DELETE "$API_URL/rest/v1/rides?user_id=eq.$OWNER" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_TOKEN")"
[ "$STATUS" = "403" ] || fail "unfenced legacy wipe was not rejected (HTTP $STATUS)"

if pgrep -f "supabase functions serve" >/dev/null 2>&1; then
  fail "stop the existing functions serve process before validating this checkout"
fi
"$CLI" functions serve >"$WORK/functions.log" 2>&1 &
SERVE_PID=$!
for _ in $(seq 1 60); do
  STATUS="$(code -X POST "$API_URL/functions/v1/wipe-cloud-data" \
    -H 'Content-Type: application/json' -d '{}')"
  [ "$STATUS" = "401" ] && break
  sleep 1
done
[ "$STATUS" = "401" ] || { tail -30 "$WORK/functions.log" >&2; fail "wipe endpoint did not start"; }
STATUS="$(curl -sS -m 60 -o "$WORK/wipe.json" -w '%{http_code}' \
  -X POST "$API_URL/functions/v1/wipe-cloud-data" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_TOKEN" \
  -H 'Content-Type: application/json' -d '{}')"
[ "$STATUS" = "200" ] || { cat "$WORK/wipe.json" >&2; fail "cloud wipe failed (HTTP $STATUS)"; }
python3 - "$WORK/wipe.json" <<'PYCHECK'
import json, sys
result = json.load(open(sys.argv[1]))
assert result.get('wiped') is True, result
assert result.get('files') == 1, result
PYCHECK
STATUS="$(code "$DOWNLOAD_URL" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_TOKEN")"
[ "$STATUS" != "200" ] || fail "the GPX is still downloadable after wipe"
ok "the server removed cloud rows and GPX under the account fence"

REMAINING="$(api "$API_URL/rest/v1/rides?select=id" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_TOKEN" |
  python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
[ "$REMAINING" = "0" ] || fail "the rider still has $REMAINING ride(s) in the cloud"
ok "the rider reads back nothing"

OTHER="$(api "$API_URL/rest/v1/rides?select=id&id=eq.$EMAIL_RIDE_ID" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $EMAIL_TOKEN" |
  python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
[ "$OTHER" = "1" ] || fail "the wipe reached another account's data"
ok "the other account's ride is untouched"

# ---------------------------------------------------------------------------
# How to point the app here
# ---------------------------------------------------------------------------

cat <<EOF

==> local stack ready

  Studio    http://127.0.0.1:54323
  Mail      http://127.0.0.1:54324     (every email the stack "sends")

  Run the app against it:

    cd app
    flutter run \\
      --dart-define=SUPABASE_URL=$API_URL \\
      --dart-define=SUPABASE_ANON_KEY=$ANON_KEY

  On an Android emulator, replace 127.0.0.1 with 10.0.2.2 — the emulator's
  loopback is its own.

  Stop it with: $CLI stop
EOF
