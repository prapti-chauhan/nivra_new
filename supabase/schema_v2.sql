-- nivra — Supabase schema for slice two: customers, bills, the money ledger.
--
-- Run after schema.sql. Re-runnable.
--
-- Same two rules as slice one, for the same reasons:
--   * `server_updated_at` is stamped by the trigger, never by the client, and
--     is the cursor devices page through when pulling.
--   * No cached totals live here. There is no `balance` on customers and no
--     `amount_paid` on bills, because both are sums of rows that are
--     themselves synced. A fresh install recomputes them from ledger_entries
--     and payments rather than trusting a number off the wire.

-- ---------------------------------------------------------------------------
-- customers
-- ---------------------------------------------------------------------------

create table if not exists public.customers (
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
  linked_supplier_id text             -- the same person's supplier row, later
);

create index if not exists customers_pull_idx
  on public.customers (user_id, server_updated_at);

drop trigger if exists customers_stamp on public.customers;
create trigger customers_stamp
  before insert or update on public.customers
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- bills
-- ---------------------------------------------------------------------------

create table if not exists public.bills (
  id                text primary key,
  user_id           text not null,
  created_at        bigint not null,
  updated_at        bigint not null,
  deleted_at        bigint,
  server_updated_at bigint not null default 0,
  number            bigint not null,
  number_prefix     text not null default '',
  customer_id       text references public.customers (id) on delete set null,
  customer_name     text,             -- snapshot at billing time
  subtotal          bigint not null default 0,
  discount_type     text not null default 'none',
  discount_value    bigint not null default 0,
  discount_amount   bigint not null default 0,
  total             bigint not null default 0,
  occurred_at       bigint not null,
  note              text,
  revision          integer not null default 0
);

create index if not exists bills_pull_idx
  on public.bills (user_id, server_updated_at);
create index if not exists bills_customer_idx
  on public.bills (customer_id);

drop trigger if exists bills_stamp on public.bills;
create trigger bills_stamp
  before insert or update on public.bills
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- bill_lines
-- ---------------------------------------------------------------------------

create table if not exists public.bill_lines (
  id                text primary key,
  user_id           text not null,
  created_at        bigint not null,
  updated_at        bigint not null,
  deleted_at        bigint,
  server_updated_at bigint not null default 0,
  bill_id           text not null references public.bills (id) on delete cascade,
  item_id           text references public.items (id) on delete set null,
  name              text not null,    -- snapshot, so a renamed item does not
  unit              text not null default 'pcs',
  qty               bigint not null,            -- thousandths
  unit_price        bigint not null default 0,  -- paise
  unit_cost         bigint not null default 0,  -- paise, for profit later
  line_total        bigint not null default 0,  -- paise
  tax_rate_bp       integer not null default 0, -- reserved for GST
  position          integer not null default 0
);

create index if not exists bill_lines_pull_idx
  on public.bill_lines (user_id, server_updated_at);
create index if not exists bill_lines_bill_idx
  on public.bill_lines (bill_id);

drop trigger if exists bill_lines_stamp on public.bill_lines;
create trigger bill_lines_stamp
  before insert or update on public.bill_lines
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- bill_revisions  (one row per superseded version)
-- ---------------------------------------------------------------------------

create table if not exists public.bill_revisions (
  id                text primary key,
  user_id           text not null,
  created_at        bigint not null,
  updated_at        bigint not null,
  deleted_at        bigint,
  server_updated_at bigint not null default 0,
  bill_id           text not null references public.bills (id) on delete cascade,
  revision          integer not null,
  snapshot          text not null,   -- JSON archive, never queried by field
  replaced_at       bigint not null
);

create index if not exists bill_revisions_pull_idx
  on public.bill_revisions (user_id, server_updated_at);
create index if not exists bill_revisions_bill_idx
  on public.bill_revisions (bill_id);

drop trigger if exists bill_revisions_stamp on public.bill_revisions;
create trigger bill_revisions_stamp
  before insert or update on public.bill_revisions
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- ledger_entries  (append-only)
-- ---------------------------------------------------------------------------

create table if not exists public.ledger_entries (
  id                text primary key,
  user_id           text not null,
  created_at        bigint not null,
  updated_at        bigint not null,
  deleted_at        bigint,
  server_updated_at bigint not null default 0,
  account_type      text not null,   -- customer | cash | bank | sales | ...
  account_id        text,            -- the customer id when account_type says so
  amount            bigint not null, -- paise, signed; + means owed to the shop
  reason            text not null,
  source_type       text,
  source_id         text,
  occurred_at       bigint not null,
  note              text
);

create index if not exists ledger_entries_pull_idx
  on public.ledger_entries (user_id, server_updated_at);
create index if not exists ledger_entries_account_idx
  on public.ledger_entries (account_type, account_id, occurred_at);

drop trigger if exists ledger_entries_stamp on public.ledger_entries;
create trigger ledger_entries_stamp
  before insert or update on public.ledger_entries
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- payments
-- ---------------------------------------------------------------------------

create table if not exists public.payments (
  id                text primary key,
  user_id           text not null,
  created_at        bigint not null,
  updated_at        bigint not null,
  deleted_at        bigint,
  server_updated_at bigint not null default 0,
  customer_id       text references public.customers (id) on delete set null,
  bill_id           text references public.bills (id) on delete cascade,
  amount            bigint not null,  -- paise, positive is money in
  method            text not null default 'cash',
  occurred_at       bigint not null,
  note              text
);

create index if not exists payments_pull_idx
  on public.payments (user_id, server_updated_at);
create index if not exists payments_bill_idx
  on public.payments (bill_id);

drop trigger if exists payments_stamp on public.payments;
create trigger payments_stamp
  before insert or update on public.payments
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- row level security — same sentence as slice one, on every new table
-- ---------------------------------------------------------------------------

alter table public.customers      enable row level security;
alter table public.bills          enable row level security;
alter table public.bill_lines     enable row level security;
alter table public.bill_revisions enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.payments       enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array[
    'customers', 'bills', 'bill_lines', 'bill_revisions',
    'ledger_entries', 'payments'
  ]
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
