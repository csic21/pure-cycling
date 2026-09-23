-- Upsert RPCs used by the client's sync queue.
--
-- ## Why an RPC instead of a plain PostgREST upsert
--
-- `route_geometry` is a PostGIS `geometry(LineString, 4326)`. Sending a
-- geometry through PostgREST's automatic casting works on some versions and
-- fails silently or verbosely on others, and the failure mode is a sync that
-- appears to succeed while the geometry column stays null.
--
-- These functions take the geometry as a GeoJSON object and call
-- `ST_GeomFromGeoJSON` explicitly, so the behaviour is identical on any
-- Supabase project. They are `security invoker`, which means they run as the
-- calling user and row level security still applies in full — the RPC is a
-- convenience, never a bypass.
--
-- `user_id` is never taken from the payload. It is always `auth.uid()`, so a
-- crafted request cannot write a ride into somebody else's account even if a
-- policy were ever loosened by mistake.

create or replace function public.push_ride(p_ride jsonb)
returns void
language sql
security invoker
set search_path = public, extensions, pg_temp
as $$
  insert into public.rides (
    id, user_id, name, started_at, ended_at,
    elapsed_seconds, moving_seconds,
    distance_meters, avg_speed_mps, max_speed_mps,
    elevation_gain_meters, elevation_loss_meters,
    start_lat, start_lng, end_lat, end_lng,
    route_geometry, gpx_path, fit_path, notes,
    sync_version, deleted_at, updated_at
  )
  select
    (p_ride->>'id')::uuid,
    auth.uid(),
    nullif(p_ride->>'name', ''),
    (p_ride->>'started_at')::timestamptz,
    nullif(p_ride->>'ended_at', '')::timestamptz,
    coalesce((p_ride->>'elapsed_seconds')::integer, 0),
    coalesce((p_ride->>'moving_seconds')::integer, 0),
    coalesce((p_ride->>'distance_meters')::double precision, 0),
    nullif(p_ride->>'avg_speed_mps', '')::double precision,
    nullif(p_ride->>'max_speed_mps', '')::double precision,
    nullif(p_ride->>'elevation_gain_meters', '')::double precision,
    nullif(p_ride->>'elevation_loss_meters', '')::double precision,
    nullif(p_ride->>'start_lat', '')::double precision,
    nullif(p_ride->>'start_lng', '')::double precision,
    nullif(p_ride->>'end_lat', '')::double precision,
    nullif(p_ride->>'end_lng', '')::double precision,
    case
      when p_ride->'route_geometry' is null
        or jsonb_typeof(p_ride->'route_geometry') <> 'object'
      then null
      else st_setsrid(
        st_geomfromgeojson(p_ride->'route_geometry'::text), 4326
      )
    end,
    nullif(p_ride->>'gpx_path', ''),
    nullif(p_ride->>'fit_path', ''),
    nullif(p_ride->>'notes', ''),
    coalesce((p_ride->>'sync_version')::bigint, 1),
    nullif(p_ride->>'deleted_at', '')::timestamptz,
    coalesce(nullif(p_ride->>'updated_at', '')::timestamptz, now())
  where auth.uid() is not null
  on conflict (id) do update set
    name                   = excluded.name,
    ended_at               = excluded.ended_at,
    elapsed_seconds        = excluded.elapsed_seconds,
    moving_seconds         = excluded.moving_seconds,
    distance_meters        = excluded.distance_meters,
    avg_speed_mps          = excluded.avg_speed_mps,
    max_speed_mps          = excluded.max_speed_mps,
    elevation_gain_meters  = excluded.elevation_gain_meters,
    elevation_loss_meters  = excluded.elevation_loss_meters,
    start_lat              = excluded.start_lat,
    start_lng              = excluded.start_lng,
    end_lat                = excluded.end_lat,
    end_lng                = excluded.end_lng,
    -- Never overwrite a stored line with null: a device that pushes a ride
    -- before its geometry has been built would otherwise erase a good line.
    route_geometry         = coalesce(excluded.route_geometry, rides.route_geometry),
    gpx_path               = coalesce(excluded.gpx_path, rides.gpx_path),
    fit_path               = coalesce(excluded.fit_path, rides.fit_path),
    notes                  = excluded.notes,
    sync_version           = greatest(rides.sync_version, excluded.sync_version),
    deleted_at             = excluded.deleted_at,
    -- The client's clock is authoritative for the conflict rule, but a clock
    -- that is behind the stored value would make the local copy permanently
    -- "older" and lose every merge. monotonicity here prevents that.
    updated_at             = greatest(rides.updated_at, excluded.updated_at);
$$;

comment on function public.push_ride(jsonb) is
  'Idempotent upsert of one ride for the calling user. Geometry arrives as GeoJSON.';

create or replace function public.push_route(p_route jsonb)
returns void
language sql
security invoker
set search_path = public, extensions, pg_temp
as $$
  insert into public.routes (
    id, user_id, name, distance_meters, estimated_seconds,
    elevation_gain_meters, route_geometry, provider, provider_route_id,
    deleted_at, updated_at
  )
  select
    (p_route->>'id')::uuid,
    auth.uid(),
    coalesce(nullif(p_route->>'name', ''), '路线'),
    nullif(p_route->>'distance_meters', '')::double precision,
    nullif(p_route->>'estimated_seconds', '')::integer,
    nullif(p_route->>'elevation_gain_meters', '')::double precision,
    case
      when p_route->'route_geometry' is null
        or jsonb_typeof(p_route->'route_geometry') <> 'object'
      then null
      else st_setsrid(
        st_geomfromgeojson(p_route->'route_geometry'::text), 4326
      )
    end,
    nullif(p_route->>'provider', ''),
    nullif(p_route->>'provider_route_id', ''),
    nullif(p_route->>'deleted_at', '')::timestamptz,
    coalesce(nullif(p_route->>'updated_at', '')::timestamptz, now())
  where auth.uid() is not null
  on conflict (id) do update set
    name                  = excluded.name,
    distance_meters       = excluded.distance_meters,
    estimated_seconds     = excluded.estimated_seconds,
    elevation_gain_meters = excluded.elevation_gain_meters,
    route_geometry        = coalesce(excluded.route_geometry, routes.route_geometry),
    provider              = excluded.provider,
    provider_route_id     = excluded.provider_route_id,
    deleted_at            = excluded.deleted_at,
    updated_at            = greatest(routes.updated_at, excluded.updated_at);
$$;

comment on function public.push_route(jsonb) is
  'Idempotent upsert of one saved route for the calling user.';

-- Functions default to EXECUTE for PUBLIC in Postgres; revoke that and grant
-- only to authenticated, so an anon key cannot even reach the body.
revoke all on function public.push_ride(jsonb) from public, anon;
revoke all on function public.push_route(jsonb) from public, anon;

grant execute on function public.push_ride(jsonb) to authenticated;
grant execute on function public.push_route(jsonb) to authenticated;
