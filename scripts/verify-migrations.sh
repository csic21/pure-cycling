#!/usr/bin/env bash
#
# Validates the Supabase migrations against Supabase's own Postgres image.
#
# ## Why this image and not a generic one
#
# The first version of this script ran against `postgis/postgis` with hand-written
# stubs for `auth.users`, `auth.uid()` and `storage.*`. That tests the SQL
# syntax and nothing else: the things most likely to be wrong — whether
# `auth.uid()` behaves the way the policies assume, whether the storage schema
# has the columns the migration writes, whether the grants are even meaningful —
# are exactly the things the stubs replace.
#
# It found a real bug the moment it was pointed at the real image. `storage.buckets`
# there is `id | name | owner | created_at | updated_at`; `public`,
# `file_size_limit` and `allowed_mime_types` are added by *storage-api's own
# migrations*, which run when that service starts. `supabase db reset` applies
# these migrations while the stack is still coming up, so a plain
# `insert ... public` succeeded or failed depending on whether storage-api won
# the race. The migration now guards on the column's presence.
#
# Usage: scripts/verify-migrations.sh
set -euo pipefail

CONTAINER="${CONTAINER:-cycling-supa-verify}"
PORT="${PORT:-55445}"
IMAGE="${IMAGE:-supabase/postgres:15.8.1.060}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> starting $IMAGE"
cleanup
docker run -d --name "$CONTAINER" \
  -e POSTGRES_PASSWORD=postgres -p "${PORT}:5432" "$IMAGE" >/dev/null

# Wait for the *second* "ready", not for pg_isready. The image runs its own
# bootstrap on a temporary server first; connecting during that window gives
# confusing errors from a database that is still being created.
echo "==> waiting for postgres to finish initialising"
for _ in $(seq 1 120); do
  ready=$(docker logs "$CONTAINER" 2>&1 |
    grep -c 'database system is ready to accept connections' || true)
  [ "${ready:-0}" -ge 2 ] && break
  sleep 1
done

for _ in $(seq 1 30); do
  docker exec "$CONTAINER" psql -U postgres -q -c 'select 1' >/dev/null 2>&1 && break
  sleep 1
done

# Reads SQL from stdin and applies it, stopping at the first error.
psql_stdin() {
  docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -U postgres -q
}

echo "==> confirming the image ships a real Supabase schema"
psql_stdin <<'SQL'
do $$
begin
  if not exists (select 1 from pg_namespace where nspname = 'auth') then
    raise exception 'the image has no auth schema — this is not a Supabase image';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'auth' and p.proname = 'uid'
  ) then
    raise exception 'auth.uid() is missing — the RLS policies would be untestable';
  end if;
end $$;
SQL

