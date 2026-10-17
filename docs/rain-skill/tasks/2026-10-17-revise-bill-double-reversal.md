# BUG_FIX: reviseBill / deleteBill double-reverse earlier ledger entries

Status: DONE (2026-10-17). Option (a): forward fix only, no repair of old rows. 4 new tests in billing_dao_test.dart, analyze clean, 366 tests pass. Callers of `_reverseEffects`: reviseBill, deleteBill only. Rolled back with `git restore lib/data/db/database.dart` if needed.

## Root cause
`BillingDao._reverseEffects` (lib/data/db/database.dart, ~line 1666) cancels a bill's books by selecting every ledger entry with `source_type='bill'`, `source_id=<bill>` and `reason = 'sale'`, and writing the negative of each.

Entries after one edit: `sale +A`, `saleReversal -A`, `sale +B`. On the second edit the query returns BOTH `sale` rows (+A and +B) and reverses both: `-A` and `-B`. Net before applying the new version: `+A -A +B -A -B = -A`, but it must be 0. Every account touched (sales, customer) ends up A too low, so a customer is shown as owing less than they do.

The same function is used by `deleteBill`, so deleting a bill that was edited earlier is wrong in the same way. `restoreBill` then re-applies `bill.total`, which is correct only if the delete left a net of zero.

Stock movements are not affected: they are reversed from the bill's current (non-deleted) lines, not by querying history.

## Precedent
`_reversePurchaseLedger` (same file, ~line 2584) already fixes this for purchases by reversing the NET per (account_type, account_id) over all entries for the source. Bills never got it.

## Plan
1. RED: tests in `test/data/billing_dao_test.dart` (or a new file) for a credit bill edited twice: customer balance and sales account after edit 2 equal the new total; delete after two edits leaves balance 0; delete then restore returns to total.
2. GREEN: in `_reverseEffects`, replace the `reason = sale` query with `SUM(amount) ... GROUP BY account_type, account_id` over `source_type='bill' AND source_id=?`, skip zero nets, write `-net` with reason `saleReversal`. Mirror `_reversePurchaseLedger`.
3. `flutter analyze`, full `flutter test`.
4. Update open-questions.md and the wiki.

## Decision needed: data already written wrong
Bills edited twice before this fix have wrong ledger rows. Options:
a. Fix going forward only (recommended if the only data is sample/test data).
b. Also add a one-off repair that, per bill, compares the net ledger to what it should be (`total` if live, 0 if deleted) and writes a correcting entry. Extra scope plus a migration-like step.

## Not in this task (separate calls)
- Apply schema_v5/v6/v7 to the live Supabase project: changes a live system, needs your explicit go-ahead.
- Strip EXIF from logo photos before upload: separate small fix, can do next.
- Device run and clean live-sync run: need you and a phone.
