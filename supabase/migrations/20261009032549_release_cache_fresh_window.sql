-- The release cache used to serve a freshly written body for ten minutes
-- without asking GitHub again. That window is measured from the moment of the
-- fetch, and the release pipeline fetches on purpose: `verify` runs
-- `scripts/check-release-service.sh` against the relay, and the `publish` job
-- does not create the GitHub Release until roughly ten minutes later. So every
-- release warmed the cache with the *previous* release and then hid the new one
-- for the rest of the window — riders were told the old version was current,
-- and downloaded the old APK under the old version number.
--
-- One minute turns that into something a rider is unlikely to hit and a
-- regenerated check clears, and `release.yml` now waits for the feed to report
-- the new tag before the publish job is allowed to finish.
--
-- The GitHub call budget is not the binding constraint: the relay sends a token
-- when it has one, the lease still collapses concurrent refreshes into a single
-- request, and a relay that does run out of anonymous quota falls back to the
-- website path rather than failing.
create or replace function public.finish_release_cache(
  p_repository text,
  p_lease_id uuid,
  p_status integer,
  p_body text
)
returns boolean
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_updated integer;
begin
  if p_status is null or p_status not in (200, 404) or
     (p_status = 200 and (p_body is null or octet_length(p_body) > 1048576)) or
     (p_status = 404 and p_body is not null) then
    raise exception 'invalid release cache response';
  end if;

  update public.release_cache
    set status = p_status,
        body = p_body,
        fetched_at = now(),
        expires_at = now() + case when p_status = 200
          then interval '1 minute' else interval '30 seconds' end,
        lease_id = null,
        lease_until = null,
        retry_after = null
    where repository = p_repository and lease_id = p_lease_id
      and lease_until > now();
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$$;
