-- Disposable synthetic records only; scripts/verify-migrations.sh rolls back.
begin;
insert into auth.users (id, email) values
 ('a1234567-1234-4234-8234-123456789abc', 'tombstone@example.invalid');
set local role authenticated;
set local request.jwt.claim.sub = 'a1234567-1234-4234-8234-123456789abc';
do $$
declare
 p jsonb := '{"id":"b1234567-1234-4234-8234-123456789abc","started_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T01:00:00Z","name":"private","notes":"private notes","start_lat":31,"start_lng":121,"end_lat":32,"end_lng":122,"route_geometry":{"type":"LineString","coordinates":[[121,31],[122,32]]}}';
 r jsonb;
begin
 r := public.push_ride_v2(p);
 r := public.push_ride_v2((p - 'route_geometry') || '{"updated_at":"2026-01-01T02:00:00Z"}');
 if r->'row'->>'route_geometry' is null then raise exception 'omitted geometry erased live line'; end if;
 r := public.push_ride_v2(p || '{"route_geometry":null,"updated_at":"2026-01-01T03:00:00Z"}');
 if r->'row'->>'route_geometry' is not null then raise exception 'explicit null retained geometry'; end if;
 r := public.push_ride_v2(p || '{"updated_at":"2026-01-01T04:00:00Z"}');
 r := public.push_ride_v2(p || '{"updated_at":"2026-01-01T05:00:00Z","deleted_at":"2026-01-01T05:00:00Z"}');
 if exists (select 1 from public.rides where id = (p->>'id')::uuid and
   (route_geometry is not null or start_lat is not null or start_lng is not null
    or end_lat is not null or end_lng is not null or name is not null
    or notes is not null or fit_path is not null)) then
   raise exception 'tombstone retained precise location or description';
 end if;
 r := public.push_ride_v2(p || '{"updated_at":"2099-01-01T00:00:00Z"}');
 if r->>'accepted' <> 'false' or r->'row'->>'deleted_at' is null then
   raise exception 'old device resurrected scrubbed tombstone';
 end if;
end $$;
rollback;
