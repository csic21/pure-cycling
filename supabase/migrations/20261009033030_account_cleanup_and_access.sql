-- Account state is authoritative on every Data/Storage request. A still-valid
-- JWT must not keep working after a ban, cleanup fence, or account deletion.
create schema if not exists cycling_private;
revoke all on schema cycling_private from public, anon;
grant usage on schema cycling_private to authenticated;

create table cycling_private.account_access (
  user_id uuid primary key references auth.users(id) on delete cascade,
  disabled boolean not null default false,
  storage_epoch uuid not null default gen_random_uuid(),
  cleanup_mode text check (cleanup_mode in ('wipe', 'delete')),
  cleanup_token uuid,
  cleanup_lease_until timestamptz,
  check ((cleanup_token is null) = (cleanup_lease_until is null)),
  check (cleanup_mode is not null or cleanup_token is null)
);
alter table cycling_private.account_access enable row level security;
revoke all on cycling_private.account_access from public, anon, authenticated;

-- Existing Auth bans are checked live below. Never derive access from old
-- audit rows or freeze a historical ban/unban into the new application fence.
insert into cycling_private.account_access (user_id) select id from auth.users;

create function cycling_private.bootstrap_account_access()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into cycling_private.account_access(user_id) values (new.id);
  return new;
end;
$$;
revoke all on function cycling_private.bootstrap_account_access() from public, anon, authenticated;
create trigger a_bootstrap_account_access after insert on auth.users
for each row execute function cycling_private.bootstrap_account_access();

-- VOLATILE + a row lock are intentional. Cleanup obtains FOR UPDATE on the
-- same row, so it waits for any already-authorized write to commit. A write
-- that was waiting for cleanup sees the new state before it can proceed.
-- Storage finalization can bypass RLS. The separate epoch trigger below
-- guards that privileged write too, including after a wipe has reopened.
create function cycling_private.account_is_active()
returns boolean language plpgsql volatile security definer set search_path = '' as $$
declare v_access cycling_private.account_access; v_banned_until timestamptz;
begin
  if auth.uid() is null then return false; end if;
  select * into v_access from cycling_private.account_access
    where user_id = auth.uid() for share;
  if not found or v_access.disabled or v_access.cleanup_mode is not null then
    return false;
  end if;
  -- The base test image predates GoTrue's banned_until migration. JSON reads
  -- the real column when present and safely yields NULL before it is added.
  select (to_jsonb(u)->>'banned_until')::timestamptz into v_banned_until
    from auth.users u where u.id = auth.uid();
  return found and (v_banned_until is null or v_banned_until <= now());
end;
$$;
revoke all on function cycling_private.account_is_active() from public, anon;
grant execute on function cycling_private.account_is_active() to authenticated;

-- Restrictive policies AND with the existing owner policies. In particular,
-- an administrator still has no access to another user's ride/route/GPX data.
do $$
declare v_table text;
begin
  foreach v_table in array array['profiles','rides','routes','bikes','user_settings'] loop
    execute format('create policy "Account must be active" on public.%I as restrictive for all to authenticated using ((select cycling_private.account_is_active())) with check ((select cycling_private.account_is_active()))', v_table);
  end loop;
end;
$$;
create policy "Ride storage account must be active" on storage.objects
as restrictive for all to authenticated
using (bucket_id <> 'rides' or (select cycling_private.account_is_active()))
with check (bucket_id <> 'rides' or (select cycling_private.account_is_active()));

-- Hard cloud wipes must use the fenced service cleanup. Ordinary ride/route
-- deletion is a tombstone RPC. Old clients must fail visibly rather than
-- report a successful unfenced, row-index-only wipe that leaves orphans.
revoke delete on public.rides, public.routes from authenticated, anon;

-- A read-only reservation: every upload attempt gets an immutable name bearing
-- the current account epoch. Cleanup changes that epoch before enumerating.
create function public.new_gpx_upload_path(p_ride_id uuid, p_attempt_id uuid)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare v_epoch uuid;
begin
  if p_ride_id is null or p_attempt_id is null or not cycling_private.account_is_active() then
    raise exception 'account cannot upload' using errcode = '42501';
  end if;
  select storage_epoch into v_epoch from cycling_private.account_access where user_id = auth.uid();
  return 'rides/' || auth.uid()::text || '/' || p_ride_id::text || '/' ||
    v_epoch::text || '/' || p_attempt_id::text || '.gpx';
end;
$$;
revoke all on function public.new_gpx_upload_path(uuid, uuid) from public, anon;
grant execute on function public.new_gpx_upload_path(uuid, uuid) to authenticated;

-- Compatibility exception to treating the managed Storage schema as read-only:
-- this trigger does not edit/delete metadata. It rejects unsafe finalization.
-- Storage checks RLS before streaming bytes, then completes with a superuser;
-- RLS alone cannot stop a pre-cleanup upload finishing after cleanup/reopen.
-- Its uploader catches this rejection and schedules deletion of that version's
-- underlying bytes. Verify the pinned Storage version on every platform upgrade.
create function cycling_private.guard_ride_object_finalization()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_parts text[];
  v_user uuid;
  v_access cycling_private.account_access;
  v_banned_until timestamptz;
  v_uuid constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
