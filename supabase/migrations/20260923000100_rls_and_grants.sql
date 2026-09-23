-- Row level security and Data API grants.
--
-- Two separate things have to be true before a client can touch a table:
--
--   1. The role needs a *grant* on the table.
--   2. A *policy* has to let the specific row through.
--
-- Since 2026 Supabase no longer assumes a table created in `public` is
-- automatically exposed through the Data API (spec §25). Relying on the old
-- default produces a table that works in the SQL editor and returns nothing
-- from the app, which is a confusing way to spend an afternoon. Both are set
-- explicitly below.

-- ---------------------------------------------------------------------------
-- Enable RLS on every user-owned table.
--
-- The `anon` role is granted nothing at all: location traces are among the
-- most sensitive data a phone holds, and there is no feature that needs an
-- unauthenticated read (spec §44).
-- ---------------------------------------------------------------------------

alter table public.profiles      enable row level security;
alter table public.rides         enable row level security;
alter table public.routes        enable row level security;
alter table public.bikes         enable row level security;
alter table public.user_settings enable row level security;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

grant select, insert, update, delete on table public.profiles      to authenticated;
grant select, insert, update, delete on table public.rides         to authenticated;
grant select, insert, update, delete on table public.routes        to authenticated;
grant select, insert, update, delete on table public.bikes         to authenticated;
grant select, insert, update, delete on table public.user_settings to authenticated;

-- The trigger that bootstraps a new account runs as the auth service, not as
-- the end user, so it needs its own path.
grant usage on schema public to anon, authenticated;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------

drop policy if exists "Users can read own profile" on public.profiles;
create policy "Users can read own profile"
on public.profiles
for select
to authenticated
using ((select auth.uid()) = id);

drop policy if exists "Users can insert own profile" on public.profiles;
create policy "Users can insert own profile"
on public.profiles
for insert
to authenticated
with check ((select auth.uid()) = id);

drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile"
on public.profiles
for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

drop policy if exists "Users can delete own profile" on public.profiles;
create policy "Users can delete own profile"
on public.profiles
for delete
to authenticated
using ((select auth.uid()) = id);

-- ---------------------------------------------------------------------------
-- rides (spec §25)
--
-- `(select auth.uid())` rather than a bare `auth.uid()`: wrapping the call in
-- a subquery lets the planner evaluate it once per statement instead of once
-- per row, which on a 10,000-row scan is the difference between fast and not.
-- ---------------------------------------------------------------------------

drop policy if exists "Users can read own rides" on public.rides;
create policy "Users can read own rides"
on public.rides
for select
to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists "Users can insert own rides" on public.rides;
create policy "Users can insert own rides"
on public.rides
for insert
to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists "Users can update own rides" on public.rides;
create policy "Users can update own rides"
on public.rides
for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists "Users can delete own rides" on public.rides;
create policy "Users can delete own rides"
on public.rides
for delete
to authenticated
using ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------------------
-- routes
-- ---------------------------------------------------------------------------

drop policy if exists "Users can read own routes" on public.routes;
create policy "Users can read own routes"
on public.routes
for select
to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists "Users can insert own routes" on public.routes;
create policy "Users can insert own routes"
on public.routes
for insert
to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists "Users can update own routes" on public.routes;
create policy "Users can update own routes"
on public.routes
for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists "Users can delete own routes" on public.routes;
create policy "Users can delete own routes"
on public.routes
for delete
to authenticated
using ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------------------
-- bikes
-- ---------------------------------------------------------------------------

drop policy if exists "Users can read own bikes" on public.bikes;
create policy "Users can read own bikes"
on public.bikes
for select
to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists "Users can insert own bikes" on public.bikes;
create policy "Users can insert own bikes"
on public.bikes
for insert
to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists "Users can update own bikes" on public.bikes;
create policy "Users can update own bikes"
on public.bikes
for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists "Users can delete own bikes" on public.bikes;
create policy "Users can delete own bikes"
on public.bikes
for delete
to authenticated
using ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------------------
-- user_settings
-- ---------------------------------------------------------------------------

drop policy if exists "Users can read own settings" on public.user_settings;
create policy "Users can read own settings"
on public.user_settings
for select
to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists "Users can insert own settings" on public.user_settings;
create policy "Users can insert own settings"
on public.user_settings
for insert
to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists "Users can update own settings" on public.user_settings;
create policy "Users can update own settings"
on public.user_settings
for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists "Users can delete own settings" on public.user_settings;
create policy "Users can delete own settings"
on public.user_settings
for delete
to authenticated
using ((select auth.uid()) = user_id);
