#!/usr/bin/env bash
#
# Runs the real Supabase auth server against the real migrations, then
# registers two accounts and checks that row level security keeps them apart.
#
# ## What this proves that the migration script cannot
#
# `verify-migrations.sh` applies the schema and pokes at it with a hand-set
# `request.jwt.claim.sub`. That covers the policies, but it starts from a claim
# this script made up. It cannot tell you whether:
#
#   * GoTrue's insert into `auth.users` satisfies every foreign key we declared
#   * the `on_auth_user_created` trigger fires for a user GoTrue actually created
#   * an anonymous signup produces a row shaped the way the policies assume
#   * the `sub` in a real issued token is the id the policies compare against
#
# Those are the seams between three separately-versioned things — this repo's
# migrations, Supabase's `auth` schema, and Supabase's auth server — and they
# are exactly where a mismatch hides until runtime.
#
# Two containers, no cloud project, no keys, no cost:
#
#   supabase/postgres   the real image, with the real auth/storage schemas
#   supabase/gotrue     the real auth server
#
# Usage: scripts/verify-auth-flow.sh
set -euo pipefail

NET="${NET:-cycling-verify-net}"
DB="${DB:-cycling-verify-db}"
AUTH="${AUTH:-cycling-verify-auth}"
PORT_DB="${PORT_DB:-55446}"
PORT_AUTH="${PORT_AUTH:-55447}"
PG_IMAGE="${PG_IMAGE:-supabase/postgres:15.8.1.060}"
AUTH_IMAGE="${AUTH_IMAGE:-supabase/gotrue:v2.177.0}"
API="http://127.0.0.1:${PORT_AUTH}"
JWT_SECRET="verify-only-jwt-secret-with-at-least-32-characters"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Created after the opening cleanup below — that call removes it.
WORK=""

