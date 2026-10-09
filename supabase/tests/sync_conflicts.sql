-- Run after all real Supabase migrations (scripts/verify-migrations.sh).
-- Transactional fixtures never affect the rest of the migration harness.
begin;
insert into auth.users (id, email) values
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'sync-conflict-fixture@example.invalid');
set local role authenticated;
set local request.jwt.claim.sub = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

do $$
declare
  payload jsonb := jsonb_build_object(
    'id', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    'name', 'Winning ride', 'notes', 'new notes',
    'started_at', '2026-09-01T00:00:00Z',
    'updated_at', '2026-09-01T02:00:00Z',
    'distance_meters', 12000, 'elapsed_seconds', 3600,
    'gpx_path', 'rides/cccccccc-cccc-4ccc-8ccc-cccccccccccc/dddddddd-dddd-4ddd-8ddd-dddddddddddd/winner.gpx',
    'route_geometry', '{"type":"LineString","coordinates":[[121,31],[121.1,31.1]]}'::jsonb);
  response jsonb;
  winner jsonb;
begin
  payload := payload || jsonb_build_object('gpx_path', public.new_gpx_upload_path(
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'ffffffff-ffff-4fff-8fff-ffffffffffff'));
  insert into storage.objects (bucket_id, name, owner)
    values ('rides', payload->>'gpx_path', auth.uid());
  response := public.push_ride_v2(payload);
  if response->>'accepted' <> 'true' then raise exception 'initial ride rejected'; end if;
  winner := response->'row';
  begin
    perform public.push_ride_v2(payload || jsonb_build_object('gpx_path',
      'rides/cccccccc-cccc-4ccc-8ccc-cccccccccccc/dddddddd-dddd-4ddd-8ddd-dddddddddddd/missing.gpx'));
    raise exception 'missing GPX reference reported success';
  exception when sqlstate 'PC001' then null;
  end;
  -- Legacy exact retries succeed, but a rejected stale delete must raise
  -- before an old client is allowed to remove the surviving GPX object.
  perform public.push_ride(payload);
  begin
    perform public.push_ride(payload || '{"max_speed_mps":99}'::jsonb);
    raise exception 'legacy equal-timestamp statistics conflict reported success';
  exception when serialization_failure then null;
  end;
  begin
    perform public.push_ride(payload || '{"route_geometry":{"type":"LineString","coordinates":[[122,32],[122.1,32.1]]}}'::jsonb);
    raise exception 'legacy equal-timestamp geometry conflict reported success';
  exception when serialization_failure then null;
  end;
  begin
    perform public.push_ride(payload || '{"deleted_at":"2026-09-01T01:00:00Z","updated_at":"2026-09-01T01:00:00Z"}'::jsonb);
    raise exception 'legacy stale delete reported success';
  exception when serialization_failure then null;
  end;
  response := public.push_ride_v2(payload || '{"name":"Stale ride","distance_meters":1,"updated_at":"2026-09-01T01:00:00Z"}'::jsonb);
  if response->>'accepted' <> 'false' or response->'row' <> winner then
    raise exception 'stale push changed ride, geometry, timestamp or GPX: %', response;
  end if;
  response := public.push_ride_v2(payload || '{"name":"Equal timestamp competitor"}'::jsonb);
  if response->>'accepted' <> 'false' or response->'row' <> winner then
    raise exception 'equal timestamp changed server winner: %', response;
  end if;
  response := public.push_ride_v2(payload);
  if response->'row' <> winner then raise exception 'retry was not idempotent'; end if;
  response := public.push_ride_v2(payload || '{"deleted_at":"2026-09-01T01:00:00Z","updated_at":"2026-09-01T01:00:00Z"}'::jsonb);
  if response->>'accepted' <> 'false' or response->'row' <> winner then
    raise exception 'older delete removed newer live ride';
  end if;
  response := public.push_ride_v2(payload || '{"name":"Newer ride","notes":null,"updated_at":"2026-09-01T03:00:00Z"}'::jsonb);
  if response->>'accepted' <> 'true' or response->'row'->>'name' <> 'Newer ride'
      or response->'row'->>'notes' is not null then raise exception 'newer edit/clear lost'; end if;
  payload := payload || '{"deleted_at":"2026-09-01T03:00:00Z","updated_at":"2026-09-01T03:00:00Z"}'::jsonb;
  response := public.push_ride_v2(payload);
  if response->>'accepted' <> 'true' or response->'row'->>'deleted_at' is null then
    raise exception 'delete did not win timestamp tie'; end if;
  winner := response->'row';
  response := public.push_ride_v2(payload || '{"deleted_at":null,"updated_at":"2099-01-01T00:00:00Z"}'::jsonb);
  if response->>'accepted' <> 'false' or response->'row' <> winner then
    raise exception 'live upload resurrected ride tombstone'; end if;
  response := public.push_ride_v2(payload);
  if response->'row' <> winner then raise exception 'tombstone retry changed winner'; end if;
  raise notice 'ride conflict, tie, clear, retry and sticky tombstone checks passed';
end $$;

do $$
declare
  payload jsonb := '{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","name":"Winning route","distance_meters":5000,"updated_at":"2026-09-01T02:00:00Z","route_geometry":{"type":"LineString","coordinates":[[121,31],[121.1,31.1]]}}'::jsonb;
  response jsonb;
  winner jsonb;
begin
  response := public.push_route_v2(payload);
  if response->>'accepted' <> 'true' then raise exception 'initial route rejected'; end if;
  winner := response->'row';
  perform public.push_route(payload);
  begin
    perform public.push_route(payload || '{"provider":"competing-provider"}'::jsonb);
    raise exception 'legacy equal-timestamp route provider conflict reported success';
  exception when serialization_failure then null;
  end;
  response := public.push_route_v2(payload || '{"name":"Stale route","distance_meters":1,"updated_at":"2026-09-01T01:00:00Z"}'::jsonb);
  if response->>'accepted' <> 'false' or response->'row' <> winner then raise exception 'stale route won'; end if;
  response := public.push_route_v2(payload || '{"name":"Equal timestamp competitor"}'::jsonb);
  if response->>'accepted' <> 'false' or response->'row' <> winner then raise exception 'equal route changed winner'; end if;
  response := public.push_route_v2(payload || '{"name":"Newest","updated_at":"2026-09-01T03:00:00Z"}'::jsonb);
  if response->>'accepted' <> 'true' or response->'row'->>'name' <> 'Newest' then raise exception 'new route edit lost'; end if;
  payload := payload || '{"deleted_at":"2026-09-01T03:00:00Z","updated_at":"2026-09-01T03:00:00Z"}'::jsonb;
  response := public.push_route_v2(payload);
  if response->>'accepted' <> 'true' then raise exception 'route delete tie lost'; end if;
  winner := response->'row';
  response := public.push_route_v2(payload || '{"deleted_at":null,"updated_at":"2099-01-01T00:00:00Z"}'::jsonb);
  if response->>'accepted' <> 'false' or response->'row' <> winner then raise exception 'route resurrected'; end if;
  response := public.push_route_v2(payload);
  if response->'row' <> winner then raise exception 'route delete retry changed winner'; end if;
  raise notice 'route conflict, tie, retry and sticky tombstone checks passed';
end $$;
rollback;