begin
  if new.bucket_id <> 'rides' then return new; end if;
  v_parts := string_to_array(new.name, '/');
  if v_parts[1] <> 'rides' or v_parts[2] is null or v_parts[2] !~ v_uuid then
    raise exception 'invalid ride object owner' using errcode = '42501';
  end if;
  v_user := v_parts[2]::uuid;
  select * into v_access from cycling_private.account_access where user_id = v_user for share;
  if not found or v_access.disabled or v_access.cleanup_mode is not null then
    raise exception 'account cannot finalize upload' using errcode = '42501';
  end if;
  select (to_jsonb(u)->>'banned_until')::timestamptz into v_banned_until
    from auth.users u where u.id = v_user;
  if not found or v_banned_until > now() then
    raise exception 'account cannot finalize upload' using errcode = '42501';
  end if;
  -- Original shared names from older app versions remain readable/deletable,
  -- but new writes require an epoch-bearing immutable name.
  if array_length(v_parts, 1) <> 5 or v_parts[3] !~ v_uuid
    or v_parts[4] is distinct from v_access.storage_epoch::text
    or v_parts[5] !~ ('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.gpx$') then
    raise exception 'upload epoch expired; update the app and retry' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' then
    raise exception 'ride objects are immutable; upload a new attempt' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function cycling_private.guard_ride_object_finalization() from public, anon, authenticated;
create trigger guard_ride_object_finalization before insert or update on storage.objects
for each row execute function cycling_private.guard_ride_object_finalization();

