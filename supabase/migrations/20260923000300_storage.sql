-- Storage for original GPX files (spec §24).
--
-- Path layout:
--
--   rides/{user_id}/{ride_id}/original.gpx
--   rides/{user_id}/{ride_id}/activity.fit   (V2)
--   rides/{user_id}/{ride_id}/thumbnail.png  (V2)
--
-- The bucket is **private**. A location trace reveals where somebody lives,
-- works and sleeps; a public bucket with an unguessable path is one link-share
-- away from being public in practice (spec §44).

-- `public`, `file_size_limit` and `allowed_mime_types` are not part of the
-- base `storage.buckets` table. They are added by **storage-api's own
-- migrations, which run when that service first starts** — so they are present
-- on every real project, and absent on a Postgres image that has only just
-- been started.
--
-- The distinction is not academic. `supabase db reset` applies these
-- migrations while the stack is still coming up, so a plain `insert ... public`
-- fails or succeeds depending on whether storage-api won the race. Guarding on
-- the column's presence makes the migration do the right thing in both cases
-- instead of the right thing most of the time.
do $$
declare
  has_full_schema boolean;
begin
  select exists (
    select 1 from information_schema.columns
    where table_schema = 'storage'
      and table_name = 'buckets'
      and column_name = 'public'
  ) into has_full_schema;

  if has_full_schema then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values (
      'rides',
      'rides',
      false,
      52428800, -- 50 MB: a 12-hour ride at 1 Hz of GPX is well under this.
      array['application/gpx+xml', 'application/xml', 'text/xml', 'application/octet-stream']
    )
    on conflict (id) do update set
      public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;
  else
    -- Storage has not initialised yet. Create the row; `public` defaults to
    -- false, which is the value we wanted anyway, and the constraints get
    -- applied the next time this migration runs against an upgraded schema.
    insert into storage.buckets (id, name)
    values ('rides', 'rides')
    on conflict (id) do nothing;
  end if;
end $$;

-- Files are never overwritten by a different user, and never overwritten in
-- place at all: the ride id is part of the path, so a re-upload of the same
-- ride targets the same object and `upsert` handles it.
--
-- `storage.foldername(name)` splits the object path on `/`, so for
-- `rides/<uid>/<ride_id>/original.gpx` element 1 is the bucket-style prefix
-- and element 2 is the owner's uid.

drop policy if exists "Users can read own ride files" on storage.objects;
create policy "Users can read own ride files"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'rides'
  and (storage.foldername(name))[1] = 'rides'
  and (storage.foldername(name))[2] = (select auth.uid())::text
);

drop policy if exists "Users can upload own ride files" on storage.objects;
create policy "Users can upload own ride files"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'rides'
  and (storage.foldername(name))[1] = 'rides'
  and (storage.foldername(name))[2] = (select auth.uid())::text
);

drop policy if exists "Users can update own ride files" on storage.objects;
create policy "Users can update own ride files"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'rides'
  and (storage.foldername(name))[1] = 'rides'
  and (storage.foldername(name))[2] = (select auth.uid())::text
)
with check (
  bucket_id = 'rides'
  and (storage.foldername(name))[1] = 'rides'
  and (storage.foldername(name))[2] = (select auth.uid())::text
);

drop policy if exists "Users can delete own ride files" on storage.objects;
create policy "Users can delete own ride files"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'rides'
  and (storage.foldername(name))[1] = 'rides'
  and (storage.foldername(name))[2] = (select auth.uid())::text
);
