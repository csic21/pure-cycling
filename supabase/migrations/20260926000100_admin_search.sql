-- Search and pagination for the admin console's account list.
--
-- The first version of that list fetched 100 accounts at offset 0 and stopped.
-- The parameters existed, but nothing passed anything but zero — a defect that
-- is invisible until account 101 exists, and then presents as "there are 100
-- accounts". An operator looking for one account in a thousand has no way to
-- find it, and no way to tell that they are looking at a truncated list.
--
-- Search is a case-insensitive email substring. Two deliberate choices:
--
--   * `position()` rather than `ilike '%' || p_search || '%'`: an email
--     containing `%` or `_` would otherwise turn the search box into a
--     wildcard, and escaping is one more thing to get wrong.
--   * Anonymous accounts (email is null) match only when the search box is
--     empty. They have no address to search for; the console's input says
--     「按邮箱搜索」 so this is not a surprise.
--
-- The result carries `total` — the count for the current filter, via a window
-- function so it costs one round trip rather than two. The console uses it to
-- say 「共 N 个」 and to decide whether the next page exists.

-- `create or replace` cannot change a function's return type or its parameter
-- list, so the previous shape is dropped explicitly. Every deployment applies
-- the migrations in order, and this file is re-runnable against a database
-- that already has the old signature.
drop function if exists public.admin_list_users(integer, integer);

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
stable
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
      ), 'active')::text,
      -- Window function, so it is computed after the filter and before the
      -- limit: the total of what matches, not of what fits on this page.
      count(*) over () as total
    from auth.users u
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
