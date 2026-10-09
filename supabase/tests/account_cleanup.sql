-- Run after all migrations in the disposable real Supabase Postgres harness.
-- Roll back fixtures. Storage metadata below is test data only; production
-- cleanup must use the Storage API to remove the underlying object bytes.
begin;
insert into auth.users(id, email, created_at) values
  ('a1000000-0000-4000-8000-000000000001', 'cleanup-owner@example.test', '2020-01-01'),
  ('a1000000-0000-4000-8000-000000000002', 'cleanup-other@example.test', '2020-01-01'),
  ('a1000000-0000-4000-8000-000000000003', 'cleanup-admin@example.test', '2020-01-01');
insert into public.admins(user_id) values ('a1000000-0000-4000-8000-000000000003');
insert into public.rides(id, user_id, started_at) values
  ('b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', now()),
  ('b1000000-0000-4000-8000-000000000002', 'a1000000-0000-4000-8000-000000000002', now());
insert into storage.objects(bucket_id, name)
select 'rides', 'rides/' || user_id::text ||
  '/b1000000-0000-4000-8000-000000000088/' || storage_epoch::text ||
  '/c1000000-0000-4000-8000-000000000088.gpx'
from cycling_private.account_access where user_id in
  ('a1000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000002');
-- Save a pre-cleanup path as if an HTTP upload had been admitted but had not
-- yet finalized. Storage later writes this using its superuser connection.
select set_config('test.old_upload_path',
  'rides/' || user_id::text || '/b1000000-0000-4000-8000-000000000089/' ||
  storage_epoch::text || '/c1000000-0000-4000-8000-000000000089.gpx', true)
from cycling_private.account_access where user_id = 'a1000000-0000-4000-8000-000000000001';

set local role authenticated;
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000001';
do $$
begin
  if (select count(*) from public.rides) <> 1 or (select count(*) from storage.objects) <> 1 then
    raise exception 'active owner lost its own data or sees other account data';
  end if;
  begin
    delete from public.rides where user_id = auth.uid();
    raise exception 'legacy unfenced hard wipe was accepted';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.routes where user_id = auth.uid();
    raise exception 'legacy route hard wipe was accepted';
  exception when insufficient_privilege then null; end;
  begin
    perform public.admin_get_user('a1000000-0000-4000-8000-000000000002');
    raise exception 'non-admin exact lookup was allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform public.begin_account_cleanup(auth.uid(), auth.uid(), 'delete', gen_random_uuid());
    raise exception 'user could invoke service cleanup RPC';
  exception when insufficient_privilege then null; end;
  begin
    perform public.admin_set_account_disabled('a1000000-0000-4000-8000-000000000002', true);
    raise exception 'non-admin could ban someone';
  exception when insufficient_privilege then null; end;
end;
$$;

-- Existing owner JWT keeps the same sub throughout the ban/unban checks.
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000003';
select public.admin_set_account_disabled('a1000000-0000-4000-8000-000000000001', true);
do $$
begin
  if (select access_state from public.admin_get_user('a1000000-0000-4000-8000-000000000001')) <> 'disabled' then
    raise exception 'exact lookup does not show authoritative ban state';
  end if;
  begin
    perform public.admin_set_account_disabled(auth.uid(), true);
    raise exception 'admin could ban self';
  exception when insufficient_privilege then null; end;
  if exists (select 1 from public.rides) or exists (select 1 from storage.objects) then
    raise exception 'admin gained access to private ride/Storage data';
  end if;
end;
$$;
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000001';
do $$
begin
  if exists (select 1 from public.rides) or exists (select 1 from storage.objects)
     or exists (select 1 from public.profiles) or exists (select 1 from public.user_settings) then
    raise exception 'old JWT still reads data after authoritative ban';
  end if;
  begin
    insert into public.rides(id, user_id, started_at)
      values ('b1000000-0000-4000-8000-000000000099', auth.uid(), now());
    raise exception 'old JWT still writes rides after ban';
  exception when insufficient_privilege then null; end;
  begin
    insert into storage.objects(bucket_id, name)
      values ('rides', 'rides/' || auth.uid()::text || '/late.gpx');
    raise exception 'old JWT still uploads after ban';
  exception when insufficient_privilege then null; end;
end;
$$;
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000002';
do $$
begin
  if (select count(*) from public.rides) <> 1 or (select count(*) from storage.objects) <> 1 then
    raise exception 'another account was affected by the ban';
  end if;
end;
$$;
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000003';
select public.admin_set_account_disabled('a1000000-0000-4000-8000-000000000001', false);
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000001';
do $$
begin
  if (select count(*) from public.rides) <> 1 then raise exception 'unban did not restore owner access'; end if;
end;
$$;

reset role;
select public.begin_account_cleanup('a1000000-0000-4000-8000-000000000001',
  'a1000000-0000-4000-8000-000000000001', 'wipe', 'c1000000-0000-4000-8000-000000000001');
do $$
declare v_count integer;
begin
  select count(*) into v_count from public.list_account_cleanup_objects(
    'a1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001');
  if v_count <> 1 then raise exception 'orphan object was not enumerated'; end if;
  begin
    perform public.finish_account_cleanup('a1000000-0000-4000-8000-000000000001',
      'c1000000-0000-4000-8000-000000000001');
    raise exception 'finish accepted remaining objects' using errcode = 'XX000';
  exception when raise_exception then null; end;
  begin
    perform public.begin_account_cleanup('a1000000-0000-4000-8000-000000000001',
      'a1000000-0000-4000-8000-000000000001', 'wipe', 'c1000000-0000-4000-8000-000000000002');
    raise exception 'concurrent worker stole cleanup';
  exception when lock_not_available then null; end;
