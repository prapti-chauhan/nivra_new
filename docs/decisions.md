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

---

# Slice three — the bill PDF

## Settled before building

| # | Decision | Chosen | Rejected |
|---|----------|--------|----------|
| 9 | How the PDF is made | The `pdf` package, rendered in Dart on the device | HTML through a webview; rendering server-side |
| 10 | Look | Classic invoice structure, set with care | Minimal receipt; thermal-printer format |
| 11 | Page size | A5 | A4 |
| 12 | Sharing | `share_plus` to the OS share sheet | A `wa.me` deep link |
| 13 | Storage | Rendered fresh on every share | Cached to disk after the first render |

**No network is involved at any point.** This was asked directly and is worth
recording: the renderer is plain Dart and the fonts are bundled assets. The
`printing` package ships a `PdfGoogleFonts` helper that downloads faces at
runtime, and using it would have made the bill unprintable in exactly the shop
this app is for.

**The fonts are a subset, built from the Noto Sans variable font.** The 14
standard PDF fonts contain no rupee glyph (U+20B9) at all, so an embedded face
is not a nicety — without one the bill cannot show the one symbol it most
needs. The variable original is 2 MB; static instances at weight 400 and 700,
subset to Latin, punctuation and the rupee sign, are 12.6 KB each.

**A5, not A4.** Nearly every one of these is read on a phone in WhatsApp,
where an A4 page holding three lines is mostly empty. A5 fills a phone screen
and still prints. `kInvoicePageFormat` is one constant if that turns out to be
wrong.

**Rendered fresh every time.** A bill can be revised, and a cached PDF would
quietly show superseded numbers — precisely wrong for the dispute this
document exists to settle.

**The sharing flow is three taps, not one.** WhatsApp's URL scheme cannot
attach a file, so "send this bill to this customer" has to go through the OS
share sheet: share, pick WhatsApp, pick the contact. This is a real dent in
the fifteen-second story and it is a platform limit, not a design choice.

## Decided while building

- **The bill's stored totals are printed, never recomputed.** The customer's
  copy must match what the shop's screen said, including for an old bill saved
  under arithmetic that has since changed.
- **The name snapshotted on the bill beats the customer's current name**, so a
  later rename cannot change what an old bill says.
- **A walk-in reads "Cash sale"**, never a blank — it is the most prominent
  line on the page.
- **A revised bill says so on the customer's copy**, not only on Ramesh's
  screen. A trace only he can see does not settle an argument.
- **The total is printed in words.** Its absence is one of the things that
  makes a bill look homemade.
- **A signature block** ("For <shop>", rule, "Authorised signature"), which is
  standard on an Indian invoice and gives the lower half of a short bill
  something to be.
- **The renderer has no Flutter dependency.** Asset loading lives in
  `invoice_fonts_flutter.dart`, so the PDF layer runs on the plain Dart VM —
  which is what lets `tool/emit_sample_invoice.dart` exist and what keeps the
  renderer testable without a widget harness.

## Verified, not asserted

- `flutter analyze`: clean. `flutter test`: **111 passing** (83 before this
  slice), including 28 new.
- A rendered bill was **read back with pypdf**: the rupee sign is present in
  the extracted text, the page box is A5 (419x595pt), and a 40-line bill
  paginates to 3 pages with the totals and the amount in words on the last.
- `flutter build apk --debug` succeeds with the three new plugins, and the
  subset fonts are present in the built APK under
  `assets/flutter_assets/assets/fonts/`.

**One bug was found only by looking at the output.** The `#` column was 18pt
wide, which could not fit "10" at 9pt once padding was removed. Every row from
ten onwards wrapped to two lines, pushing a 40-line bill from three pages to
four. Nothing threw and no test failed. There is now a page-count assertion
that would catch it.

## Still open after this slice

- The bundled font covers Latin only. A customer name typed in Devanagari
  will render as empty boxes on the bill. The fix is a Devanagari subset as a
  `fontFallback`; it was not done here because the app is English-only by
  decision and the extra weight deserves its own call.
- A shop logo: `business_profile.logo_path` exists and nothing sets it, so the
  invoice header is text only.
- Sharing has not yet been exercised on a physical device.

---

# Slice four — suppliers and purchases

## Settled before building