create or replace function public.is_admin()
returns boolean language sql volatile security definer set search_path = '' as $$
  select cycling_private.account_is_active() and exists (
    select 1 from public.admins where user_id = (select auth.uid())
  );
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- The state change and its audit record commit together. GoTrue's ban is an
-- additional server action; if it fails, this fence still fails closed.
create function public.admin_set_account_disabled(p_user_id uuid, p_disabled boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() or p_user_id = auth.uid()
     or exists (select 1 from public.admins where user_id = p_user_id) then
    raise exception 'cannot change this account' using errcode = '42501';
  end if;
  if p_disabled is null then raise exception 'disabled must be supplied'; end if;
  update cycling_private.account_access set disabled = p_disabled where user_id = p_user_id;
  if not found then raise exception 'account not found' using errcode = 'P0002'; end if;
  insert into public.admin_audit(admin_id, action, target_user_id)
    values (auth.uid(), case when p_disabled then 'disable_user' else 'enable_user' end, p_user_id);
end;
$$;
revoke all on function public.admin_set_account_disabled(uuid, boolean) from public, anon;
grant execute on function public.admin_set_account_disabled(uuid, boolean) to authenticated;

-- Only trusted server code can start/drain/complete cleanup. It supplies the
-- verified actor, never an ID read from a request body. A crashed worker leaves
-- the fence in place; after its lease expires a retry may take ownership.
create function public.begin_account_cleanup(
  p_user_id uuid, p_actor_id uuid, p_mode text, p_token uuid
) returns void language plpgsql security definer set search_path = '' as $$
declare v_access cycling_private.account_access;
begin
  if p_mode not in ('wipe','delete') or p_mode is null or p_token is null then
    raise exception 'invalid cleanup request';
  end if;
  if p_actor_id is null or (p_actor_id <> p_user_id and (
    not exists (select 1 from public.admins where user_id = p_actor_id)
    or not exists (select 1 from cycling_private.account_access a
      join auth.users u on u.id = a.user_id
      where a.user_id = p_actor_id and not a.disabled and a.cleanup_mode is null
        and ((to_jsonb(u)->>'banned_until')::timestamptz is null
          or (to_jsonb(u)->>'banned_until')::timestamptz <= now()))
    or exists (select 1 from public.admins where user_id = p_user_id)
  )) then raise exception 'invalid cleanup actor' using errcode = '42501'; end if;
  select * into v_access from cycling_private.account_access where user_id = p_user_id for update;
  if not found then raise exception 'account not found' using errcode = 'P0002'; end if;
  if v_access.cleanup_token is not null and v_access.cleanup_token <> p_token
     and v_access.cleanup_lease_until > now() then
    raise exception 'cleanup already running' using errcode = '55P03';
  end if;
  -- A partial account deletion can be retried as deletion, never reopened by
  -- a wipe request. A failed wipe can still be escalated to account deletion.
  if v_access.cleanup_mode = 'delete' and p_mode <> 'delete' then
    raise exception 'account deletion is pending' using errcode = '55P03';
  end if;
  update cycling_private.account_access set cleanup_mode = p_mode,
    storage_epoch = gen_random_uuid(),
    cleanup_token = p_token, cleanup_lease_until = now() + interval '15 minutes'
    where user_id = p_user_id;
end;
$$;

create function public.list_account_cleanup_objects(p_user_id uuid, p_token uuid)
returns table(name text) language plpgsql security definer set search_path = '' as $$
begin
  update cycling_private.account_access set cleanup_lease_until = now() + interval '15 minutes'
    where user_id = p_user_id and cleanup_token = p_token;
  if not found then raise exception 'cleanup ownership lost' using errcode = '55P03'; end if;
  -- Page-draining: always return the first page. Removing a page before asking
  -- for an offset would skip rows. Storage metadata is the authoritative index,
  -- including failed push_ride uploads, versioned GPX, FIT and nested objects.
  return query select o.name from storage.objects o
    where o.bucket_id = 'rides'
      and starts_with(o.name, 'rides/' || p_user_id::text || '/')
    order by o.name collate "C" limit 500;
end;
$$;

create function public.finish_account_cleanup(p_user_id uuid, p_token uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_mode text;
begin
  select cleanup_mode into v_mode from cycling_private.account_access
    where user_id = p_user_id and cleanup_token = p_token for update;
  if not found then raise exception 'cleanup ownership lost' using errcode = '55P03'; end if;
  if exists (select 1 from storage.objects where bucket_id = 'rides'
    and starts_with(name, 'rides/' || p_user_id::text || '/')) then
    raise exception 'storage cleanup incomplete';
  end if;
  if v_mode = 'wipe' then
    delete from public.rides where user_id = p_user_id;
    delete from public.routes where user_id = p_user_id;
    delete from public.bikes where user_id = p_user_id;
    delete from public.user_settings where user_id = p_user_id;
    update cycling_private.account_access set cleanup_mode = null,
      cleanup_token = null, cleanup_lease_until = null where user_id = p_user_id;
  else
    -- Keep the fence until GoTrue deletes auth.users (and cascades this row).
    update cycling_private.account_access set cleanup_lease_until = now() + interval '15 minutes'
      where user_id = p_user_id;
  end if;
end;
$$;

create function public.release_account_cleanup(p_user_id uuid, p_token uuid)
returns void language sql security definer set search_path = '' as $$
  update cycling_private.account_access set cleanup_token = null, cleanup_lease_until = null
    where user_id = p_user_id and cleanup_token = p_token;
$$;

revoke all on function public.begin_account_cleanup(uuid, uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.list_account_cleanup_objects(uuid, uuid) from public, anon, authenticated;
revoke all on function public.finish_account_cleanup(uuid, uuid) from public, anon, authenticated;
revoke all on function public.release_account_cleanup(uuid, uuid) from public, anon, authenticated;
grant execute on function public.begin_account_cleanup(uuid, uuid, text, uuid) to service_role;
grant execute on function public.list_account_cleanup_objects(uuid, uuid) to service_role;
grant execute on function public.finish_account_cleanup(uuid, uuid) to service_role;
grant execute on function public.release_account_cleanup(uuid, uuid) to service_role;

-- An exact lookup, independent of list pagination. Only metadata is returned.
create function public.admin_get_user(p_user_id uuid)
returns table(id uuid, email text, created_at timestamptz, ride_count bigint,
  route_count bigint, is_admin boolean, access_state text)
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not public.is_admin() then
    raise exception 'admin_get_user requires an admin account' using errcode = '42501';
  end if;
  return query select u.id, u.email::text, u.created_at,
    (select count(*) from public.rides r where r.user_id = u.id and r.deleted_at is null),
    (select count(*) from public.routes r where r.user_id = u.id and r.deleted_at is null),
    exists (select 1 from public.admins a where a.user_id = u.id),
    case when a.cleanup_mode is not null then a.cleanup_mode
      when a.disabled or (to_jsonb(u)->>'banned_until')::timestamptz > now()
      then 'disabled' else 'active' end
  from auth.users u join cycling_private.account_access a on a.user_id = u.id where u.id = p_user_id;
end;
$$;
revoke all on function public.admin_get_user(uuid) from public, anon;
grant execute on function public.admin_get_user(uuid) to authenticated;

-- List badges reflect authoritative state, including partial cleanup.
create or replace function public.admin_list_users(
  p_search text default null,
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
  access_state text,
  total bigint
)
language plpgsql
volatile
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
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
      case when state.cleanup_mode is not null then state.cleanup_mode
        when state.disabled or (to_jsonb(u)->>'banned_until')::timestamptz > now()
        then 'disabled' else 'active' end::text,
      -- Window function, so it is computed after the filter and before the
      -- limit: the total of what matches, not of what fits on this page.
      count(*) over () as total
    from auth.users u
    join cycling_private.account_access state on state.user_id = u.id
    where v_search is null
       or position(lower(v_search) in lower(coalesce(u.email, ''))) > 0
    order by u.created_at desc, u.id
    limit least(greatest(p_limit, 1), 200)
    offset greatest(p_offset, 0);
end;
$$;

comment on function public.admin_list_users(text, integer, integer) is
  'Account metadata for the admin console, filtered by email substring and '
  'paged. Refuses non-admins; returns no ride content.';

revoke all on function public.admin_list_users(text, integer, integer)
  from public, anon;
grant execute on function public.admin_list_users(text, integer, integer)
  to authenticated;
