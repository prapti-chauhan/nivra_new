# nivra — decisions

A running record of the calls made and why, so nobody has to reconstruct the
reasoning from the code later. Newest section last.

## Settled before slice one

| # | Decision | Chosen | Rejected |
|---|----------|--------|----------|
| 1 | Stock and balances | Append-only ledger as the truth, cached totals as a derived optimisation, rebuildable | Mutable running totals; pure ledger with no cache |
| 2 | Local storage and sync | Drift over SQLite, sync written by us | PowerSync; Supabase-only with no local database |
| 3 | First slice | The spine: auth + items + ledger + sync end to end | Billing first with sync retrofitted; four small slices |
| 4 | Architecture | Riverpod, feature-first layout, pure `domain/` | BLoC; Provider with ChangeNotifier |

Sub-decisions:

- **Dirty flag, plus a capped local `sync_log`** for debugging, rather than a
  full outbox table. One device writes at a time, so change-by-change replay
  buys nothing, and an outbox can disagree with the rows it describes.
- **Customers and suppliers in two separate tables.** Chosen against the
  recommendation of one table. Both will carry the same column shape and a
  nullable `linked_party_id`, so merging later is a data migration rather than
  a redesign.
- **Cached totals maintained in Dart transactions, not SQLite triggers**, with
  `rebuildStockCache()` and debug-mode invariant checks as the safety net.

Settled without discussion because they are cheap now and expensive later:

- Money is an integer count of **paise**. No double ever touches a money value,
  including during formatting.
- Quantities are integer **thousandths**, so half a metre of wire is
  representable.
- Ids are **UUIDs generated on the device**, because a bill needs identity the
  moment it is saved, hours before the server hears about it.
- GST fields (`hsn_code`, `tax_rate_bp`) exist and stay zero, so adding tax
  later is a feature rather than a migration of live money data.

## Decided while building slice one

These came up in the code and were not part of the four decisions above.

- **`server_updated_at` is stamped by Postgres and is the pull cursor.** The
  device's own `updated_at` is used only for display and for the
  edited-during-push guard. Cheap Android phones drift and users change the
  date by hand; paging on a client timestamp would silently skip rows forever.

- **The stock cache is never synced.** `stock_qty` is excluded from the push
  payload and from the pull writer, and Postgres has no such column. A fresh
  install pulls items and movements and recomputes. This removes the only
  place where a server value could race a locally derived one.

- **A row edited while its push is in flight stays dirty.** `markPushed` only
  clears the flag `WHERE updated_at = <the value that was sent>`. Without this,
  an edit made during the request is marked as synced and never sent again.

- **A pulled row that collides with a dirty local row is discarded.** With one
  device writing at a time, a dirty local row is by definition newer than
  anything the server can return.

- **Transient failures are reported as "offline", not as errors.** Bad coverage
  is the normal state of Ramesh's shop, not an incident. Only a payload the
  server actually rejected (`23xxx`/`42xxx`) becomes a visible failure.

- **The sync indicator never optimistically says "Saved".** Before the service
  has reported anything it shows what the service actually knows. A widget test
  enforces this — it was a real bug before that test existed.

- **The app runs fully without Supabase configured.** Credentials come from
  `--dart-define`; absent them the app is local-only and says so honestly. An
  app that refuses to start without a backend is the wrong shape for a shop
  with no signal.

- **Rows created before a backend existed are claimed on first real sign-in.**
  `claimLocalRows` rewrites the placeholder `user_id` and marks the rows dirty.

- **An expired token does not sign Ramesh out.** If a stored session exists at
  all he keeps access to data on his own phone; sync is what fails, visibly and
  harmlessly, until the refresh succeeds.

- **Stock is allowed to go negative.** Blocking a sale because the app's count
  disagrees with the shelf would be worse than showing a number he can correct.

- **Deleting does not ask for confirmation.** It is a soft delete with an undo
  in the snackbar, which is cheaper for someone billing fast than a modal on
  every action.

- **Only items with a threshold ever warn.** A low-stock alert on everything is
  an alert on nothing.

## Verified against the live project

Slice one's remote half was checked end to end on 18 Sep 2026 against
`ezclmofmjvgxaqujcfdu.supabase.co`, not just against the fake:

- All three tables exist with the expected shape, and `items` has **no**
  `stock_qty` column, as intended.
- An anonymous read returns `[]` — RLS is on and the `anon` role matches no
  policy.
- The Postgres trigger stamps `server_updated_at` on write.
- A movement referencing a non-existent item is rejected (`409`).
- A second user cannot read the first user's rows, and cannot insert a row
  owned by them (`403`).
- A soft delete applies as an ordinary `PATCH`.
- `test/integration/supabase_sync_test.dart` drives the real `SyncService`
  through the real `SupabaseSyncApi`: device one pushes an item plus two
  movements, a second empty database pulls them and **rebuilds stock to the
  correct 32.5 from the movements alone**, and a later price edit propagates.

## Verified on a real device

Android 16 emulator (API 36), debug build, against the live project:

- Sign up on the device redirects to Items and the indicator reads "Saved" —
  a full sync cycle completed.
- An item created on the device arrives in Postgres with the right encoding:
  Rs 14.50 as `1450` paise, 24 pcs as `24000` thousandths, and no `stock_qty`.
- **Offline:** with wifi and mobile data disabled, creating an item works with
  no error and no delay; the indicator reads "2 waiting" (the item and its
  opening movement) with a cloud-off icon.
- **Back online:** sync ran on its own with no user action, indicator returned
  to "Saved", and the item created offline is on the server.
