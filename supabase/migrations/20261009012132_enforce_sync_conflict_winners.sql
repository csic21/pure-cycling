-- Atomically choose the winning edit before any column can be overwritten.
-- Structured v2 RPCs return winners; legacy void RPCs reject losing writes
-- rather than letting old clients delete the live winner's GPX after a no-op.
create function public.push_ride_v2(p_ride jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public, extensions, pg_temp
as $$
declare
  winner public.rides%rowtype;
  accepted boolean;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  -- A device may retain a once-valid reference after a wipe on another
  -- device. Never recreate a live row pointing at missing private bytes.
  -- Tombstone retries are allowed after their file has already been removed.
  if nullif(p_ride->>'deleted_at', '') is null
    and nullif(p_ride->>'gpx_path', '') is not null
    and (left(p_ride->>'gpx_path', length('rides/' || auth.uid()::text || '/' || (p_ride->>'id')::uuid::text || '/'))
           <> 'rides/' || auth.uid()::text || '/' || (p_ride->>'id')::uuid::text || '/'
      or not exists (select 1 from storage.objects
        where bucket_id = 'rides' and name = p_ride->>'gpx_path')) then
    raise exception 'GPX_OBJECT_MISSING' using errcode = 'PC001';
  end if;
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
      else extensions.st_setsrid(
        extensions.st_geomfromgeojson(p_ride->'route_geometry'::text), 4326
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
    updated_at             = excluded.updated_at
  -- The predicate and row lock belong in Postgres, not a client-side preflight.
  -- Existing tombstones are terminal; ties keep the server winner, except a
  -- delete wins a live/delete tie. Replayed requests return the same winner.
  where (public.rides.deleted_at is null or excluded.deleted_at is not null)
    and (excluded.updated_at > public.rides.updated_at or
      (excluded.updated_at = public.rides.updated_at
       and public.rides.deleted_at is null and excluded.deleted_at is not null))
  returning * into winner;
  accepted := found;
  if not accepted then
    select * into strict winner from public.rides
      where id = (p_ride->>'id')::uuid and user_id = auth.uid();
  end if;
  return jsonb_build_object('accepted', accepted, 'row',
    to_jsonb(winner) || jsonb_build_object('route_geometry',
      case when winner.route_geometry is null then null
      else extensions.st_asgeojson(winner.route_geometry)::jsonb end));
end;
$$;

comment on function public.push_ride_v2(jsonb) is
  'Idempotent upsert of one ride for the calling user. Geometry arrives as GeoJSON.';

create function public.push_route_v2(p_route jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = public, extensions, pg_temp
as $$
declare
  winner public.routes%rowtype;
  accepted boolean;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
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
      else extensions.st_setsrid(
        extensions.st_geomfromgeojson(p_route->'route_geometry'::text), 4326
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
    updated_at             = excluded.updated_at
  -- The predicate and row lock belong in Postgres, not a client-side preflight.
  -- Existing tombstones are terminal; ties keep the server winner, except a
  -- delete wins a live/delete tie. Replayed requests return the same winner.
  where (public.routes.deleted_at is null or excluded.deleted_at is not null)
    and (excluded.updated_at > public.routes.updated_at or
      (excluded.updated_at = public.routes.updated_at
       and public.routes.deleted_at is null and excluded.deleted_at is not null))
  returning * into winner;
  accepted := found;
  if not accepted then
    select * into strict winner from public.routes
      where id = (p_route->>'id')::uuid and user_id = auth.uid();
  end if;
  return jsonb_build_object('accepted', accepted, 'row',
    to_jsonb(winner) || jsonb_build_object('route_geometry',
      case when winner.route_geometry is null then null
      else extensions.st_asgeojson(winner.route_geometry)::jsonb end));
end;
$$;

comment on function public.push_route_v2(jsonb) is
  'Idempotent upsert of one saved route for the calling user.';

-- Old applications cannot inspect a winner response. In particular they
-- delete the shared original.gpx immediately after a successful delete RPC.
-- A losing legacy delete MUST throw and roll back, not silently succeed.
create or replace function public.push_ride(p_ride jsonb)
returns void language plpgsql security invoker
set search_path = public, extensions, pg_temp
as $$
declare
  result jsonb := public.push_ride_v2(p_ride);
  winner jsonb := result->'row';
  replay boolean;
begin
  if (result->>'accepted')::boolean or
    (nullif(p_ride->>'deleted_at', '') is not null and winner->>'deleted_at' is not null) then
    return;
  end if;
  -- Compare the complete effective payload, with exactly the same casts and
  -- null-coalesce semantics as the upsert. Equal clocks alone are not a retry.
  replay := winner @> jsonb_build_object(
      'name', nullif(p_ride->>'name', ''),
      'notes', nullif(p_ride->>'notes', ''),
      'started_at', (p_ride->>'started_at')::timestamptz,
      'ended_at', nullif(p_ride->>'ended_at', '')::timestamptz,
      'elapsed_seconds', coalesce((p_ride->>'elapsed_seconds')::integer, 0),
      'moving_seconds', coalesce((p_ride->>'moving_seconds')::integer, 0),
      'distance_meters', coalesce((p_ride->>'distance_meters')::double precision, 0),
      'avg_speed_mps', nullif(p_ride->>'avg_speed_mps', '')::double precision,
      'max_speed_mps', nullif(p_ride->>'max_speed_mps', '')::double precision,
      'elevation_gain_meters', nullif(p_ride->>'elevation_gain_meters', '')::double precision,
      'elevation_loss_meters', nullif(p_ride->>'elevation_loss_meters', '')::double precision,
      'start_lat', nullif(p_ride->>'start_lat', '')::double precision,
      'start_lng', nullif(p_ride->>'start_lng', '')::double precision,
      'end_lat', nullif(p_ride->>'end_lat', '')::double precision,
      'end_lng', nullif(p_ride->>'end_lng', '')::double precision,
      'gpx_path', coalesce(nullif(p_ride->>'gpx_path', ''), winner->>'gpx_path'),
      'fit_path', coalesce(nullif(p_ride->>'fit_path', ''), winner->>'fit_path'),
      'sync_version', greatest(coalesce((p_ride->>'sync_version')::bigint, 1), (winner->>'sync_version')::bigint),
      'deleted_at', nullif(p_ride->>'deleted_at', '')::timestamptz,
      'updated_at', (p_ride->>'updated_at')::timestamptz)
    and (jsonb_typeof(p_ride->'route_geometry') is distinct from 'object'
      or extensions.st_asgeojson(extensions.st_setsrid(
        extensions.st_geomfromgeojson(p_ride->'route_geometry'), 4326))::jsonb
        = winner->'route_geometry');
  if not (result->>'accepted')::boolean and not coalesce(replay, false)
    and not (nullif(p_ride->>'deleted_at', '') is not null and winner->>'deleted_at' is not null) then
    raise exception 'Newer cloud ride or tombstone exists; pull before retrying'
      using errcode = '40001';
  end if;
end;
$$;

create or replace function public.push_route(p_route jsonb)
returns void language plpgsql security invoker
set search_path = public, extensions, pg_temp
as $$
declare
  result jsonb := public.push_route_v2(p_route);
  winner jsonb := result->'row';
  replay boolean;
begin
  if (result->>'accepted')::boolean or
    (nullif(p_route->>'deleted_at', '') is not null and winner->>'deleted_at' is not null) then
    return;
  end if;
  -- Compare the complete effective payload, with exactly the same casts and
  -- null-coalesce semantics as the upsert. Equal clocks alone are not a retry.
  replay := winner @> jsonb_build_object(
      'name', coalesce(nullif(p_route->>'name', ''), '路线'),
      'distance_meters', nullif(p_route->>'distance_meters', '')::double precision,
      'estimated_seconds', nullif(p_route->>'estimated_seconds', '')::integer,
      'elevation_gain_meters', nullif(p_route->>'elevation_gain_meters', '')::double precision,
      'provider', nullif(p_route->>'provider', ''),
      'provider_route_id', nullif(p_route->>'provider_route_id', ''),
      'deleted_at', nullif(p_route->>'deleted_at', '')::timestamptz,
      'updated_at', (p_route->>'updated_at')::timestamptz)
    and (jsonb_typeof(p_route->'route_geometry') is distinct from 'object'
      or extensions.st_asgeojson(extensions.st_setsrid(
        extensions.st_geomfromgeojson(p_route->'route_geometry'), 4326))::jsonb
        = winner->'route_geometry');
  if not (result->>'accepted')::boolean and not coalesce(replay, false)
    and not (nullif(p_route->>'deleted_at', '') is not null and winner->>'deleted_at' is not null) then
    raise exception 'Newer cloud route or tombstone exists; pull before retrying'
      using errcode = '40001';
  end if;
end;
$$;

-- Functions default to EXECUTE for PUBLIC. All four remain invoker-only,
-- authenticated APIs with the same ownership/account RLS boundary.
revoke all on function public.push_ride(jsonb) from public, anon;
revoke all on function public.push_route(jsonb) from public, anon;
revoke all on function public.push_ride_v2(jsonb) from public, anon;
revoke all on function public.push_route_v2(jsonb) from public, anon;
grant execute on function public.push_ride(jsonb) to authenticated;
grant execute on function public.push_route(jsonb) to authenticated;
grant execute on function public.push_ride_v2(jsonb) to authenticated;
grant execute on function public.push_route_v2(jsonb) to authenticated;
