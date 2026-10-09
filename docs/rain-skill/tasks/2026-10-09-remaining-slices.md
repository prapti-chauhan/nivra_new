# Remaining slices (seven to twelve)

Flow: FEATURE
Created: 2026-10-09
Status: IN PROGRESS — plan approved 2026-10-09.

## Request

"Carry on with the remaining slices." Open items from `docs/decisions.md`,
done in the user's order, one slice per commit, each with a decisions.md entry.

## Brainstorm (answered)

| # | Answer |
|---|--------|
| Scope | All of a, b, c, d, e, f, g, in that order |
| Verification gaps | Not first. New features first. |
| Commits | One slice per commit |
| Language | English only, so **e (Devanagari) is dropped** |
| Logo | Gallery or camera. **Synced** across devices (Supabase Storage) |
| Schema | Claude writes `supabase/schema_v5.sql` etc.; **the user applies them** in the Supabase SQL editor. Claude never applies SQL to the live project. |

## Done =

Each slice: `flutter analyze` clean, `flutter test` green, decisions.md entry
written, one commit. Any slice that changes a synced table additionally has its
SQL file written and live tests added, but those live tests are **not claimed
as passing until the user has applied the SQL and they have been run**.

## Slices

### Slice 7 — faster expense entry (a)

No schema change.
- Read `money_entry_editor_screen.dart` and `money_screen.dart` first to see the
  current tap count.
- Likely shape: quick-add row on the Money screen, with amount field focused,
  recent categories as chips, cash/bank as a toggle defaulting to the last used,
  one Save. Target: an expense in amount + one chip + Save.
- Tests: widget test that an expense saves from amount + chip only; ledger rows
  correct.

### Slice 8 — per-line cost correction (b, D18's price-swing weakness)

Schema: **yes, `schema_v5.sql`**, local Drift `schemaVersion` 4 -> 5.
- Problem: a sale often precedes its purchase record, so `bill_lines.unit_cost`
  can be stale or zero and profit is wrong.
- Approach (proposed): add nullable `original_unit_cost` and `cost_corrected_at`
  to `bill_lines`. Correcting a line sets `unit_cost`, and keeps the first
  original value. Does not touch quantity, price or any ledger/stock row, so no
  reverse-and-reissue is needed.
- Rejected: routing it through `reviseBill`. It would reverse and reissue the
  whole sale, burn a revision and mark the bill "Edited" for what is a cost-only
  fix that changes nothing the customer sees.
- Open for you: should a corrected bill show anything on the customer's PDF?
  Proposed: no. Cost is internal.
- UI: on the profit report, lines with zero or suspect cost can be tapped to
  correct.
- Update `mappers.dart`, `sync_api.dart` pull/push, tests for round trip.

### Slice 9 — custom date range (c)

No schema change.
- Extend `ReportPeriod` / `rangeFor` in `lib/domain/reports.dart` (pure Dart)
  with a custom range; `reportPeriodProvider` carries start and end.
- UI: a "Custom" chip using `showDateRangePicker`, shared by `ReportPeriodBar`
  and the screens a tile opens into.
- Tests: boundaries at local midnight, inclusive end day, start after end rejected.

### Slice 10 — edit a purchase in place (d)

Schema: **yes, `schema_v6.sql`**, Drift 5 -> 6.
- Mirror the bill mechanism: `purchases.revision` plus a `purchase_revisions`
  table (snapshot JSON), synced, RLS like the others.
- `revisePurchase` in `database.dart` mirrors `reviseBill`: opposing stock
  movements and supplier-ledger rows, originals untouched, test asserts every
  original row survives.
- Revised purchase lines update the item's last purchase price only if it is
  the item's latest purchase (to be confirmed by reading `savePurchase`).
- Purchase detail gets an Edit action and an "Edited" mark.

### Slice 11 — shop logo, synced (f)

Schema: **yes, `schema_v7.sql`**, Drift 6 -> 7. Largest slice.
- Pick from gallery or camera: needs `image_picker` (new dependency, plus
  Android/iOS permission entries; iOS camera usage string).
- Resize and re-encode on device before upload (small, e.g. max 512 px, PNG or
  JPEG) so the invoice and storage stay small.
- Supabase Storage bucket `logos`, private, objects at `<user_id>/logo.<ext>`,
  with storage RLS so a user can only read and write their own folder.
- `business_profiles` gets a synced `logo_object` (storage path) column; local
  `logo_path` stays device-local as the cache of the downloaded file.
- Sync: upload after pick; on pull, if `logo_object` changed, download to the
  documents directory and set `logo_path`. Offline: logo saved locally, upload
  retried by the normal sync.
- Invoice PDF header (`invoice_pdf.dart`) draws it when present.
- Note: `mappers.dart` header comment about `logo_path` must be updated.
- **I am guessing** at the `supabase_flutter` storage API details and the
  `image_picker` platform setup. Will verify against the installed package
  versions before relying on it.
- Rejected: base64 in a text column. Simple, but bloats every pull of the profile row.

### Slice 12 — "Today" goes stale past midnight (g)

No schema change.
- `reportPeriodProvider` computes the range when built. Make the "now" input
  invalidate at the next local midnight (timer in the provider, via the
  database clock so tests can pin it) and on app resume.
- Tests with the pinned clock advanced across midnight.

(Slice 12 is small. Could be folded into slice 9 if you prefer, since both
touch the report period; kept separate per "one slice per commit".)

## Cross-cutting

- Domain skills: flutter-expert, flutter-apply-architecture-best-practices,
  testing-patterns, database-design, flutter-add-widget-test.
- After each slice: `flutter analyze`, `flutter test`, security-gate (slice 11
  gets the full pass: storage policies, upload content, permissions),
  post-task-review, decisions.md entry. No claim of "done" without the output.
- Wiki: `docs/rain-skill/wiki/` does not exist; will be created silently at
  close, with a feature page per slice.
- Uncommitted work at start of each slice: check `git status` first.

## Risks

- The previous live-sync runs stalled (probably laptop sleep). Slices 8, 10,
  11 add live tests whose results depend on that being solved. They will be
  reported as "written, not run" until the SQL is applied and a clean run is seen.
- Slice 11 adds a dependency and platform permission entries; the app has only
  been verified on an Android emulator.

## Log

- Slice 7 done, committed e28ba83. Also fixed a stray typo (`broadc ast`) in the user's uncommitted auth_repository.dart edit that stopped the project compiling.
- Slice 8 code, tests and schema_v5.sql written. Live test written, NOT run (SQL not applied).