| # | Decision | Chosen | Rejected |
|---|----------|--------|----------|
| 14 | Suppliers | A separate table, confirming the slice-two call | One `parties` table with is_customer / is_supplier flags |
| 15 | Scope | Suppliers, purchases and paying suppliers, together | Purchases alone, with payment later |
| 16 | Editing a purchase | Delete and re-enter | Reverse-and-reissue with revisions, as bills have |
| 17 | Where it lives | Under More, full screen | A fifth tab in the bottom bar |

**Suppliers stayed a separate table.** Earlier in this conversation I argued for
one `parties` table, on the grounds that the same person is often both. Having
built it, the existing decision is the better one: separate rows are what stop
"he owes me 4,000" and "I owe him 9,000" from ever being netted into a single
misleading figure. `linked_customer_id` makes merging a data migration later
rather than a redesign.

**Paying suppliers is in scope**, because a payable that can only go up is not
a feature. Recording what arrived without being able to settle it would have
left the slice half-built.

**A purchase is corrected by deleting and re-entering**, not by the
reverse-and-reissue machinery bills have. Bills need a trace because a customer
may dispute one; a purchase is an internal record, and deleting it already
reverses the stock and the payable in full. Revisions can be added later
without a migration.

**Purchases live under More, not in the bottom bar.** Billing is the whole app;
adding a fifth tab would dilute the four that matter at the counter.

## Decided while building

- **One sign rule, no exceptions.** Positive means owed to Ramesh, or money
  came in. A supplier he owes therefore sits at a NEGATIVE balance, and the UI
  flips it once at the edge through `payableFromBalance`. The stored cache is
  not flipped, because `cache == SUM(ledger)` is the single invariant the
  rebuild checks and an exception to it is how caches rot.
- **A payment out is an ordinary payment row with a negative amount.** The cash
  account stays a plain sum that never has to know which kind of party was
  involved. `purchases.amount_paid` flips the sign once when rebuilding.
- **An opening payable is a ledger row, never a column** — same as opening
  stock and opening customer balances.
- **What he paid this time becomes the item's cost next time.** `savePurchase`
  updates `items.purchase_price`, and the movement carries the actual cost, so
  the costing method (still open) can be chosen later from real data.
- **Deleting a purchase reverses the payments made against it too.** The
  purchase did not happen, so neither did the money that settled it.
- **The purchase editor is deliberately not built like the bill editor.**
  Billing happens with a customer waiting and is optimised for speed; a
  purchase is entered later off the supplier's printed invoice and is optimised
  for getting the figures right, so quantity and cost are always visible and
  never assumed.

## Verified, not asserted

- `flutter analyze` clean. `flutter test`: **135 passing** (111 before), of
  which 21 are new purchase-DAO tests and 3 are migration tests.
- The DAO tests check the full round trip: a purchase raises stock and the
  payable, a payment lowers the payable and takes cash out, and deleting the
  purchase returns stock, payable and cash to exactly zero.
- Cache repair is tested by corrupting `suppliers.balance` and
  `purchases.amount_paid` directly and asserting the rebuild finds exactly one
  fault, fixes it, and finds nothing on a second run.
- `flutter build apk --debug` succeeds.

**Migration testing now exists, and did not before.** `schemaVersion` went from
2 to 3, and a fresh install exercises `createAll` and never touches
`onUpgrade` — so a broken migration would only ever have appeared on the shop
owner's phone, with his data. `drift_schemas/` now holds snapshots of v2 (taken
from the previous commit via a git worktree) and v3, and
`test/data/migration_test.dart` rebuilds a v2 database on disk, writes rows
through the old schema, reopens it under the current one and asserts the data
survived.

Two things went wrong while writing that test and are worth remembering:

- `createMigrator().createAll()` does not stamp `user_version`. The file then
  looks brand-new on reopen and drift runs `onCreate` instead of `onUpgrade` —
  so the test was silently not testing a migration at all. Letting drift open
  the v2 database normally is what stamps the version.
- `drift/drift.dart` and `matcher` both export `isNull` and `isNotNull`. Test
  files that use both need `hide`.

## Still open after this slice

- Editing a purchase in place.
- The remote half is unverified. `supabase/schema_v3.sql` is written but has
  not been applied to the live project, so none of the sync claims for these
  three tables have been checked against Postgres the way slices one and two
  were. **This is the gap to close before the slice counts as done.**
- Expenses, other income, and cash versus bank balances.
- Reports, which is where the costing method finally has to be chosen.

