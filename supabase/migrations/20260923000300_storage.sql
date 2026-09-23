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
