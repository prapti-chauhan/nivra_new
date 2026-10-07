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

---

# Slice five — reports

## Settled before building

| # | Decision | Chosen | Rejected |
|---|----------|--------|----------|
| 18 | Costing for profit | Last purchase cost, frozen onto each bill line at sale | Weighted average; FIFO |
| 19 | Where reports live | A fifth tab, "Reports" | Under More; a summary strip on the Bills screen |
| 20 | What "profit" means for now | Profit on goods sold only, and labelled as such | Calling it net profit before expenses exist |
| 21 | What a low-stock warning says | How fast it is selling and about how many days are left | Quantity alone |

**Costing is last purchase cost (D18), chosen by the owner after the tradeoffs
were laid out.** It is the only option where a profit figure opens into a short
list of lines checkable with a calculator. Weighted average and FIFO would each
need an algorithm he has to take on trust, and both break on this shop's real
workflow: purchases are entered later, off the supplier's printed invoice, so a
sale often precedes its own purchase record. The known weakness is price swings:
a sale from older, cheaper stock is costed at the newer price. A per-line "correct
this cost" is the likely remedy and is not built.

**Reports got a tab (D19) — a call made without asking, and reversible.**
Purchases went under More to keep the bar at four. Reports is different:
"how much did I make" is a daily glance, not a monthly errand. It is one entry
in `shell.dart` and one branch in `router.dart` to undo.

## Decided while building

- **Every figure opens.** Overview tile -> list of bills -> the lines inside a
  bill, each showing the cost it was sold against. Three taps from the headline
  to a single line.
- **Sales and profit are two views of one list**, `billProfitsProvider`, so they
  cannot disagree about which bills count.
- **A bill discount comes out of profit.** Revenue is the bill total, not the sum
  of its lines.
- **A zero cost is never treated as free.** It is flagged on the overview, in the
  profit summary, on the bill and on the line, because profit that silently
  counts an unknown cost as zero is the one way these screens could mislead. A
  bill whose lines have not reached the phone yet is flagged the same way.
- **Profit is not net profit.** There are no expenses in the app yet, so the
  screen says "profit on goods only" in words rather than letting the number
  imply more than it is.
- **Periods are local midnight, weeks start Monday, ranges are half-open.** A
  bill at 11pm is that day's; a bill at exactly midnight belongs to one period.
- **Reorder uses `created_at`, not `occurred_at`, and only bill movements.**
  Editing a bill writes a reversal stamped now and re-applies the sale at the
  original date, so counting by `occurred_at` would keep the reversal and drop
  the re-sale and read an edited bill as negative demand. A deleted purchase is
  also a "reversal" and is not a sale. Both are tested.
- **Only items with a threshold ever appear** (unchanged from slice one), sorted
  out of stock first, then fewest days left.
- **Stock value counts negative stock as nothing**, so a miscount on the shelf
  cannot shrink the figure below what is actually there.
- **Owed-to-you and you-owe stay two lists with two totals, never netted.**
- **Reports only read.** `ReportQueries` is a plain class with no write path,
  and needs no code generation.

## Verified, not asserted

- `flutter analyze` clean; `flutter test`: **192 passing** (135 before): 33
  domain, 17 query, 7 click-through.
- **A second route to the same number.** One test sums live bills and compares
  with the `sales` account in the ledger after a save, a discounted bill, an
  edit and a delete. They agree.
- **Past profit does not move.** A purchase at a higher price changes the item's
  cost to Rs 24 and the earlier bill still reports against Rs 18.
- **An edited bill is counted once**, at its current lines.
- **Cross-tab navigation works.** A row on a report opens a bill that lives in
  the Bills tab and popping returns to the report, not the Bills tab. Tested
  against the real router rather than assumed.
- `flutter build apk --debug` succeeds.

One test assertion was wrong, not the code: with no invoice prefix a bill's
label is just "1", not "INV-0001" (my sample PDF had hardcoded a label). The
test now sets a prefix, as a real shop would.

## Not verified

- **Not run on a device, and not looked at.** The screens were exercised in
  widget tests, which render with a placeholder font, so no one has seen what
  these screens look like. The PDF got a visual check in slice three; this did
  not.
- **"Today" goes stale if the app stays open past midnight.** The period is
  computed when the provider is built. A shop that never closes the app will see
  yesterday under "Today" until it restarts.
- `supabase/schema_v3.sql` is still unapplied, so slice four's sync is still
  unchecked against Postgres. Reports add no remote schema.

## Still open

- Expenses, other income, and cash versus bank. Until they exist the profit
  figure cannot become a profit-and-loss.
- Per-line cost correction, for the price-swing weakness in D18.
- A custom date range.

---

## Slice four, verified against the live project

The slice-four sections above record the remote half as unverified. That is
closed: `schema_v3.sql` was applied and the integration test now covers it.
Both earlier "not verified" notes were true when written; this supersedes them.

`test/integration/supabase_sync_test.dart` drives the real `SyncService` through
the real `SupabaseSyncApi`, with a second empty database standing in for a fresh
install:

