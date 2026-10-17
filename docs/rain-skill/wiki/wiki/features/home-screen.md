# Home screen (2026-10-17)

The `/bills` landing screen, rebuilt in the layout shopkeepers coming from other billing apps expect. Same route, same providers. Layout only: palette, icons and wording are Nivra's own, no third-party logo or assets.

- Header: shop logo and name from `businessProfileProvider` / `logoBytesProvider`, sync indicator, settings gear (`/more`).
- Pills: Transaction Details (bills) and Party Details (customers via `CustomerRow`, plus the "Owed to you" total).
- Quick Links: Add Txn (sheet: Sale or Expense), Sale Report, Day Book, Profit & Loss.
- Search and filter: `filterBills` in `bills_screen.dart` matches customer name or the printed bill number; Unpaid includes part-paid. Client-side, so `billsSearchProvider` is no longer used by this screen.
- Cards: SALE chip, `#number`, `d MMM, yy`, Total and Balance, menu (View, Edit, Share). FAB "Add New Sale" keeps key `new-bill`.
- Bottom nav: first tab renamed Bills -> Home. Five tabs kept.

Decisions: the expense app-bar icon moved into Add Txn so the counter-expense shortcut survives. Rejected: a separate `HomeScreen` route (two near-duplicate screens).

Not built: PAYMENT-IN rows in the list, inline Print/Pdf/Share icons per card, a "Get Desktop" tab.

Tests: `test/features/home_screen_test.dart`; `money_flow_test.dart` updated to go through Add Txn.
