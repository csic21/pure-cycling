-- Prospective only: this migration does NOT purge existing tombstones or
-- Storage objects. Historical data cleanup requires a separately approved run.
-- Existing RLS, invoker rights, conflict arbitration and account fences remain.
-- Atomically choose the winning edit before any column can be overwritten.
-- Structured v2 RPCs return winners; legacy void RPCs reject losing writes
-- rather than letting old clients delete the live winner's GPX after a no-op.
create or replace function public.push_ride_v2(p_ride jsonb)
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
  -- Deletes clear precise coordinates and free text while retaining activity
  -- metrics, timestamps and the opaque GPX cleanup pointer, even when
  -- an older client sends its complete former ride as the delete payload.
  if nullif(p_ride->>'deleted_at', '') is not null then
    p_ride := p_ride || jsonb_build_object(
      'name', null, 'notes', null, 'fit_path', null,
      'start_lat', null, 'start_lng', null, 'end_lat', null, 'end_lng', null,
      'route_geometry', null);
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
    -- Absence means unchanged; explicit JSON null clears a line. A tombstone
    -- always clears, including legacy clients that omitted this key.
    route_geometry         = case when excluded.deleted_at is not null
                               or p_ride ? 'route_geometry'
                             then excluded.route_geometry
                             else rides.route_geometry end,
    gpx_path               = coalesce(excluded.gpx_path, rides.gpx_path),
    fit_path               = case when excluded.deleted_at is not null then null
                             else coalesce(excluded.fit_path, rides.fit_path) end,
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

