-- nivra — Supabase schema for slice eleven: the shop logo.
--
-- Run after schema_v6.sql. Re-runnable.
--
-- Two parts:
--   1. business_profiles.logo_version. 0 means no logo; otherwise it is bumped
--      each time a new one is chosen. The image is not in the row — this number
--      is how another phone learns that its copy is out of date.
--   2. A private Storage bucket, `logos`, holding one object per user at
--      `<user id>/logo`, overwritten in place when the logo changes. Storage
--      policies let a user read and write only inside their own folder.
--
-- The app never sends a version before the image for it is in the bucket, so a
-- phone is never told about a logo that is not there yet.

alter table public.business_profiles
  add column if not exists logo_version integer not null default 0;

-- ---------------------------------------------------------------------------
-- the bucket
-- ---------------------------------------------------------------------------

-- Private (public = false): nothing is reachable without a signed-in user.
-- 1 MB and image types only, enforced here as well as in the app, because the
-- app is not the only thing that can talk to the bucket.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('logos', 'logos', false, 1048576, array['image/jpeg', 'image/png'])
on conflict (id) do update
  set public = false,
      file_size_limit = 1048576,
      allowed_mime_types = array['image/jpeg', 'image/png'];

-- ---------------------------------------------------------------------------
-- who may touch what in it
-- ---------------------------------------------------------------------------

drop policy if exists logos_owner_select on storage.objects;
drop policy if exists logos_owner_insert on storage.objects;
drop policy if exists logos_owner_update on storage.objects;
drop policy if exists logos_owner_delete on storage.objects;

-- The first folder of the object's path must be the caller's own user id.
create policy logos_owner_select on storage.objects
  for select to authenticated
  using (bucket_id = 'logos'
         and (storage.foldername(name))[1] = auth.uid()::text);

create policy logos_owner_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'logos'
              and (storage.foldername(name))[1] = auth.uid()::text);

-- An upload that overwrites needs update as well as insert.
create policy logos_owner_update on storage.objects
  for update to authenticated
  using (bucket_id = 'logos'
         and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'logos'
              and (storage.foldername(name))[1] = auth.uid()::text);

-- Unlike the data tables, the logo is hard-deleted: removing it from the shop
-- should remove it from the server, not leave an object behind.
create policy logos_owner_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'logos'
         and (storage.foldername(name))[1] = auth.uid()::text);