cleanup() {
  docker rm -f "$DB" "$AUTH" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  [ -n "$WORK" ] && rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

fail() { echo "  ✗ $1" >&2; exit 1; }
ok() { echo "  ✓ $1"; }

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

echo "==> starting the real Supabase Postgres"
cleanup
WORK="$(mktemp -d)"
docker network create "$NET" >/dev/null
docker run -d --name "$DB" --network "$NET" \
  -e POSTGRES_PASSWORD=postgres -p "${PORT_DB}:5432" "$PG_IMAGE" >/dev/null

for _ in $(seq 1 120); do
  ready=$(docker logs "$DB" 2>&1 |
    grep -c 'database system is ready to accept connections' || true)
  [ "${ready:-0}" -ge 2 ] && break
  sleep 1
done

echo "==> applying migrations"
for migration in "$REPO_ROOT"/supabase/migrations/*.sql; do
  echo "    $(basename "$migration")"
  # `-q` quiets psql, not the server's NOTICEs — "policy does not exist,
  # skipping" is expected on a first run and drowns the output.
  if ! docker exec -i "$DB" psql -v ON_ERROR_STOP=1 -U postgres -q \
    < "$migration" > "$WORK/migration.log" 2>&1; then
    cat "$WORK/migration.log" >&2
    fail "migration failed: $(basename "$migration")"
  fi
  # Only suppress the filter's empty-output status, never psql's failure.
  grep -vE '^NOTICE' "$WORK/migration.log" || true
done

# ---------------------------------------------------------------------------
# Auth server
# ---------------------------------------------------------------------------

echo "==> starting GoTrue"
docker run -d --name "$AUTH" --network "$NET" -p "${PORT_AUTH}:9999" \
  -e GOTRUE_DB_DRIVER=postgres \
  -e "GOTRUE_DB_DATABASE_URL=postgres://supabase_admin:postgres@${DB}:5432/postgres?search_path=auth&sslmode=disable" \
  -e "API_EXTERNAL_URL=${API}" \
  -e GOTRUE_SITE_URL=http://localhost:3000 \
  -e "GOTRUE_JWT_SECRET=${JWT_SECRET}" \
  -e GOTRUE_JWT_EXP=3600 \
  -e GOTRUE_JWT_AUD=authenticated \
  -e GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated \
  -e GOTRUE_API_HOST=0.0.0.0 \
  -e GOTRUE_API_PORT=9999 \
  -e GOTRUE_DISABLE_SIGNUP=false \
  -e GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED=true \
  -e GOTRUE_MAILER_AUTOCONFIRM=true \
  "$AUTH_IMAGE" >/dev/null

for _ in $(seq 1 45); do
  curl -sf -m 2 "$API/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf -m 5 "$API/health" >/dev/null 2>&1 || {
  docker logs "$AUTH" 2>&1 | tail -10
  fail "GoTrue did not come up"
}
ok "auth server healthy"

# ---------------------------------------------------------------------------
# The flow
# ---------------------------------------------------------------------------

echo "==> registering an account"

curl -s -m 10 -X POST "$API/signup" -H 'Content-Type: application/json' \
  -d '{"email":"rider@example.com","password":"hunter2secret"}' > "$WORK/a.json"

python3 - "$WORK/a.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
if not d.get('access_token'):
    print('  ✗ signup returned no session:', d); sys.exit(1)
u = d['user']
if u.get('is_anonymous'):
    print('  ✗ an email signup came back anonymous'); sys.exit(1)
print('  ✓ email signup returned a session')
PY

curl -s -m 10 -X POST "$API/signup" -H 'Content-Type: application/json' \
  -d '{"email":"rider@example.com","password":"hunter2secret"}' > "$WORK/dup.json"

python3 - "$WORK/dup.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
msg = str(d.get('msg') or d.get('error_description') or d.get('error') or '')
if 'already' not in msg.lower():
    print('  ✗ a duplicate signup was not rejected:', d); sys.exit(1)
# The app maps this exact string; see AuthRepository.describeAuthError.
print('  ✓ duplicate signup rejected:', msg)
PY

echo "==> anonymous signup"
curl -s -m 10 -X POST "$API/signup" -H 'Content-Type: application/json' \
  -d '{}' > "$WORK/b.json"

python3 - "$WORK/b.json" <<'PY' || exit 1
import base64, json, sys
d = json.load(open(sys.argv[1]))
if not d.get('access_token'):
    print('  ✗ anonymous signup returned no session:', d); sys.exit(1)
u = d['user']
if not u.get('is_anonymous'):
    print('  ✗ anonymous signup produced a non-anonymous user'); sys.exit(1)
if u.get('email'):
    print('  ✗ anonymous signup produced an email'); sys.exit(1)
p = d['access_token'].split('.')[1]; p += '=' * (-len(p) % 4)
claims = json.loads(base64.urlsafe_b64decode(p))
if claims.get('role') != 'authenticated' or claims.get('sub') != u['id']:
    print('  ✗ anonymous token has an incorrect role or subject'); sys.exit(1)
print('  ✓ anonymous signup returned a session with no address')
PY

echo "==> password sign-in"
curl -s -m 10 -X POST "$API/token?grant_type=password" \
  -H 'Content-Type: application/json' \
  -d '{"email":"rider@example.com","password":"hunter2secret"}' > "$WORK/login.json"

python3 - "$WORK/login.json" "$WORK/sub.txt" <<'PY' || exit 1
import base64, json, sys
d = json.load(open(sys.argv[1]))
t = d.get('access_token')
if not t:
    print('  ✗ sign-in returned no token:', d); sys.exit(1)
p = t.split('.')[1]; p += '=' * (-len(p) % 4)
claims = json.loads(base64.urlsafe_b64decode(p))
if not claims.get('sub'):
    print('  ✗ the token carries no subject'); sys.exit(1)
if claims.get('role') != 'authenticated':
    print('  ✗ the token does not carry the authenticated role'); sys.exit(1)
if claims.get('sub') != d['user']['id']:
    print('  ✗ the token subject does not match the signed-in user'); sys.exit(1)
# The subject is written to a file rather than stdout so the line above stays
# a checkmark the reader can see.
open(sys.argv[2], 'w').write(claims['sub'])
print('  ✓ sign-in returned an authenticated token with the correct subject')
PY

EMAIL_SUB=$(cat "$WORK/sub.txt")
ANON_SUB=$(python3 -c "
import json; d=json.load(open('$WORK/b.json')); print(d['user']['id'])")
[ -n "$EMAIL_SUB" ] || fail "no subject in the issued token"

# ---------------------------------------------------------------------------
# The seams
# ---------------------------------------------------------------------------

echo "==> checking what GoTrue's writes did to our schema"

# `set -e` would abort on psql's non-zero exit before the diagnostics below
# could run, turning a clear SQL error into a silent stop.
#
# The subjects arrive through `current_setting` rather than as `:'vars'`:
# psql interpolates variables on the client, but it treats a `$$ ... $$` body
# as an opaque literal and leaves them alone — so a variable inside a DO block
# is a syntax error, not a substitution.
if ! docker exec -i "$DB" psql -v ON_ERROR_STOP=1 -U postgres -q \
  -v email_sub="$EMAIL_SUB" -v anon_sub="$ANON_SUB" \
  > "$WORK/checks.txt" 2>&1 <<'SQL'
\set ON_ERROR_STOP on
set "app.email_sub" = :'email_sub';
set "app.anon_sub" = :'anon_sub';

do $$
declare
  sub uuid := current_setting('app.email_sub')::uuid;
  anon uuid := current_setting('app.anon_sub')::uuid;
  n integer;
begin
  -- The trigger on auth.users has to have fired for a user GoTrue created.
  -- This is the seam between our migration and their server: if it is attached
  -- to the wrong table, or fires before the row is visible, the app shows a
  -- blank name and nothing anywhere says why.
  select count(*) into n from public.profiles where id = sub;
  if n <> 1 then
    raise exception 'no profile row for a GoTrue-created user';
  end if;

  select count(*) into n from public.user_settings where user_id = sub;
  if n <> 1 then
    raise exception 'no settings row for a GoTrue-created user';
  end if;

  -- And for an anonymous account, which GoTrue creates with no email at all —
  -- the case where any NOT NULL expectation on display_name would blow up.
  select count(*) into n from public.profiles where id = anon;
  if n <> 1 then
    raise exception 'no profile row for an anonymous user';
  end if;

  raise notice 'trigger fired for both a real and an anonymous signup';
end $$;

-- RLS, driven by the subject of a token GoTrue actually issued rather than one
-- this script invented.
set role authenticated;
set request.jwt.claim.sub = :'email_sub';
insert into public.rides (id, user_id, started_at, distance_meters)
values ('aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa',
        current_setting('app.email_sub')::uuid, '2026-09-23T06:00:00Z', 25000);

set request.jwt.claim.sub = :'anon_sub';
do $$
declare n integer;
begin
  select count(*) into n from public.rides;
  if n <> 0 then
    raise exception 'RLS leak: a second account sees % ride(s)', n;
  end if;
  raise notice 'a second account sees nothing';
end $$;

insert into public.rides (id, user_id, started_at, distance_meters)
values ('bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb',
        current_setting('app.anon_sub')::uuid, '2026-09-23T08:00:00Z', 8000);
reset role;

do $$
declare a integer; b integer;
begin
  select count(*) into a from public.rides
    where user_id = current_setting('app.email_sub')::uuid;
  select count(*) into b from public.rides
    where user_id = current_setting('app.anon_sub')::uuid;
  if a <> 1 or b <> 1 then
    raise exception 'rows landed under the wrong owners: % / %', a, b;
  end if;
  raise notice 'each account wrote, and can read, only its own row';
end $$;
SQL
then
  echo "  ✗ the schema checks failed:" >&2
  cat "$WORK/checks.txt" >&2
  exit 1
fi

if grep -qE 'ERROR|FATAL' "$WORK/checks.txt"; then
  echo "  ✗ the schema checks failed:" >&2
  grep -E 'ERROR|FATAL|CONTEXT|^LINE' "$WORK/checks.txt" >&2
  exit 1
fi

grep -E '^NOTICE' "$WORK/checks.txt" | sed 's/^NOTICE:  */  ✓ /'

echo "==> auth flow OK"
