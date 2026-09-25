-- A per-account quota for server-side helpers (the routing relay).
--
-- Edge functions run with the service role, so RLS is not available to them
-- as a guard. The guard has to be a counter they consume before doing work.
-- It lives in Postgres rather than in memory because an edge function is a
-- fleet, not a process: an in-memory counter resets on every cold start and
-- multiplies with every instance.
--
-- Nothing here is exposed to the Data API. The table has no grants and the
-- consuming function is service_role-only.

create table if not exists public.rate_limits (
  user_id uuid not null,
  bucket text not null,
  window_start timestamptz not null default now(),
  count integer not null default 0,
  primary key (user_id, bucket)
);

alter table public.rate_limits enable row level security;

-- Supabase's image grants `all` on new public tables to anon/authenticated by
-- default, so "no access" has to be written explicitly.
revoke all on table public.rate_limits from anon, authenticated;

create or replace function public.consume_rate_limit(
  p_user_id uuid,
  p_bucket text,
  p_limit integer,
  p_window_seconds integer
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.rate_limits;
  v_now timestamptz := now();
begin
  if p_user_id is null or p_limit <= 0 or p_window_seconds <= 0 then
    return false;
  end if;

  -- One statement, so two concurrent calls cannot both read "under the limit"
  -- and then both write. The window is fixed rather than sliding: simpler, and
  -- for a daily quota the difference is one burst at the boundary.
  insert into public.rate_limits as r (user_id, bucket, window_start, count)
  values (p_user_id, p_bucket, v_now, 1)
  on conflict (user_id, bucket) do update
    set count = case
          when r.window_start < v_now - make_interval(secs => p_window_seconds)
            then 1
          else r.count + 1
        end,
        window_start = case
          when r.window_start < v_now - make_interval(secs => p_window_seconds)
            then v_now
          else r.window_start
        end
  returning * into v_row;

  return v_row.count <= p_limit;
end;
$$;

comment on function public.consume_rate_limit(uuid, text, integer, integer) is
  'Consumes one unit of a per-account quota. False means exhausted. Service role only.';

revoke all on function public.consume_rate_limit(uuid, text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.consume_rate_limit(uuid, text, integer, integer)
  to service_role;
