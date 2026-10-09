#!/usr/bin/env bash
# Real Storage HTTP + GoTrue + Postgres, with disposable local fixtures only.
# Pinned official images. A partial raw file is the preflight-passed barrier,
# not a guessed sleep; the helper checks physical version cleanup afterward.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NET="${NET:-cycling-storage-verify}"
DB="${DB:-cycling-storage-db}"
AUTH="${AUTH:-cycling-storage-auth}"
STORAGE="${STORAGE:-cycling-storage-api}"
PORT_AUTH="${PORT_AUTH:-55451}"
PORT_STORAGE="${PORT_STORAGE:-55452}"
PG_IMAGE="${PG_IMAGE:-supabase/postgres:15.8.1.060}"
AUTH_IMAGE="${AUTH_IMAGE:-supabase/gotrue:v2.177.0}"
STORAGE_IMAGE="${STORAGE_IMAGE:-supabase/storage-api:v1.74.0}"
JWT_SECRET='local-storage-regression-only-secret-at-least-32-characters'
WORK="$(mktemp -d)"
cleanup() {
  docker rm -f "$STORAGE" "$AUTH" "$DB" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  # Storage's container may create files as root. Delete only our temp fixture
  # directory through that same official image before removing the directory.
  docker run --rm -v "$WORK:/fixture" --entrypoint sh "$STORAGE_IMAGE" \
    -c 'rm -rf /fixture/storage' >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() {
  echo "  ✗ $1" >&2
  docker logs "$STORAGE" 2>&1 | tail -50 >&2 || true
  exit 1
}
command -v docker >/dev/null || fail 'Docker is required; this test never uses a hosted project'
mkdir "$WORK/storage"
chmod 777 "$WORK/storage"
# A bind mount's parent only needs traversal; fixtures remain private otherwise.
chmod 711 "$WORK"
python3 - "$WORK/keys.json" "$JWT_SECRET" <<'PY'
import base64, hashlib, hmac, json, sys, time
b64 = lambda value: base64.urlsafe_b64encode(value).rstrip(b'=').decode()
def token(role):
    head = b64(b'{"alg":"HS256","typ":"JWT"}')
    body = b64(json.dumps({'role': role, 'iss': 'supabase', 'iat': int(time.time()), 'exp': int(time.time()) + 3600}).encode())
    signature = b64(hmac.new(sys.argv[2].encode(), f'{head}.{body}'.encode(), hashlib.sha256).digest())
    return f'{head}.{body}.{signature}'
with open(sys.argv[1], 'w') as f: json.dump({'anon':token('anon'), 'service':token('service_role')}, f)
PY
ANON_KEY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anon"])' "$WORK/keys.json")"
SERVICE_KEY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["service"])' "$WORK/keys.json")"

docker network create "$NET" >/dev/null
docker run -d --name "$DB" --network "$NET" -e POSTGRES_PASSWORD=postgres "$PG_IMAGE" >/dev/null
for _ in $(seq 1 120); do
  ready="$(docker logs "$DB" 2>&1 | grep -c 'database system is ready to accept connections' || true)"
  [ "${ready:-0}" -ge 2 ] && break
  sleep 1
done
psql_stdin() { docker exec -i "$DB" psql -U postgres -v ON_ERROR_STOP=1 -q; }
psql_stdin <<'SQL'
select 1;
alter role supabase_storage_admin with password 'postgres';
SQL

docker run -d --name "$AUTH" --network "$NET" -p "127.0.0.1:${PORT_AUTH}:9999" \
  -e GOTRUE_DB_DRIVER=postgres \
  -e "GOTRUE_DB_DATABASE_URL=postgres://supabase_admin:postgres@${DB}:5432/postgres?search_path=auth&sslmode=disable" \
  -e "API_EXTERNAL_URL=http://127.0.0.1:${PORT_AUTH}" -e GOTRUE_SITE_URL=http://localhost \
  -e "GOTRUE_JWT_SECRET=$JWT_SECRET" -e GOTRUE_JWT_EXP=3600 \
  -e GOTRUE_API_HOST=0.0.0.0 -e GOTRUE_API_PORT=9999 -e GOTRUE_DISABLE_SIGNUP=false \
  -e GOTRUE_MAILER_AUTOCONFIRM=true "$AUTH_IMAGE" >/dev/null
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:${PORT_AUTH}/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:${PORT_AUTH}/health" >/dev/null || fail 'Auth did not start'

docker run -d --name "$STORAGE" --network "$NET" -p "127.0.0.1:${PORT_STORAGE}:5000" \
  -e "AUTH_JWT_SECRET=$JWT_SECRET" -e "PGRST_JWT_SECRET=$JWT_SECRET" \
  -e "ANON_KEY=$ANON_KEY" -e "SERVICE_KEY=$SERVICE_KEY" \
  -e "DATABASE_URL=postgres://supabase_storage_admin:postgres@${DB}:5432/postgres" \
  -e POSTGREST_URL=http://unused-postgrest:3000 \
  -e STORAGE_BACKEND=file -e FILE_STORAGE_BACKEND_PATH=/var/lib/storage \
  -e TENANT_ID=cleanup-test -e GLOBAL_S3_BUCKET=cleanup-test -e REGION=local \
  -e FILE_SIZE_LIMIT=52428800 -e ENABLE_IMAGE_TRANSFORMATION=false \
  -e PG_QUEUE_ENABLE=true -e PG_QUEUE_WORKERS_ENABLE=true \
  -v "$WORK/storage:/var/lib/storage" "$STORAGE_IMAGE" >/dev/null
for _ in $(seq 1 90); do
  curl -fsS "http://127.0.0.1:${PORT_STORAGE}/status" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:${PORT_STORAGE}/status" >/dev/null || fail 'Storage did not start'

# Seed genuine old-client files before the new write restrictions are applied.
# This proves legacy-read compatibility without disabling the finalization guard.
reached_access=false
for migration in "$REPO_ROOT"/supabase/migrations/*.sql; do
  case "$migration" in *_account_cleanup_and_access.sql) reached_access=true; break;; esac
  psql_stdin < "$migration"
done
[ "$reached_access" = true ] || fail 'account access migration not found'
export STORAGE_TEST_DB="$DB" STORAGE_TEST_AUTH_URL="http://127.0.0.1:$PORT_AUTH"
export STORAGE_TEST_URL="http://127.0.0.1:$PORT_STORAGE" STORAGE_TEST_WORK="$WORK"
python3 "$REPO_ROOT/scripts/test_helpers/storage_cleanup.py" seed

apply_remaining=false
for migration in "$REPO_ROOT"/supabase/migrations/*.sql; do
  case "$migration" in *_account_cleanup_and_access.sql) apply_remaining=true;; esac
  if [ "$apply_remaining" = true ]; then psql_stdin < "$migration"; fi
done
python3 "$REPO_ROOT/scripts/test_helpers/storage_cleanup.py" verify

echo '==> real Storage cleanup regressions passed'