- The session survives a full app restart — the app reopens on Items, not on
  the login screen.

Fixed as a result of looking at it on a device: the item detail screen printed
the stock figure twice, once as the headline and again as a status chip that
had nothing to add. The chip now appears only when stock is low or out.

---

# Slice two — billing

## Settled before building

| # | Decision | Chosen | Rejected |
|---|----------|--------|----------|
| 5 | Bill entry layout | Search-first, one tap to add, line list as the expanded view | Keypad/POS grid; classic line-item form with a picker screen |
| 6 | Customer ledger | `ledger_entries` is the truth, `balance` is a rebuildable cache | A stored balance column |
| 7 | Invoice numbers | Plain incrementing integer + optional prefix, stored on the bill | Financial-year numbering (deferred, no migration needed to add) |
| 8 | Editing a saved bill | Reverse and reissue, with a snapshot and no grace period | Overwrite in place; immutable bills with credit notes |
| 9 | Payment status | Derived from `payments`, never stored | A status column set by hand |
| 10 | Navigation | Bottom bar, Bills first | Opening straight onto the bill editor |

The arithmetic behind decision 5: three items in fifteen seconds is about eight
interactions, so under two seconds each. Adding an item is therefore two
characters plus one tap, with no screen transition and the keyboard never
dismissed. The classic picker-screen layout costs roughly six interactions and
two transitions per item, which is where the time goes.

Two concessions to the same target, both of which remove a tap from the common
case:

- **Quantity defaults to 1**, and tapping a result that is already on the bill
  bumps it rather than adding a second line.
- **A customer is optional.** A bill starts as a cash sale. Credit requires a
  customer, because an unpaid walk-in is a debt owed by nobody — the DAO
  refuses it and the UI explains why.

## Decided while building

- **Bill lines snapshot the name, price and cost.** Editing an item afterwards
  cannot change what an old bill says.
- **Revising a bill never edits a ledger row.** The old movements and entries
  stay exactly as they were; the correction is opposing rows plus a JSON
  snapshot of the previous version. A test asserts every original row survives
  a revision untouched.
- **Deleting a bill reverses its payments too**, and burns the invoice number.
  Gaps in the sequence are correct; reused numbers are how disputes start.
- **PGRST20x is a permanent failure, not a transient one.** A missing table or
  column will fail the same way tomorrow, so it surfaces as a visible problem
  instead of retrying forever behind an "offline" label.
- **Screens that write now watch `currentUserProvider` rather than only
  reading it.** An unlistened StreamProvider is still loading on first read, so
  the user id came back null and the save silently did nothing. It only worked
  in the app because the router happened to keep that provider alive. A save
  with no user now says so instead of failing silently.

## Measured, not asserted

On an Android 16 emulator in profile mode, with **400 items** in the catalogue
(`integration_test/billing_speed_test.dart`):

```
item 1: +351ms   item 2: +146ms   item 3: +99ms   save: +60ms
TOTAL app time for three items and a save: 656ms

SEARCH LATENCY: median 35ms, best 22ms, worst 57ms
```

That is the app's own contribution only — the query, the list rebuild and the
database write. Human time to read, aim and think is not included, so it is a
floor rather than what Ramesh will experience. Against a fifteen-second budget
the app costs under a second.

Two things went wrong while measuring and are worth remembering:

- The live test binding registers no test text input, so `enterText` silently
  did nothing and the first "133ms" search figure was timing an empty query.
  The test now sets the search term directly and asserts the expected row
  actually appears, so it cannot time nothing again.
- The first attempt asserted on the worst sample, which is the cold query. It
  now asserts on the median and prints all three.

## Verified against the live project

Checked on 19 Sep 2026 against `ezclmofmjvgxaqujcfdu.supabase.co` after
`schema_v2.sql` was applied:

- Anonymous reads return nothing on all six new tables — RLS is on and the
  `anon` role matches no policy.
- `customers` has **no** `balance` column and `bills` has **no** `amount_paid`
  column, as intended. Both are rebuilt on the device.
- The trigger stamps `server_updated_at` on every new table.
- A bill line for a non-existent bill is rejected (`409`).
- A second user sees zero rows across all six tables, and cannot insert a bill
  owned by the first (`403`).
- The cursor pull query works on every table, and a second pull past the cursor
  returns nothing — no re-apply loop.

`test/integration/supabase_sync_test.dart` then drives the real `SyncService`
through the real `SupabaseSyncApi`:

- Device one creates an item, a customer, a **credit bill** for Rs 2,100 and a
  **part payment** of Rs 500, and pushes.
- Device two starts with an empty database, pulls, and arrives at stock 15,
  balance Rs 1,600 and amount paid Rs 500 — **none of which crossed the wire**.
  Each was recomputed locally from the movements, ledger entries and payments.
- Device one then revises the bill down to two bags. Device two ends at total
  Rs 840, revision 1, stock 18, balance Rs 340, and holds the superseded
  version in `bill_revisions`.

That last step is the whole slice-two design working end to end over a real
network: an edit that leaves a trace, reverses cleanly, and reconstructs
correctly on a device that never saw the original.

## Still open

- Costing method for profit (last cost, weighted average, FIFO). Movements
  already carry `unit_cost`, so this can be chosen when reports are built.
- Visual direction beyond the working theme in `lib/core/theme.dart`.
- Navigation shape once billing exists.
- Invoice numbering format.
- What happens to the free Supabase project's one-week inactivity pause before
  a real shop depends on it.
