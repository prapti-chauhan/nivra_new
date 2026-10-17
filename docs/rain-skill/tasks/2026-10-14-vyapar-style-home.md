# Vyapar-style home screen

Flow: FEATURE
Status: DONE (2026-10-17). analyze clean, 362 tests pass. Add Txn opens a Sale/Expense sheet so the expense shortcut is kept.

## Brainstorm
Reference: screenshot of Vyapar home (user-supplied, 2026-10-14).
Answered by screenshot: sections wanted = header, tab pills, Quick Links card, search + filter, transaction cards, "Add New Sale" FAB, bottom nav.
Defaults chosen (user can overrule by editing this file):
- Replaces the current `/bills` landing screen (`BillsScreen`); no new route.
- Layout copied; colours stay Nivra's green palette, Material icons, no Vyapar logo/assets.
- All data real (bills from `billsProvider`).
- Not built in this task: Party Details tab content, "Get Desktop" tab, Pdf/print/share actions that need new plumbing (see Out of scope).

## Approaches
1. **Rebuild `BillsScreen` in place** (recommended). Same route, same providers, same tests; new header, Quick Links, search/filter, card rows. Trade-off: the screen is no longer a plain list, so existing widget tests on `_BillRow` need updating.
2. New `HomeScreen` as a fresh route, leave `BillsScreen` alone. Trade-off: two near-duplicate screens, and nav/redirects (`/bills`) must be re-pointed.

## Acceptance Criteria
1. Header: shop logo (existing logo provider) + shop name, settings icon -> `/more`, sync indicator kept.
2. Two pill tabs: "Transaction Details" (active, red-tint style in ref; Nivra accent here) and "Party Details" (switches list to customers with balance, reusing `CustomersScreen` data).
3. "Quick Links" card with 4 tiles: Add Txn (-> `/bills/new`), Sale Report (-> `/reports/sales`), Day Book (-> `/reports/money`), Profit & Loss (-> `/reports/pnl`).
4. Search field filters the list by customer name or invoice number; filter icon opens a sheet (All / Paid / Unpaid) .
5. Transaction card: customer name, SALE chip, `#number`, date (`15 Oct, 26`), Total and Balance, three-dot menu (View, Edit, Share via existing `/bills/:id/share`). Tap opens `/bills/:id`.
6. Extended FAB "Add New Sale" -> `/bills/new`, `heroTag: null`, key `new-bill` kept (existing tests).
7. Bottom nav: Home, Dashboard(Reports), Items, More. See open question 1.
8. Empty state kept. `flutter analyze` clean, `flutter test` green, new widget tests for search + filter + quick links.

## Out of scope (needs your call)
- Inline Print / Pdf / Share icons on each card (3-dot menu offers Share only; PDF exists at `/bills/:id/share`).
- PAYMENT-IN rows: need money-entry data merged into the list.
- "Get Desktop" tab.

## Open questions
1. Nav: Vyapar has Home / Dashboard / Items / More. Nivra has Bills / Items / Customers / Reports / More. Keep Nivra's 5 tabs (rename Bills -> Home, restyle) or switch to Vyapar's 4 (Customers moves under Party Details tab, Reports = Dashboard)? Default: keep 5 tabs, rename only.
2. Show PAYMENT-IN rows in the list now? Default: no.

## Plan
1. Add tests (RED): search filter, paid/unpaid filter, quick-link navigation, FAB key.
2. Split `bills_screen.dart` into `home_screen` parts: `_HomeHeader`, `_QuickLinks`, `_TxnSearchBar`, `_TxnCard`; keep `PaymentBadge` (used elsewhere).
3. Wire local state (query, filter, tab) with `StateProvider`/`Notifier` consistent with existing providers.
4. Party Details tab: reuse customers provider.
5. Rename nav label per Q1.
6. analyze + test, security-gate, post-task-review, wiki entry.
