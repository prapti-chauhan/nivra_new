-- nivra — Supabase schema for slice eight: correcting the cost on a bill line.
--
-- Run after schema_v4.sql. Re-runnable.
--
-- Two nullable columns on bill_lines, nothing else:
--   * original_unit_cost is the cost the line had before it was first
--     corrected, and is never overwritten by a later correction.
--   * cost_corrected_at is when it was last corrected.
-- Both are null for every existing row, which is correct: none were corrected.
-- No new table, no new policy — bill_lines already has row level security
-- keyed on user_id, and a correction is an ordinary update of one's own row.

alter table public.bill_lines
  add column if not exists original_unit_cost bigint,   -- paise
  add column if not exists cost_corrected_at  bigint;   -- epoch ms

-- A cost, once given, is a real price. Zero is "not recorded", which is what
-- unit_cost already means, and the app refuses to save it as a correction.
alter table public.bill_lines
  drop constraint if exists bill_lines_original_cost_nonnegative;
alter table public.bill_lines
  add constraint bill_lines_original_cost_nonnegative
  check (original_unit_cost is null or original_unit_cost >= 0);