echo "==> applying migrations"
for migration in "$REPO_ROOT"/supabase/migrations/*.sql; do
  echo "    $(basename "$migration")"
  psql_stdin < "$migration"
done

echo "==> exercising push_ride / push_route as an authenticated user"
psql_stdin <<'SQL'
-- A real row in Supabase's own auth.users. No stub: the foreign keys, the
-- trigger and auth.uid() are all the genuine article.
insert into auth.users (id, email) values
  ('11111111-1111-7111-8111-111111111111', 'rider@example.com');

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-7111-8111-111111111111';

select public.push_ride(jsonb_build_object(
  'id', '22222222-2222-7222-8222-222222222222',
  'name', 'Morning ride',
  'started_at', '2026-09-23T06:00:00Z',
  'ended_at', '2026-09-23T07:30:00Z',
  'elapsed_seconds', 5400,
  'moving_seconds', 5100,
  'distance_meters', 42195.5,
  'avg_speed_mps', 8.27,
  'max_speed_mps', 14.1,
  'elevation_gain_meters', 486,
  'elevation_loss_meters', 480,
  'start_lat', 31.2304, 'start_lng', 121.4737,
  'end_lat', 31.2404, 'end_lng', 121.4837,
  'gpx_path', 'rides/11111111-1111-7111-8111-111111111111/22222222-2222-7222-8222-222222222222/original.gpx',
  'route_geometry', jsonb_build_object(
    'type', 'LineString',
    'coordinates', jsonb_build_array(
      jsonb_build_array(121.4737, 31.2304),
      jsonb_build_array(121.4837, 31.2404)
    )
  ),
  'updated_at', '2026-09-23T07:31:00Z'
));

-- Idempotency, and the second push deliberately carries no geometry: a device
-- that pushes before its line is built must not erase the stored one.
select public.push_ride(jsonb_build_object(
  'id', '22222222-2222-7222-8222-222222222222',
  'name', 'Morning ride (renamed)',
  'started_at', '2026-09-23T06:00:00Z',
  'elapsed_seconds', 5400,
  'moving_seconds', 5100,
  'distance_meters', 42195.5,
  'updated_at', '2026-09-23T07:35:00Z'
));

select public.push_route(jsonb_build_object(
  'id', '33333333-3333-7333-8333-333333333333',
  'name', 'Lakeside loop',
  'distance_meters', 56200,
  'estimated_seconds', 9060,
  'provider', 'amap',
  'route_geometry', jsonb_build_object(
    'type', 'LineString',
    'coordinates', jsonb_build_array(
      jsonb_build_array(121.4737, 31.2304),
      jsonb_build_array(121.4937, 31.2504)
    )
  ),
  'updated_at', '2026-09-23T08:00:00Z'
));
SQL

echo "==> asserting the results"
psql_stdin <<'SQL'
reset role;

do $$
declare
  v_rides integer;
  v_name text;
  v_geom text;
  v_length double precision;
  v_routes integer;
  v_profiles integer;
  v_settings integer;
  v_bucket text;
  v_storage_policies integer;
begin
  select count(*), max(name) into v_rides, v_name from public.rides;
  if v_rides <> 1 then
    raise exception 'expected 1 ride after two upserts, found %', v_rides;
  end if;
  if v_name <> 'Morning ride (renamed)' then
    raise exception 'the upsert did not update the name: %', v_name;
  end if;

  select extensions.geometrytype(route_geometry), extensions.st_length(route_geometry::extensions.geography)
    into v_geom, v_length
    from public.rides where id = '22222222-2222-7222-8222-222222222222';
  if v_geom <> 'LINESTRING' then
    raise exception 'the ride geometry was not stored: %', coalesce(v_geom, 'NULL');
  end if;
  if v_length <= 0 then
    raise exception 'the ride geometry has no length';
  end if;

  select count(*) into v_routes from public.routes;
  if v_routes <> 1 then
    raise exception 'expected 1 route, found %', v_routes;
  end if;

  select count(*) into v_profiles from public.profiles;
  if v_profiles <> 1 then
    raise exception 'the profile trigger did not run: %', v_profiles;
  end if;

  select count(*) into v_settings from public.user_settings;
  if v_settings <> 1 then
    raise exception 'the settings row was not created: %', v_settings;
  end if;

  select id into v_bucket from storage.buckets where id = 'rides';
  if v_bucket is null then
    raise exception 'the GPX bucket was not created';
  end if;

  select count(*) into v_storage_policies from pg_policies where schemaname = 'storage';
  if v_storage_policies < 4 then
    raise exception 'expected 4 storage policies, found %', v_storage_policies;
  end if;

  raise notice 'upsert, geometry, trigger and storage checks passed (% m)', round(v_length);
end $$;

-- RLS must be switched on for every user table.
do $$
declare r record;
begin
  for r in
    select tablename from pg_tables
    where schemaname = 'public'
      and tablename in (
        'profiles','rides','routes','bikes','user_settings',
        'admins','admin_audit'
      )
  loop
    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = r.tablename and c.relrowsecurity
    ) then
      raise exception 'RLS is not enabled on public.%', r.tablename;
    end if;
  end loop;
  raise notice 'rls enabled on all user tables';
end $$;

-- ---------------------------------------------------------------------------
-- Isolation. "RLS is enabled" is not "RLS works": a policy written as
-- `user_id = user_id` is enabled, valid, and lets every user read everything.
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('99999999-9999-7999-8999-999999999999', 'other@example.com');

set role authenticated;
set request.jwt.claim.sub = '99999999-9999-7999-8999-999999999999';

do $$
declare v_rides integer; v_routes integer;
begin
  select count(*) into v_rides from public.rides;
  select count(*) into v_routes from public.routes;

  if v_rides <> 0 then
    raise exception 'RLS leak: another account can read % ride(s)', v_rides;
  end if;
  if v_routes <> 0 then
    raise exception 'RLS leak: another account can read % route(s)', v_routes;
  end if;

  raise notice 'cross-account reads are correctly blocked';
end $$;

-- Writing a ride under somebody else's user_id must be rejected by the insert
-- policy, not merely ignored.
do $$
begin
  begin
    insert into public.rides (id, user_id, started_at, distance_meters)
    values (
      '44444444-4444-7444-8444-444444444444',
      '11111111-1111-7111-8111-111111111111',
      now(), 1
    );
    raise exception 'RLS leak: inserted a ride into another account';
  exception
    when insufficient_privilege then
      raise notice 'cross-account writes are correctly blocked';
  end;
end $$;

-- …and the RPC must ignore a user_id smuggled into the payload, because it
-- takes the owner from auth.uid() rather than from the caller.
select public.push_ride(jsonb_build_object(
  'id', '55555555-5555-7555-8555-555555555555',
  'user_id', '11111111-1111-7111-8111-111111111111',
  'name', 'Injected',
  'started_at', '2026-09-23T09:00:00Z',
  'distance_meters', 1,
  'updated_at', '2026-09-23T09:01:00Z'
));
reset role;

do $$
declare v_owner uuid;
begin
  select user_id into v_owner from public.rides
    where id = '55555555-5555-7555-8555-555555555555';
  if v_owner is null then
    raise exception 'push_ride did not insert the row';
  end if;
  if v_owner <> '99999999-9999-7999-8999-999999999999' then
    raise exception 'push_ride honoured a spoofed user_id: %', v_owner;
  end if;
  raise notice 'push_ride ignores a caller-supplied user_id';
end $$;
SQL

echo "==> asserting the public key boundary"
psql_stdin <<'SQL'
-- ---------------------------------------------------------------------------
-- The public key
--
-- This is the boundary that matters once the app is distributed. The binary
-- ships the anon key on purpose, so anyone can extract it and call PostgREST,
-- GoTrue and Storage. "It is safe because the key is public" is only true
-- while every table has RLS and every policy is scoped to a role that only a
-- signed-in user holds — and Supabase's image grants `all` on new public
-- tables to `anon` by default, so the grants are *not* the barrier. The
-- policies are. Nothing here should be reachable.
-- ---------------------------------------------------------------------------

set role anon;

do $$
declare
  v_rows integer;
  v_table text;
begin
  foreach v_table in array array[
    'rides', 'routes', 'profiles', 'user_settings', 'bikes', 'admin_audit'
  ] loop
    begin
      execute format('select count(*) from public.%I', v_table) into v_rows;
      if v_rows <> 0 then
        raise exception 'public key leak: anon can read % row(s) from public.%',
          v_rows, v_table;
      end if;
    exception
      when insufficient_privilege then
        -- No grant at all at this table (that is how `admins` and
        -- `admin_audit` are set up). Stronger than an empty result, and just
        -- as safe.
        null;
    end;
  end loop;

  select count(*) into v_rows from storage.objects;
  if v_rows <> 0 then
    raise exception 'public key leak: anon can list % storage object(s)', v_rows;
  end if;

  raise notice 'the public key reads nothing';
end $$;

do $$
begin
  begin
    insert into public.rides (id, user_id, started_at, distance_meters)
    values ('66666666-6666-7666-8666-666666666666',
            '11111111-1111-7111-8111-111111111111', now(), 1);
    raise exception 'anon wrote a ride';
  exception
    when insufficient_privilege then
      raise notice 'anon cannot write rides';
  end;

  begin
    perform public.push_ride('{}'::jsonb);
    raise exception 'anon executed push_ride';
  exception
    when insufficient_privilege then
      raise notice 'anon cannot execute push_ride';
  end;

  begin
    perform public.admin_list_users(null, 1, 0);
    raise exception 'anon executed admin_list_users';
  exception
    when insufficient_privilege then
      raise notice 'anon cannot execute admin_list_users';
  end;

  begin
    perform public.is_admin();
    raise exception 'anon executed is_admin';
  exception
    when insufficient_privilege then
      raise notice 'anon cannot execute is_admin';
  end;

  begin
    perform 1 from public.admins;
    raise exception 'anon can read public.admins';
  exception
    when insufficient_privilege then
      raise notice 'anon cannot read public.admins';
  end;
end $$;

reset role;
SQL

echo "==> asserting the admin boundary"
psql_stdin <<'SQL'
-- ---------------------------------------------------------------------------
-- Admin access. The assertion that matters is the last one: an admin can list
-- accounts and read the audit log, and still cannot read a single ride.
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa', 'admin@example.com'),
  -- An anonymous account: no address, so an email search cannot find it. It
  -- still has to appear in the unfiltered list — the console says as much in
  -- its empty state.
  ('bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb', null);

insert into public.admins (user_id, note) values
  ('aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa', 'created by verify-migrations.sh');

-- One audit row, written the way the console writes it: with the service role.
insert into public.admin_audit (admin_id, action, target_user_id, detail) values
  ('aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa',
   'verify_migrations',
   '11111111-1111-7111-8111-111111111111',
   '{"reason":"harness"}'::jsonb);

set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa';

do $$
declare
  v_accounts bigint;
  v_matches bigint;
  v_total bigint;
  v_rider_email text;
  v_rides bigint;
  v_audit bigint;
begin
  select count(*) into v_accounts from public.admin_list_users();
  if v_accounts < 4 then
    raise exception 'admin_list_users returned % accounts, expected at least 4', v_accounts;
  end if;

  -- Search: only the matching account, and a total that follows the filter —
  -- the console shows 「匹配 N 个」 from that number.
  select count(*) into v_matches from public.admin_list_users('rider@');
  if v_matches <> 1 then
    raise exception 'searching for rider@ returned % rows, expected 1', v_matches;
  end if;

  select total into v_total from public.admin_list_users('rider@');
  if v_total <> 1 then
    raise exception 'search total was %, expected 1', v_total;
  end if;

  -- `position()`, not `ilike`: every email contains '@', and none of the
  -- accounts with an address should be filtered out by it. The anonymous
  -- account has no address, so it is not in this result.
  select count(*) into v_matches from public.admin_list_users('@');
  if v_matches <> 3 then
    raise exception 'searching for @ returned %, expected the 3 accounts with an email',
      v_matches;
  end if;

  -- Pagination: one row per page, while `total` stays the size of the whole
  -- filtered set. That is what tells the console the next page exists.
  select count(*) into v_matches from public.admin_list_users(null, 1, 0);
  if v_matches <> 1 then
    raise exception 'a one-row page returned % rows', v_matches;
  end if;

  select total into v_total from public.admin_list_users(null, 1, 0);
  select count(*) into v_accounts from public.admin_list_users();
  if v_total <> v_accounts then
    raise exception 'paged total was %, unfiltered count was %', v_total, v_accounts;
  end if;

  select email into v_rider_email
    from public.admin_list_users()
    where id = '11111111-1111-7111-8111-111111111111';
  if v_rider_email <> 'rider@example.com' then
    raise exception 'admin_list_users is missing the rider account (got %)',
      coalesce(v_rider_email, 'NULL');
  end if;

  -- The privacy line: account metadata yes, location traces no.
  select count(*) into v_rides from public.rides;
  if v_rides <> 0 then
    raise exception 'privacy leak: an admin can read % ride(s)', v_rides;
  end if;

  select count(*) into v_audit from public.admin_audit;
  if v_audit < 1 then
    raise exception 'an admin cannot read the audit log';
  end if;

  raise notice 'admin can search, page, list accounts and read the audit log, but not rides';
end $$;

-- The console derives 「已封禁」 from its own audit trail, so the state has to
-- follow the latest disable/enable row.
reset role;
insert into public.admin_audit (admin_id, action, target_user_id)
values ('aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa',
        'disable_user',
        '99999999-9999-7999-8999-999999999999');
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa';

do $$
declare v_state text;
begin
  select access_state into v_state
    from public.admin_list_users()
    where id = '99999999-9999-7999-8999-999999999999';
  if v_state <> 'disabled' then
    raise exception 'access_state did not follow the audit trail: %',
      coalesce(v_state, 'NULL');
  end if;
  raise notice 'access_state follows the console audit trail';
end $$;

-- The membership table is not reachable through the Data API at all.
do $$
begin
  begin
    perform 1 from public.admins;
    raise exception 'public.admins is reachable through the Data API';
  exception
    when insufficient_privilege then
      raise notice 'admins table is not exposed to the Data API';
  end;
end $$;

-- …and a non-admin is refused by the list RPC and sees no audit rows.
reset role;
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-7111-8111-111111111111';

do $$
declare v_audit bigint;
begin
  begin
    perform 1 from public.admin_list_users();
    raise exception 'a non-admin could call admin_list_users';
  exception
    when insufficient_privilege then
      raise notice 'non-admins are refused by admin_list_users';
  end;

  -- Invisible rather than forbidden: the grant exists, the policy filters
  -- every row.
  select count(*) into v_audit from public.admin_audit;
  if v_audit <> 0 then
    raise exception 'audit leak: a non-admin can read % audit row(s)', v_audit;
  end if;

  raise notice 'non-admins see neither the account list nor the audit log';
end $$;

reset role;
SQL

echo "==> asserting the rate limit"
psql_stdin <<'SQL'
-- The routing relay is an edge function: it runs with the service role, so
-- RLS is not its guard — this counter is. Three things have to hold: it
-- allows up to the limit, it refuses after it, and only the service role can
-- touch it.
do $$
declare
  v_allowed boolean;
  v_user uuid := '11111111-1111-7111-8111-111111111111';
  i integer;
begin
  for i in 1..3 loop
    select public.consume_rate_limit(v_user, 'route-test', 3, 3600) into v_allowed;
    if not v_allowed then
      raise exception 'rate limit refused call % of 3', i;
    end if;
  end loop;

  select public.consume_rate_limit(v_user, 'route-test', 3, 3600) into v_allowed;
  if v_allowed then
    raise exception 'rate limit allowed a call past the limit';
  end if;

  -- A different bucket has its own window.
  select public.consume_rate_limit(v_user, 'other-bucket', 3, 3600) into v_allowed;
  if not v_allowed then
    raise exception 'rate limit leaked across buckets';
  end if;

  raise notice 'rate limit allows the quota, refuses the next call, and is per bucket';
end $$;

-- The table is invisible through the Data API, and the function is not
-- callable by anyone but the service role.
set role authenticated;

do $$
begin
  begin
    perform 1 from public.rate_limits;
    raise exception 'rate_limits is reachable through the Data API';
  exception
    when insufficient_privilege then
      raise notice 'rate_limits is not exposed';
  end;

  begin
    perform public.consume_rate_limit(
      '11111111-1111-7111-8111-111111111111', 'x', 1, 60);
    raise exception 'a normal user could consume the quota';
  exception
    when insufficient_privilege then
      raise notice 'only the service role can consume the quota';
  end;
end $$;

reset role;
SQL

echo "==> migrations OK"