- Device one creates a supplier with Rs 1,000 already owed, buys 50 at Rs 18 on
  credit with Rs 300 paid at the counter, and later pays Rs 200 against nothing in
  particular. It pushes with nothing left pending.
- Device two starts empty, pulls, and arrives at a payable of Rs 1,400, `amount_paid`
  of Rs 300, stock of 60, and the new cost of Rs 18 on the item. **None of the first
  three crossed the wire**; each was rebuilt locally from the rows that define it.
- Cash paid out is Rs 500 on device two, matching device one and the server.
- Device one then deletes the purchase. Device two ends with stock back at 10, the
  payable back to Rs 800 (the Rs 1,000 opening less the Rs 200 standalone payment),
  and the Rs 300 paid against the purchase returned to the till.
- **Isolation:** an anonymous caller reads nothing from `suppliers`, `purchases` or
  `purchase_lines`; a second signed-in user sees none of the first user's rows,
  cannot insert a supplier in the first user's name, and cannot edit one (the name is
  unchanged afterwards); and the same user can still write their own, so the
  refusals are about ownership and not a table that rejects everything.

**A wrong diagnosis worth remembering.** The first full run failed on the cash
assertion: the fresh device summed cash to 0 instead of -50000, which looked like
money leaving the till and not arriving after a sync. It was not. Every test in the
file shares one signed-up user, and the bill test earlier in the same run had put
Rs 500 *into* the same till, so an unscoped cash sum netted to zero. Run alone, the
purchase test passed, and a ledger breakdown showed device one, device two and the
server in exact agreement. The assertion is now scoped to payments out
(`payment_out` and `payment_out_reversal`). No application code changed.

**Side effect on the live project.** Each run signs up throwaway users named
`nivra-it-<timestamp>@example.com` and `nivra-it-other-<timestamp>@example.com`,
and leaves their rows behind, because the client cannot delete auth users. Five were
created while verifying this slice. They are harmless, and removing them is a
dashboard job.

---

# Slice six — expenses, other income, cash and bank, profit and loss

## Settled before building

| # | Decision | Chosen | Rejected |
|---|----------|--------|----------|
| 22 | Cash and bank balances | A sum over the ledger, never stored | A cached `cash`/`bank` column kept in step |
| 23 | Shape of an entry | One `money_entries` table for expense, income and transfer | Three tables |
| 24 | Categories | Free text, his recent ones offered first, no categories table | A managed list he must set up first |
| 25 | What profit means | Profit on goods, plus other income, less expenses | Counting purchases as an expense |
| 26 | Getting a balance right | "Count the till" writes the difference as a visible adjustment | An opening-balance field; an editable balance |
| 27 | Correcting an entry | Edit by reversing and re-applying; delete softly with an undo | Overwrite in place; a confirmation dialog |

**The shape of the expense entry (D24) was the owner's to confirm and they went
with the recommendation:** an amount and a category he types or picks, with no
setup before the first one. Everything else in this table I decided and am
recording here so it can be redirected.

**No cached balance (D22).** Cash and bank have no stored figure anywhere. Each
is `SUM(amount)` over its ledger account, so there is nothing that can drift and
nothing to rebuild — unlike stock, customer balances and amounts paid, which are
caches with repair functions. It agrees with every other figure by construction.

**Purchases are not an expense (D25).** Buying stock turns cash into goods; the
shop is no poorer. The cost appears when the goods are sold, as the cost of what
was sold (D18). Counting the purchase as well would charge for the same stock
twice. Transfers are in neither column for the same reason: moving money between
cash and bank is not earning or spending it. Both are tested.

**No opening balance (D26).** Rather than a field that has to be right once and
can then never be corrected honestly, "Count the till" takes what is actually
there and writes the *difference* as an adjustment. It is how the first balance
gets in, and also how a till that is Rs 20 short gets recorded as exactly that.
A count that already matches writes nothing, because an adjustment of zero is
noise in a history that is meant to be honest.

## Decided while building

- **One sign rule, extended.** Impersonal accounts (expense, other income) are
  positive in their own direction, like sales and purchases. Cash and bank are
  signed: in is positive, out is negative.
- **UPI is bank.** Payments already routed anything that is not `cash` to the
  bank account, so entries do the same rather than inventing a third place.
- **A transfer has no category and must go somewhere else.** Same-place and
  nowhere are refused.
- **The kind of an entry cannot change in an edit.** Turning an expense into
  income is a delete and a new entry, which is what actually happened.
- **The database refuses nonsense too.** `amount > 0` and a known `kind` are
  check constraints, a second line of defence behind the screen.
- **Entry lives under Reports -> Cash and bank**, three taps from the counter.
  That is a call I made without asking and it is probably too deep for
  something done at the counter. A shortcut is the obvious next step.

## A bug found by testing the screen, and its cause

The first run of the new click-through tests failed in four places, all with the
same symptom: **Save did nothing, and said nothing.** The cause was a screen
reading `ref.read(currentUserProvider).value?.id` without ever watching the
provider. An unlistened `StreamProvider` is still loading on first read, so the
id was null and `_save` returned quietly. `bill_detail_screen.dart` already
carries a comment warning about exactly this.

