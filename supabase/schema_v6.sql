-- nivra — Supabase schema for slice ten: editing a purchase in place.
--
-- Run after schema_v5.sql. Re-runnable.
--
-- Mirrors what schema_v2.sql did for bills:
--   * purchases.revision counts edits, 0 for a purchase never edited. Every
--     existing row therefore reads as unedited, which is correct.
--   * purchase_revisions holds one JSON snapshot per superseded version, so
--     the figures an edit overwrote can still be read.
-- Same rules as every other table: `server_updated_at` is stamped by the
-- trigger and is the pull cursor, and row level security keys on user_id.

alter table public.purchases
  add column if not exists revision integer not null default 0;

create table if not exists public.purchase_revisions (
  id                text primary key,
  user_id           text not null,
  created_at        bigint not null,
  updated_at        bigint not null,
  deleted_at        bigint,
  server_updated_at bigint not null default 0,
  purchase_id       text not null references public.purchases (id) on delete cascade,
  revision          integer not null,
  snapshot          text not null,   -- JSON archive, never queried by field
  replaced_at       bigint not null
);

create index if not exists purchase_revisions_pull_idx
  on public.purchase_revisions (user_id, server_updated_at);
create index if not exists purchase_revisions_purchase_idx
  on public.purchase_revisions (purchase_id);

drop trigger if exists purchase_revisions_stamp on public.purchase_revisions;
create trigger purchase_revisions_stamp
  before insert or update on public.purchase_revisions
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- row level security — same sentence as before
-- ---------------------------------------------------------------------------

alter table public.purchase_revisions enable row level security;

drop policy if exists purchase_revisions_owner_select on public.purchase_revisions;
drop policy if exists purchase_revisions_owner_insert on public.purchase_revisions;
drop policy if exists purchase_revisions_owner_update on public.purchase_revisions;

create policy purchase_revisions_owner_select on public.purchase_revisions
  for select to authenticated using (user_id = auth.uid()::text);
create policy purchase_revisions_owner_insert on public.purchase_revisions
  for insert to authenticated with check (user_id = auth.uid()::text);
create policy purchase_revisions_owner_update on public.purchase_revisions
  for update to authenticated
  using (user_id = auth.uid()::text)
  with check (user_id = auth.uid()::text);
-- No delete policy, deliberately. Nothing is ever hard-deleted.
