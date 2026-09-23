#!/usr/bin/env bash
#
# Validates the Supabase migrations against a real Postgres + PostGIS.
#
# The migrations reference Supabase-managed objects that do not exist in a
# stock Postgres — the `auth` schema, `auth.uid()`, the `storage` tables — so
# this harness creates minimal stand-ins first. A migration that passes here
# is syntactically and semantically valid; it does not prove the Supabase
# project itself is configured identically, but it does catch the failures
# that are otherwise only discovered by applying to production.
#
# Usage: scripts/verify-migrations.sh
set -euo pipefail

CONTAINER="${CONTAINER:-cycling-pg-verify}"
PORT="${PORT:-55433}"
IMAGE="${IMAGE:-postgis/postgis:16-3.4}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> starting $IMAGE"
docker run -d --name "$CONTAINER" \
  -e POSTGRES_PASSWORD=postgres -p "${PORT}:5432" "$IMAGE" >/dev/null

# Wait for the *second* "ready to accept connections".
#
# The postgres entrypoint starts a temporary server to run its init scripts,
# then shuts it down and starts the real one. `pg_isready` succeeds against the
# temporary instance, so a naive wait lets the migrations land while the
# database is still being initialised — which shows up as a spurious
# "duplicate key value violates unique constraint pg_extension_name_index"
# from `create extension if not exists postgis`, and intermittent 137s.
echo "==> waiting for postgres to finish initialising"
for _ in $(seq 1 90); do
  ready_count=$(docker logs "$CONTAINER" 2>&1 |
    grep -c 'database system is ready to accept connections' || true)
  if [ "${ready_count:-0}" -ge 2 ]; then
    break
  fi
  sleep 1
done

# Belt and braces: confirm a real query round-trips before starting.
for _ in $(seq 1 30); do
  if docker exec "$CONTAINER" psql -U postgres -q -c 'select 1' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Reads SQL from stdin and applies it, stopping at the first error.
psql_stdin() {
  docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -U postgres -q
}

echo "==> creating Supabase stand-ins"
psql_stdin <<'SQL'
create schema if not exists auth;
create schema if not exists storage;

create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb default '{}'::jsonb
);

create or replace function auth.uid() returns uuid
language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

create table storage.buckets (
  id text primary key,
  name text not null,
  public boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[]
);

create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid
);

create or replace function storage.foldername(name text) returns text[]
language sql immutable as $$
  select string_to_array(name, '/')
$$;

create role anon;
create role authenticated;

-- In a real project these grants are part of Supabase's own bootstrap. The
-- policies in the migrations call auth.uid(), so the role needs to reach it.
grant usage on schema auth, storage to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
grant execute on function storage.foldername(text) to anon, authenticated;
grant select on storage.buckets, storage.objects to authenticated;
SQL

echo "==> applying migrations"
for migration in "$REPO_ROOT"/supabase/migrations/*.sql; do
  echo "    $(basename "$migration")"
  psql_stdin < "$migration"
done

echo "==> exercising push_ride / push_route as an authenticated user"
psql_stdin <<'SQL'
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

-- Idempotency: the same push twice must not duplicate or error.
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

reset role;

do $$
declare
  v_rides integer;
  v_name text;
  v_geom_type text;
  v_route integer;
  v_settings integer;
  v_profile integer;
  v_length double precision;
begin
  select count(*), max(name) into v_rides, v_name from public.rides;
  if v_rides <> 1 then
    raise exception 'expected 1 ride after two upserts, found %', v_rides;
  end if;
  if v_name <> 'Morning ride (renamed)' then
    raise exception 'upsert did not update the name: %', v_name;
  end if;

  select geometrytype(route_geometry) into v_geom_type
    from public.rides where id = '22222222-2222-7222-8222-222222222222';
  if v_geom_type <> 'LINESTRING' then
    raise exception 'ride geometry not stored: %', coalesce(v_geom_type, 'NULL');
  end if;

  select count(*) into v_route from public.routes;
  if v_route <> 1 then
    raise exception 'expected 1 route, found %', v_route;
  end if;

  select count(*) into v_profile from public.profiles;
  if v_profile <> 1 then
    raise exception 'profile trigger did not run: %', v_profile;
  end if;

  select count(*) into v_settings from public.user_settings;
  if v_settings <> 1 then
    raise exception 'settings row not created: %', v_settings;
  end if;

  -- The line has real length. A geometry column that accepts an insert but
  -- stores an empty or degenerate shape is the failure this catches.
  select st_length(route_geometry::geography) into v_length
    from public.rides where id = '22222222-2222-7222-8222-222222222222';
  if v_length is null or v_length <= 0 then
    raise exception 'ride geometry has no length';
  end if;

  select st_length(route_geometry::geography) into v_length
    from public.routes where id = '33333333-3333-7333-8333-333333333333';
  if v_length is null or v_length <= 0 then
    raise exception 'route geometry has no length';
  end if;

  raise notice 'upsert, geometry and trigger checks passed';
end $$;

-- RLS must be switched on for every user table.
do $$
declare
  r record;
begin
  for r in
    select tablename from pg_tables
    where schemaname = 'public'
      and tablename in ('profiles','rides','routes','bikes','user_settings')
  loop
    if not exists (
      select 1 from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = r.tablename and c.relrowsecurity
    ) then
      raise exception 'RLS is not enabled on public.%', r.tablename;
    end if;
  end loop;
  raise notice 'rls enabled on all user tables';
end $$;

-- ---------------------------------------------------------------------------
-- Isolation: a second account must see none of the first account's data, and
-- must not be able to write into the first account's rows.
--
-- "RLS is enabled" is not the same as "RLS works". A policy with `user_id =
-- user_id` instead of `auth.uid() = user_id` is enabled, syntactically valid,
-- and lets every user read every ride. This is the check that catches it.
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('99999999-9999-7999-8999-999999999999', 'other@example.com');

set role authenticated;
set request.jwt.claim.sub = '99999999-9999-7999-8999-999999999999';

do $$
declare
  v_rides integer;
  v_routes integer;
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

-- Writing a ride under another account's user_id must be rejected. The RPC
-- takes user_id from auth.uid() rather than the payload, so this asserts that
-- the insert policy is doing its job as well.
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

reset role;

-- The push RPC must ignore a user_id smuggled into the payload.
set role authenticated;
set request.jwt.claim.sub = '99999999-9999-7999-8999-999999999999';
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
declare
  v_owner uuid;
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

echo "==> migrations OK"