Three screens had it, all written by this project's recent slices:
`money_entry_editor_screen.dart`, `money_screen.dart`, and — **from slice four —
`supplier_edit_screen.dart`, which had never been exercised through the UI and
so had shipped with a Save button that could do nothing.** All three now keep the
provider alive, and a null id now shows "You are signed out. Sign in to save."
instead of silently returning. A regression test (`supplier_flow_test.dart`) was
confirmed to fail without the fix ("Bad state: No element", no row saved) and
pass with it. A grep over every screen that reads the id now finds no other
offender.

My first reading of the failures was the same wrong shape as an earlier one —
"the code must be broken" — and a probe printing the provider's value, the row
count and the route, rather than another round of editing assertions, is what
found it.

## Verified, not asserted

- `flutter analyze` clean; `flutter test`: **259 passing** (196 before).
- **A second route to the same number.** Report expenses and income equal the
  `expense` and `other_income` ledger accounts after adds, an edit, a delete and
  a transfer.
- **Migrations:** v2 -> v4 in one open, v3 -> v4, and a v3 database on disk
  written through the old schema survives and then accepts a money entry.
  (Two older tests were still calling `migrateAndValidate(db, 3)` against a
  version-4 database and passing; they now target the current version.)
- **Click-through against the real router:** an expense in a few taps moves the
  till; a typed category is kept and offered next time; a zero amount is refused
  with a reason; profit and loss subtracts what was spent and reads a loss as a
  loss; counting the till writes a correction that opens in the ledger; delete
  has a working undo; a transfer changes neither total.
- `flutter build apk --debug` succeeds.

## Not verified

- **`supabase/schema_v4.sql` is written but NOT applied**, and the two new live
  tests in `test/integration/supabase_sync_test.dart` have not been run. They
  will fail against the live project until it is applied. This is the same gap
  slice four had before it was closed.
- **Not run on a device and not looked at.** Four slices of screens (reports,
  suppliers, purchases, money) have only ever been drawn in widget tests, which
  use a placeholder font.
- "Today" still goes stale if the app stays open past midnight.

## Still open

- A faster way to record an expense from the counter.
- Per-line cost correction (D18's price-swing weakness).
- A custom date range.
- Devanagari names on the bill.

---

## Slice six, against the live project

This supersedes the "not applied" note above. `schema_v4.sql` has been applied.

**Every one of the six live tests has passed at this commit, and every one has
also stalled.** Across three full runs the victim changed each time:

| Test | Run A | Run B |
|---|---|---|
| stock rebuilds from movements | pass | stalled |
| credit bill, payment, revision | stalled | pass |
| credit purchase, payments, delete | pass | stalled |
| supplier privacy | stalled | pass |
| **expenses, income, transfer rebuild cash and bank** | **pass** | stalled |
| **money entries private; server refuses nonsense** | stalled | **pass** |

So the new behaviour is verified, test by test: a second empty device rebuilds
cash and bank from synced ledger rows, a delete propagates, an anonymous caller
and a second user read nothing from `money_entries`, a forged insert in someone
else's name is refused, and the database itself refuses an amount of 0 or -500
and an unknown `kind` through its check constraints.

**What is not true: there has been no single clean run of all six.**

**What I believe caused the stalls, and how sure I am.** Not sure. The evidence is
consistent with the laptop sleeping mid-run, and does not prove it:

- The power log shows repeated *Maintenance Sleep* on battery, in blocks of about
  ten minutes (606 secs), with roughly 45 seconds awake between them.
- A test with a 3-minute timeout failed at about 10 minutes of wall time; a static
  analysis that takes seconds took 611. Dart timers do not count time spent
  asleep, and a connection open when the machine sleeps is dead on wake.
- Tests take about 35 seconds against awake windows of about 45, so roughly half
  would straddle a boundary, which is about what was seen.

**Why that is not proven:** a run under `caffeinate -i` still stalled. That
prevents idle sleep but not lid-close or maintenance sleep, so it may not have
kept the machine awake, and I could not confirm either way because the shell
became unavailable before I could read the power log for that window. The honest
status is: consistent with environmental sleep, not demonstrated. The test that
would demonstrate it is one clean run with the machine plugged in and awake.

**Two wrong conclusions along the way, both from too little evidence:**

1. I decided the stalls were caused by slice six after one run of the same test
   on the previous commit passed in 37 seconds. That run simply landed in an
   awake window. One comparison, confounded by timing, treated as proof.
2. Before that, I read the first failure as lost money in the till. It was
   shared state between tests (see above).

What the run did show, which stands regardless of cause: **sync requests had no
timeout.** A request that never returns holds `_running = true` for the life of
the app, and because overlapping cycles collapse into the one in flight, every
later attempt would do nothing. A phone that sleeps or changes network produces
exactly that. `SupabaseSyncApi` now gives up after 30 seconds, which `_guard`
already turns into a transient failure and a retry.

**Not yet done:** the unit tests for that timeout
(`test/data/sync_api_timeout_test.dart`) were written and four of five passed;
the fifth failed because the fake HTTP response lacked a `request`, which is
fixed but was not re-run. The change is uncommitted.