end;
$$;
set local role authenticated;
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000001';
do $$
begin
  if exists (select 1 from storage.objects) or exists (select 1 from public.rides) then
    raise exception 'cleanup fence allowed reads';
  end if;
  begin
    insert into storage.objects(bucket_id, name)
      values ('rides', 'rides/' || auth.uid()::text || '/late-upload.gpx');
    raise exception 'cleanup fence allowed late upload';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.user_settings(user_id) values (auth.uid())
      on conflict(user_id) do update set units = 'imperial';
    raise exception 'cleanup fence allowed settings upsert';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
-- A failed worker releases only its claim, not the fence. A retry resumes.
select public.release_account_cleanup('a1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001');
do $$
begin
  if (select cleanup_mode from cycling_private.account_access where user_id = 'a1000000-0000-4000-8000-000000000001') <> 'wipe' then
    raise exception 'failed cleanup reopened account';
  end if;
end;
$$;
select public.begin_account_cleanup('a1000000-0000-4000-8000-000000000001',
  'a1000000-0000-4000-8000-000000000001', 'wipe', 'c1000000-0000-4000-8000-000000000002');
-- Simulates the Storage API's successful removal in the disposable fixture.
delete from storage.objects where name like 'rides/a1000000-0000-4000-8000-000000000001/%';
select public.finish_account_cleanup('a1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000002');
do $$
begin
  if exists (select 1 from public.rides where user_id = 'a1000000-0000-4000-8000-000000000001') then
    raise exception 'wipe did not clear rides';
  end if;
  if not exists (select 1 from auth.users where id = 'a1000000-0000-4000-8000-000000000001') then
    raise exception 'wipe deleted the account';
  end if;
  if not exists (select 1 from public.rides where user_id = 'a1000000-0000-4000-8000-000000000002') then
    raise exception 'wipe deleted someone else data';
  end if;
end;
$$;

-- The privileged Storage finalizer cannot resurrect a pre-wipe object even
-- AFTER the account reopens. This is the race RLS alone cannot protect.
do $$
begin
  begin
    insert into storage.objects(bucket_id, name)
      values ('rides', current_setting('test.old_upload_path'));
    raise exception 'superuser finalized an expired upload epoch';
  exception when insufficient_privilege then null; end;
  begin
    insert into storage.objects(bucket_id, name) values
      ('rides', 'rides/a1000000-0000-4000-8000-000000000001/b1000000-0000-4000-8000-000000000088/original.gpx');
    raise exception 'legacy shared path upload was accepted';
  exception when insufficient_privilege then null; end;
end;
$$;
set local role authenticated;
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000001';
insert into storage.objects(bucket_id, name)
select 'rides', public.new_gpx_upload_path('b1000000-0000-4000-8000-000000000088',
  'c1000000-0000-4000-8000-000000000088');
reset role;
-- Even service-role upserts cannot replace a committed versioned trace.
do $$
begin
  begin
    update storage.objects set metadata = '{}'::jsonb
    where name like 'rides/a1000000-0000-4000-8000-000000000001/%';
    raise exception 'committed versioned objects were mutable';
  exception when insufficient_privilege then null; end;
end;
$$;
-- Remove the fresh successful fixture before testing account deletion.
delete from storage.objects where name like 'rides/a1000000-0000-4000-8000-000000000001/%';

-- Exact UUID lookup finds an older account beyond the first 200 users.
insert into auth.users(id, email, created_at)
select ('d1000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
  'page-' || i::text || '@example.test', '2026-01-01' from generate_series(1, 205) i;
set local role authenticated;
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000003';
do $$
begin
  if exists (select 1 from public.admin_list_users(null, 200, 0) where id = 'a1000000-0000-4000-8000-000000000001') then
    raise exception 'fixture target should be beyond page 200';
  end if;
  if (select count(*) from public.admin_get_user('a1000000-0000-4000-8000-000000000001')) <> 1 then
    raise exception 'exact UUID lookup missed an older user';
  end if;
end;
$$;
reset role;
-- Delete lifecycle never opens access between storage cleanup and auth delete.
select public.begin_account_cleanup('a1000000-0000-4000-8000-000000000001',
  'a1000000-0000-4000-8000-000000000003', 'delete', 'c1000000-0000-4000-8000-000000000003');
select public.finish_account_cleanup('a1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000003');
do $$
begin
  if (select cleanup_mode from cycling_private.account_access where user_id = 'a1000000-0000-4000-8000-000000000001') <> 'delete' then
    raise exception 'delete fence was released before auth removal';
  end if;
  begin
    perform public.begin_account_cleanup('a1000000-0000-4000-8000-000000000003',
      'a1000000-0000-4000-8000-000000000002', 'delete', gen_random_uuid());
    raise exception 'non-admin actor could target admin';
  exception when insufficient_privilege then null; end;
end;
$$;
delete from auth.users where id = 'a1000000-0000-4000-8000-000000000001';
set local role authenticated;
set local request.jwt.claim.sub = 'a1000000-0000-4000-8000-000000000001';
do $$
begin
  if cycling_private.account_is_active() then raise exception 'deleted account JWT is still active'; end if;
  begin
    insert into storage.objects(bucket_id, name) values ('rides', 'rides/' || auth.uid()::text || '/after-delete.gpx');
    raise exception 'deleted account uploaded with an old JWT';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
set local role anon;
do $$
begin
  begin
    perform public.admin_get_user('a1000000-0000-4000-8000-000000000003');
    raise exception 'anon could call exact lookup';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
rollback;
