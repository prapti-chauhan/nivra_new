# Architecture

Flutter, Riverpod, feature-first folders, pure `lib/domain/`. Local Drift (SQLite)
is the source of truth on the phone; `lib/data/sync/` pushes dirty rows and pulls
by a server-stamped cursor to Supabase (Postgres + RLS + Storage). Money is paise,
quantities are thousandths, ids are device-generated UUIDs. Stock and balances are
caches rebuilt from append-only ledgers.

Local schema is version 7 (`drift_schemas/`); the Supabase side is
`supabase/schema.sql` then `schema_v2.sql` ... `schema_v7.sql`, applied by hand.

_Source: lib/data/db/database.dart, docs/decisions.md, docs/setup.md_
