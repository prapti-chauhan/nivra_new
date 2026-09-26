-- nivra — Supabase schema for slice one.
--
-- Run this once in the Supabase SQL editor. It is written to be re-runnable.
--
-- Two things are deliberate and worth reading before changing them:
--
--  1. `server_updated_at` is stamped by the trigger below, never by the
--     client. It is the cursor devices page through when pulling. Device
--     clocks drift and users change the date by hand; paging on a
--     client-written timestamp would silently skip rows forever.
--
--  2. There is no `stock_qty` column. Stock on hand is the sum of
--     `stock_movements.qty_delta` and each device recomputes it locally after
--     a pull. Storing the total here would let a stale copy race the movements
--     that produced it.
--
-- Ids are text rather than uuid: they are generated on the device and a
-- rejected cast would be a permanent, silent sync failure for that row.

-- ---------------------------------------------------------------------------
-- server stamp
-- ---------------------------------------------------------------------------

create or replace function public.stamp_server_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.server_updated_at :=
    (extract(epoch from clock_timestamp()) * 1000)::bigint;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- items
-- ---------------------------------------------------------------------------

create table if not exists public.items (
  id                  text primary key,
  user_id             text not null,
  created_at          bigint not null,
  updated_at          bigint not null,
  deleted_at          bigint,
  server_updated_at   bigint not null default 0,
  name                text not null,
  code                text,
  unit                text not null default 'pcs',
  sale_price          bigint not null default 0,
  purchase_price      bigint not null default 0,
  low_stock_threshold bigint,
  category            text,
  hsn_code            text,          -- reserved for GST, unused
  tax_rate_bp         integer not null default 0  -- reserved for GST
);

create index if not exists items_pull_idx
  on public.items (user_id, server_updated_at);

drop trigger if exists items_stamp on public.items;
create trigger items_stamp
  before insert or update on public.items
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- stock_movements  (append-only)
-- ---------------------------------------------------------------------------

create table if not exists public.stock_movements (
  id                text primary key,
  user_id           text not null,
  created_at        bigint not null,
  updated_at        bigint not null,
  deleted_at        bigint,
  server_updated_at bigint not null default 0,
  item_id           text not null references public.items (id) on delete cascade,
  qty_delta         bigint not null,     -- thousandths, signed
  unit_cost         bigint not null default 0,  -- paise per unit
  reason            text not null,
  source_type       text,
  source_id         text,
  occurred_at       bigint not null,
  note              text
);

create index if not exists stock_movements_pull_idx
  on public.stock_movements (user_id, server_updated_at);

create index if not exists stock_movements_item_idx
  on public.stock_movements (item_id, occurred_at);

drop trigger if exists stock_movements_stamp on public.stock_movements;
create trigger stock_movements_stamp
  before insert or update on public.stock_movements
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- business_profiles
-- ---------------------------------------------------------------------------

create table if not exists public.business_profiles (
  id                  text primary key,
  user_id             text not null,
  created_at          bigint not null,
  updated_at          bigint not null,
  deleted_at          bigint,
  server_updated_at   bigint not null default 0,
  shop_name           text not null default '',
  owner_name          text,
  phone               text,
  address             text,
  invoice_prefix      text not null default '',
  invoice_next_number integer not null default 1
);

create index if not exists business_profiles_pull_idx
  on public.business_profiles (user_id, server_updated_at);

drop trigger if exists business_profiles_stamp on public.business_profiles;
create trigger business_profiles_stamp
  before insert or update on public.business_profiles
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- row level security
--
-- One user owns their own data and there are no staff logins, so every policy
-- is the same sentence: you may touch a row only if it is yours. The client
-- never filters by user_id on a pull — this is what makes that safe.
-- ---------------------------------------------------------------------------

alter table public.items             enable row level security;
alter table public.stock_movements   enable row level security;
alter table public.business_profiles enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['items', 'stock_movements', 'business_profiles']
  loop
    execute format('drop policy if exists %I_owner_select on public.%I', t, t);
    execute format('drop policy if exists %I_owner_insert on public.%I', t, t);
    execute format('drop policy if exists %I_owner_update on public.%I', t, t);
    execute format('drop policy if exists %I_owner_delete on public.%I', t, t);

    execute format(
      'create policy %I_owner_select on public.%I for select to authenticated '
      'using (user_id = auth.uid()::text)', t, t);
    execute format(
      'create policy %I_owner_insert on public.%I for insert to authenticated '
      'with check (user_id = auth.uid()::text)', t, t);
    execute format(
      'create policy %I_owner_update on public.%I for update to authenticated '
      'using (user_id = auth.uid()::text) '
      'with check (user_id = auth.uid()::text)', t, t);
    -- No delete policy on purpose. Nothing is ever hard-deleted; a delete is
    -- `deleted_at`, which travels as an ordinary update.
  end loop;
end
$$;
