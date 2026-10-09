#!/usr/bin/env bash
# Uses the already-running disposable Supabase DB from verify-migrations.sh.
# Never point this fixture runner at a production database.
set -euo pipefail
: "${CONTAINER:?Set CONTAINER to the disposable verification container}"
work="$(mktemp -d)"
writer_pid=''
psql_stdin() { docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -U postgres -q "$@"; }
cleanup() {
  if [ -n "$writer_pid" ]; then wait "$writer_pid" 2>/dev/null || true; fi
  psql_stdin <<'SQL' >/dev/null 2>&1 || true
-- Test-only metadata fixtures, not production Storage deletion.
delete from storage.objects where name like 'rides/a2000000-0000-4000-8000-000000000001/%';
delete from auth.users where id = 'a2000000-0000-4000-8000-000000000001';
SQL
  rm -rf "$work"
}
trap cleanup EXIT
psql_stdin <<'SQL'
insert into auth.users(id, email) values ('a2000000-0000-4000-8000-000000000001', 'cleanup-race@example.test');
SQL

# An upload has already passed authorization, but its metadata transaction
# has not committed. The fence must wait for it, then enumerate its object.
psql_stdin >"$work/writer.log" 2>&1 <<'SQL' &
set application_name = 'cycling-cleanup-race-writer';
begin;
set local role authenticated;
set local request.jwt.claim.sub = 'a2000000-0000-4000-8000-000000000001';
select set_config('test.upload_path', public.new_gpx_upload_path(
  'b2000000-0000-4000-8000-000000000001',
  'c2000000-0000-4000-8000-000000000001'), true);
select pg_sleep(3);
insert into storage.objects(bucket_id, name)
values ('rides', current_setting('test.upload_path'));
commit;
SQL
writer_pid=$!
ready=false
for _ in $(seq 1 50); do
  if [ "$(psql_stdin -Atc "select count(*) from pg_stat_activity where application_name = 'cycling-cleanup-race-writer' and wait_event = 'PgSleep'")" = 1 ]; then
    ready=true; break
  fi
  sleep 0.05
done
[ "$ready" = true ] || { cat "$work/writer.log"; echo 'upload transaction did not reach the barrier' >&2; exit 1; }
psql_stdin <<'SQL'
select public.begin_account_cleanup('a2000000-0000-4000-8000-000000000001',
  'a2000000-0000-4000-8000-000000000001', 'delete', 'c2000000-0000-4000-8000-000000000001');
do $$
begin
  if (select count(*) from public.list_account_cleanup_objects(
    'a2000000-0000-4000-8000-000000000001', 'c2000000-0000-4000-8000-000000000001')) <> 1 then
    raise exception 'cleanup did not wait for already-authorized upload commit';
  end if;
end;
$$;
set role authenticated;
set request.jwt.claim.sub = 'a2000000-0000-4000-8000-000000000001';
do $$
begin
  begin
    insert into storage.objects(bucket_id, name)
    values ('rides', 'rides/a2000000-0000-4000-8000-000000000001/late/original.gpx');
    raise exception 'upload started after fence was accepted';
  exception when insufficient_privilege then null; end;
end;
$$;
SQL
wait "$writer_pid" || { cat "$work/writer.log"; exit 1; }
writer_pid=''
echo 'account cleanup serialized with in-flight and late Storage writes'
