-- nivra — Supabase schema for slice three: suppliers and purchases.
--
-- Run after schema_v2.sql. Re-runnable.
--
-- The same two rules as before, for the same reasons:
--   * `server_updated_at` is stamped by the trigger, never by the client, and
--     is the cursor devices page through when pulling.
--   * No cached totals live here. There is no `balance` on suppliers and no
--     `amount_paid` on purchases, because both are sums of rows that are
--     themselves synced. A fresh install recomputes them from ledger_entries
--     and payments rather than trusting a number off the wire.

-- ---------------------------------------------------------------------------
-- suppliers
--
-- A separate table from customers, not a flag on a shared one. The same
-- person is often both, and keeping the rows apart is what stops "he owes me
-- 4,000" and "I owe him 9,000" from ever being netted into one misleading
-- figure. `linked_customer_id` is the join, for later.
-- ---------------------------------------------------------------------------

create table if not exists public.suppliers (
  id                 text primary key,
  user_id            text not null,
  created_at         bigint not null,
  updated_at         bigint not null,
  deleted_at         bigint,
  server_updated_at  bigint not null default 0,
  name               text not null,
  phone              text,
  address            text,
  note               text,
  gstin              text,            -- reserved for GST
  linked_customer_id text
);

create index if not exists suppliers_pull_idx
  on public.suppliers (user_id, server_updated_at);

drop trigger if exists suppliers_stamp on public.suppliers;
create trigger suppliers_stamp
  before insert or update on public.suppliers
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- purchases
--
-- Carries no number of ours: the document that matters is the supplier's own
-- invoice, so `supplier_bill_no` records theirs.
-- ---------------------------------------------------------------------------

create table if not exists public.purchases (
  id                text primary key,
  user_id           text not null,
  created_at        bigint not null,
  updated_at        bigint not null,
  deleted_at        bigint,
  server_updated_at bigint not null default 0,
  supplier_id       text not null references public.suppliers (id),
  supplier_name     text,
  supplier_bill_no  text,
  subtotal          bigint not null default 0,
  discount_type     text   not null default 'none',
  discount_value    bigint not null default 0,
  discount_amount   bigint not null default 0,
  total             bigint not null default 0,
  occurred_at       bigint not null,
  note              text
);

create index if not exists purchases_pull_idx
  on public.purchases (user_id, server_updated_at);
create index if not exists purchases_supplier_idx
  on public.purchases (supplier_id);

drop trigger if exists purchases_stamp on public.purchases;
create trigger purchases_stamp
  before insert or update on public.purchases
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- purchase_lines
-- ---------------------------------------------------------------------------

create table if not exists public.purchase_lines (
  id                text primary key,
  user_id           text not null,
  created_at        bigint not null,
  updated_at        bigint not null,
  deleted_at        bigint,
  server_updated_at bigint not null default 0,
  purchase_id       text not null references public.purchases (id),
  item_id           text references public.items (id),
  name              text not null,
  unit              text not null default 'pcs',
  qty               bigint not null,
  unit_cost         bigint not null,
  line_total        bigint not null,
  tax_rate_bp       bigint not null default 0,  -- reserved for GST
  position          bigint not null default 0
);

create index if not exists purchase_lines_pull_idx
  on public.purchase_lines (user_id, server_updated_at);
create index if not exists purchase_lines_purchase_idx
  on public.purchase_lines (purchase_id);

drop trigger if exists purchase_lines_stamp on public.purchase_lines;
create trigger purchase_lines_stamp
  before insert or update on public.purchase_lines
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- payments learns the other side of the counter
--
-- A payment out is the same row with a negative amount, so the cash account
-- stays a plain sum that never has to know which kind of party was involved.
-- ---------------------------------------------------------------------------

alter table public.payments
  add column if not exists supplier_id text references public.suppliers (id);
alter table public.payments
  add column if not exists purchase_id text references public.purchases (id);

create index if not exists payments_supplier_idx
  on public.payments (supplier_id);
create index if not exists payments_purchase_idx
  on public.payments (purchase_id);

-- ---------------------------------------------------------------------------
-- row level security — same sentence as before, on every new table
-- ---------------------------------------------------------------------------

alter table public.suppliers      enable row level security;
alter table public.purchases      enable row level security;
alter table public.purchase_lines enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['suppliers', 'purchases', 'purchase_lines']
  loop
    execute format('drop policy if exists %I_owner_select on public.%I', t, t);
    execute format('drop policy if exists %I_owner_insert on public.%I', t, t);
    execute format('drop policy if exists %I_owner_update on public.%I', t, t);

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
    -- No delete policy, deliberately. Nothing is ever hard-deleted; a delete
    -- is `deleted_at`, which travels as an ordinary update.
  end loop;
end
$$;
