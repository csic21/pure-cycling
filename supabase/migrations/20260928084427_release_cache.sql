-- Shared Release cache and refresh lease. Edge Function isolates are short lived
-- and run in parallel, so process memory cannot enforce a GitHub call budget.
-- Only the service role may use this table or its RPCs.
create table public.release_cache (
  repository text primary key,
  status integer,
  body text,
  fetched_at timestamptz,
  expires_at timestamptz,
  lease_id uuid,
  lease_until timestamptz,
  retry_after timestamptz,
  constraint release_cache_status check (status is null or status in (200, 404)),
  constraint release_cache_body check (
    (status = 200 and body is not null) or
    (status = 404 and body is null) or
    (status is null and body is null)
  )
);

alter table public.release_cache enable row level security;
revoke all on table public.release_cache from public, anon, authenticated;
grant select, insert, update on table public.release_cache to service_role;

-- Row locks make the decision atomic across all regions and isolates. A lease
-- expires if a worker dies during the GitHub request; an existing good body is
-- served while a refresh is underway or GitHub is temporarily unavailable.
create function public.claim_release_cache(p_repository text, p_lease_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_row public.release_cache%rowtype;
  v_now timestamptz := now();
begin
  if p_repository is null or
     p_repository !~ '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$' or
     split_part(p_repository, '/', 2) in ('.', '..') or p_lease_id is null then
    raise exception 'invalid release cache key';
  end if;

  insert into public.release_cache (repository) values (p_repository)
    on conflict (repository) do nothing;
  select * into v_row from public.release_cache
    where repository = p_repository for update;

  if v_row.expires_at > v_now then
    if v_row.status = 200 then
      return jsonb_build_object('state', 'fresh', 'body', v_row.body,
        'fetched_at', v_row.fetched_at);
    end if;
    return jsonb_build_object('state', 'missing');
  end if;

  if v_row.lease_until > v_now then
    if v_row.status = 200 and v_row.fetched_at > v_now - interval '1 day' then
      return jsonb_build_object('state', 'stale', 'body', v_row.body,
        'fetched_at', v_row.fetched_at);
    end if;
    return jsonb_build_object('state', 'wait');
  end if;

  if v_row.retry_after > v_now then
    if v_row.status = 200 and v_row.fetched_at > v_now - interval '1 day' then
      return jsonb_build_object('state', 'stale', 'body', v_row.body,
        'fetched_at', v_row.fetched_at);
    end if;
    return jsonb_build_object('state', 'unavailable');
  end if;

  update public.release_cache
    set lease_id = p_lease_id, lease_until = v_now + interval '15 seconds'
    where repository = p_repository;
  return jsonb_build_object('state', 'refresh', 'body',
    case when v_row.status = 200 and v_row.fetched_at > v_now - interval '1 day'
      then v_row.body else null end,
    'fetched_at', v_row.fetched_at);
end;
$$;

create function public.finish_release_cache(
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
          then interval '10 minutes' else interval '30 seconds' end,
        lease_id = null,
        lease_until = null,
        retry_after = null
    where repository = p_repository and lease_id = p_lease_id
      and lease_until > now();
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$$;

create function public.fail_release_cache(p_repository text, p_lease_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_updated integer;
begin
  update public.release_cache
    set lease_id = null,
        lease_until = null,
        retry_after = now() + interval '30 seconds'
    where repository = p_repository and lease_id = p_lease_id;
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$$;

revoke all on function public.claim_release_cache(text, uuid) from public, anon, authenticated;
revoke all on function public.finish_release_cache(text, uuid, integer, text) from public, anon, authenticated;
revoke all on function public.fail_release_cache(text, uuid) from public, anon, authenticated;
grant execute on function public.claim_release_cache(text, uuid) to service_role;
grant execute on function public.finish_release_cache(text, uuid, integer, text) to service_role;
grant execute on function public.fail_release_cache(text, uuid) to service_role;
