-- Admin access: who may read account metadata, and the audit trail for
-- privileged actions.
--
-- ## What an admin is — and what an admin is not
--
-- The product promise is that rides are private (spec §44). An operator needs
-- to answer "which accounts exist", "is this account abusing the free tier",
-- "disable this account" — none of which require reading a location trace.
-- Admin access is therefore granted on *account metadata* and deliberately not
-- on `rides`, `routes`, `bikes`, `user_settings` or the storage bucket.
-- `scripts/verify-migrations.sh` asserts exactly that, because a policy added
-- "just in case" is how a privacy promise quietly stops being true.
--
-- ## Why membership is a table and not a Postgres role
--
-- A row can be granted and revoked without a migration, survives restores, and
-- makes `is_admin()` testable in the same harness as every other policy. The
-- table itself has no Data API grants at all: membership is changed with the
-- service role, so a stolen admin session cannot mint more admins.

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  note text,
  created_at timestamptz not null default now()
);

alter table public.admins enable row level security;

-- Supabase's images set `alter default privileges ... grant all on tables to
-- anon, authenticated` for the public schema, so a new table is reachable
-- through the Data API even when the migration grants nothing. "No grant" has
-- to be written explicitly, or the membership table is listable with the anon
-- key. (The verification harness asserts this, which is how it was caught.)
revoke all on table public.admins from anon, authenticated;

comment on table public.admins is
  'Accounts allowed to use the admin console. Managed with the service role; '
  'not reachable through the Data API.';

-- SECURITY DEFINER so a policy can read the membership table even though the
-- calling role cannot. The search path is pinned so a schema earlier in the
-- caller's path cannot shadow `public.admins` or `auth.uid()`.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.admins where user_id = (select auth.uid())
  );
$$;

comment on function public.is_admin() is
  'True when the calling user is listed in public.admins. Used by RLS policies.';

revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- ---------------------------------------------------------------------------
-- The account list, for the console
--
-- Emails live in `auth.users`, which is not exposed through the Data API, so
-- the list is an RPC rather than a table read. It is `security definer`
-- because reading `auth.users` requires it — and it refuses anyone who is not
-- an admin *inside the function*, so the grant to `authenticated` is not a
-- grant to everyone.
--
-- Deliberately absent from the result: ride traces, GPX paths, sensor data.
-- Counts are here because "how many rides has this account synced" is an
-- operational question; where those rides went is not.
-- ---------------------------------------------------------------------------

-- `create or replace` cannot change a function's return type, and this result
-- gained a column while the migration was being written. The drop makes the
-- file re-runnable against a database that already has the earlier shape.
drop function if exists public.admin_list_users(integer, integer);

create or replace function public.admin_list_users(
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid,
  email text,
  email_confirmed boolean,
  created_at timestamptz,
  last_sign_in_at timestamptz,
  ride_count bigint,
  route_count bigint,
  is_admin boolean,
  access_state text
)
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'admin_list_users requires an admin account'
      using errcode = 'insufficient_privilege';
  end if;

  return query
    select
      u.id,
      u.email::text,
      -- `confirmed_at`, not `email_confirmed_at`: the latter is added by
      -- GoTrue's own migrations and does not exist in the bare Postgres image
      -- the verification harness runs against. `confirmed_at` exists in both
      -- (as a plain column on one, a generated column on the other).
      u.confirmed_at is not null,
      u.created_at,
      u.last_sign_in_at,
      (select count(*) from public.rides r
        where r.user_id = u.id and r.deleted_at is null),
      (select count(*) from public.routes rt
        where rt.user_id = u.id and rt.deleted_at is null),
      exists (select 1 from public.admins a where a.user_id = u.id),
      -- Derived from this console's own audit trail rather than from GoTrue's
      -- `banned_until`: that column is added by the auth service and does not
      -- exist in the bare image the verification harness runs against. The
      -- trade-off is that a ban applied elsewhere (Studio, SQL) is not
      -- visible here.
      coalesce((
        select case when a.action = 'disable_user' then 'disabled' else 'active' end
        from public.admin_audit a
        where a.target_user_id = u.id
          and a.action in ('disable_user', 'enable_user')
        order by a.created_at desc, a.id desc
        limit 1
      ), 'active')::text
    from auth.users u
    order by u.created_at desc
    limit least(greatest(p_limit, 1), 200)
    offset greatest(p_offset, 0);
end;
$$;

comment on function public.admin_list_users(integer, integer) is
  'Account metadata for the admin console. Refuses non-admins; returns no ride content.';

revoke all on function public.admin_list_users(integer, integer) from public, anon;
grant execute on function public.admin_list_users(integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Audit trail
--
-- Written by the admin console's server routes with the service role, read by
-- admins through RLS. No foreign keys on purpose: the log has to survive the
-- deletion of either the admin who acted or the account that was acted on —
-- an audit row that disappears with its subject is not an audit row.
-- ---------------------------------------------------------------------------

create table if not exists public.admin_audit (
  id bigint generated always as identity primary key,
  admin_id uuid not null,
  action text not null,
  target_user_id uuid,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists admin_audit_created_idx
  on public.admin_audit (created_at desc);

create index if not exists admin_audit_target_idx
  on public.admin_audit (target_user_id);

alter table public.admin_audit enable row level security;

drop policy if exists "Admins can read the audit log" on public.admin_audit;
create policy "Admins can read the audit log"
on public.admin_audit
for select
to authenticated
using (public.is_admin());

-- SELECT only: rows are appended by the service role, never edited or removed
-- through the Data API. The revoke first, for the same default-privilege
-- reason as `admins` above.
revoke all on table public.admin_audit from anon, authenticated;
grant select on table public.admin_audit to authenticated;

-- ---------------------------------------------------------------------------
-- profiles: admins may read every account's profile row
--
-- The list RPC above covers the console's main screen. This policy exists so
-- a future detail view does not have to go through the service role just to
-- read a display name.
-- ---------------------------------------------------------------------------

drop policy if exists "Admins can read all profiles" on public.profiles;
create policy "Admins can read all profiles"
on public.profiles
for select
to authenticated
using (public.is_admin());
