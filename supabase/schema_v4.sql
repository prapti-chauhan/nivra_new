-- nivra — Supabase schema for slice six: expenses, other income, transfers.
--
-- Run after schema_v3.sql. Re-runnable.
--
-- The same rules as before, for the same reasons:
--   * `server_updated_at` is stamped by the trigger, never by the client, and
--     is the cursor devices page through when pulling.
--   * No cached figure lives here. Cash and bank balances are sums over
--     ledger_entries, which are themselves synced, so a fresh install
--     recomputes them instead of trusting a number off the wire.

create table if not exists public.money_entries (
  id                text primary key,
  user_id           text not null,
  created_at        bigint not null,
  updated_at        bigint not null,
  deleted_at        bigint,
  server_updated_at bigint not null default 0,
  kind              text   not null,          -- 'expense' | 'income' | 'transfer'
  amount            bigint not null,          -- paise, always positive
  category          text,                     -- free text; null for a transfer
  method            text   not null default 'cash',  -- a transfer's source
  to_method         text,                     -- a transfer's destination
  occurred_at       bigint not null,
  note              text,
  constraint money_entries_amount_positive check (amount > 0),
  constraint money_entries_kind_known
    check (kind in ('expense', 'income', 'transfer'))
);

create index if not exists money_entries_pull_idx
  on public.money_entries (user_id, server_updated_at);

drop trigger if exists money_entries_stamp on public.money_entries;
create trigger money_entries_stamp
  before insert or update on public.money_entries
  for each row execute function public.stamp_server_updated_at();

-- ---------------------------------------------------------------------------
-- row level security — same sentence as before
-- ---------------------------------------------------------------------------

alter table public.money_entries enable row level security;

drop policy if exists money_entries_owner_select on public.money_entries;
drop policy if exists money_entries_owner_insert on public.money_entries;
drop policy if exists money_entries_owner_update on public.money_entries;

create policy money_entries_owner_select on public.money_entries
  for select to authenticated using (user_id = auth.uid()::text);
create policy money_entries_owner_insert on public.money_entries
  for insert to authenticated with check (user_id = auth.uid()::text);
create policy money_entries_owner_update on public.money_entries
  for update to authenticated
  using (user_id = auth.uid()::text)
  with check (user_id = auth.uid()::text);
-- No delete policy, deliberately. Nothing is ever hard-deleted; a delete is
-- `deleted_at`, which travels as an ordinary update.
