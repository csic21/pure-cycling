-- Pure Cycling — initial schema.
--
-- Mirrors the local SQLite schema (spec §26) with one deliberate difference:
-- track points are NOT stored as one row per GPS sample (spec §23). A three
-- hour ride is ~10,000 points; multiplying that by every ride from every user
-- is a table that exists to be expensive. The cloud keeps the ride summary
-- plus a PostGIS LineString, and the full-resolution trace lives in Storage as
-- GPX.

-- Keep PostGIS's spatial_ref_sys lookup table outside the public Data API.
-- Supabase includes extensions in the database search_path, but the schema
-- qualification below also makes this migration portable to local Postgres.
create schema if not exists extensions;
create extension if not exists "postgis" with schema extensions;

-- ---------------------------------------------------------------------------
-- profiles (spec §18)
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,

  display_name text,
  avatar_url text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is
  'One row per account. Created by trigger on signup and repaired on sign-in.';

-- ---------------------------------------------------------------------------
-- rides (spec §19)
-- ---------------------------------------------------------------------------

create table if not exists public.rides (
  id uuid primary key,

  user_id uuid not null references auth.users(id) on delete cascade,

  name text,

  started_at timestamptz not null,
  ended_at timestamptz,

  elapsed_seconds integer not null default 0,
  moving_seconds integer not null default 0,

  distance_meters double precision not null default 0,

  avg_speed_mps double precision,
  max_speed_mps double precision,

  elevation_gain_meters double precision,
  elevation_loss_meters double precision,

  start_lat double precision,
  start_lng double precision,

  end_lat double precision,
  end_lng double precision,

  route_geometry extensions.geometry(LineString, 4326),

  gpx_path text,
  fit_path text,

  notes text,

  sync_version bigint not null default 1,

  -- Tombstone. A deleted ride stays as a row so an offline device cannot
  -- resurrect it on the next sync (spec §28).
  deleted_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists rides_user_started_at_idx
  on public.rides(user_id, started_at desc);

create index if not exists rides_route_geometry_idx
  on public.rides using gist(route_geometry);

-- The sync pull filters on updated_at, so it needs its own index or every
-- sync becomes a sequential scan of the user's entire history.
create index if not exists rides_user_updated_at_idx
  on public.rides(user_id, updated_at desc);

-- Partial index: tombstones are a tiny minority of rows and are the only
-- thing the delete-convergence query looks at.
create index if not exists rides_deleted_idx
  on public.rides(user_id, updated_at desc)
  where deleted_at is not null;

comment on column public.rides.route_geometry is
  'Simplified LineString of the recorded track, WGS-84. The full trace is in Storage as GPX.';

-- ---------------------------------------------------------------------------
-- routes (spec §20)
-- ---------------------------------------------------------------------------

create table if not exists public.routes (
  id uuid primary key,

  user_id uuid not null references auth.users(id) on delete cascade,

  name text not null,

  distance_meters double precision,
  estimated_seconds integer,

  elevation_gain_meters double precision,

  route_geometry extensions.geometry(LineString, 4326),

  provider text,
  provider_route_id text,

  deleted_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists routes_user_updated_at_idx
  on public.routes(user_id, updated_at desc);

create index if not exists routes_route_geometry_idx
  on public.routes using gist(route_geometry);

-- ---------------------------------------------------------------------------
-- bikes (spec §21) — not surfaced in V1 UI, but the table exists so a ride can
-- reference a bike without a later migration reshaping existing rows.
-- ---------------------------------------------------------------------------

create table if not exists public.bikes (
  id uuid primary key,

  user_id uuid not null references auth.users(id) on delete cascade,

  name text not null,

  brand text,
  model text,

  total_distance_meters double precision not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists bikes_user_idx on public.bikes(user_id);

-- ---------------------------------------------------------------------------
-- user_settings (spec §22)
-- ---------------------------------------------------------------------------

create table if not exists public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,

  units text not null default 'metric',

  auto_pause boolean not null default true,

  oled_mode boolean not null default true,

  pixel_shift boolean not null default true,

  dashboard_config jsonb not null default '{}'::jsonb,

  navigation_config jsonb not null default '{}'::jsonb,

  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

drop trigger if exists bikes_touch_updated_at on public.bikes;
create trigger bikes_touch_updated_at
  before update on public.bikes
  for each row execute function public.touch_updated_at();

-- rides and routes deliberately do NOT get this trigger.
--
-- The client sets `updated_at` explicitly so the conflict rule ("local wins
-- when local.updated_at > cloud.updated_at", spec §28) compares two clocks
-- from the same device. Overwriting it with the server clock on every write
-- would make the comparison meaningless and let a stale device win.

-- ---------------------------------------------------------------------------
-- profile bootstrap
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'display_name',
      split_part(coalesce(new.email, ''), '@', 1)
    )
  )
  on conflict (id) do nothing;

  insert into public.user_settings (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
