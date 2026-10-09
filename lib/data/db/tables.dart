import 'package:drift/drift.dart';

/// Columns every synced table carries.
///
/// `updated_at` comes from the device clock and is only used for display and
/// tie-breaking. `server_updated_at` is written by Postgres and is the one we
/// page through when pulling, because device clocks drift and users change
/// the date by hand — trusting them would silently skip rows forever.
mixin SyncedRow on Table {
  TextColumn get id => text()();
  TextColumn get userId => text()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  /// Set instead of deleting. A hard delete made offline would simply vanish
  /// and be resurrected by the next pull.
  IntColumn get deletedAt => integer().nullable()();

  IntColumn get serverUpdatedAt => integer().nullable()();
  BoolColumn get isDirty => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_items_dirty', columns: {#isDirty})
@TableIndex(name: 'idx_items_name', columns: {#name})
class Items extends Table with SyncedRow {
  TextColumn get name => text().withLength(min: 1, max: 160)();

  /// The shop's own code for the item, not a barcode.
  TextColumn get code => text().nullable()();

  TextColumn get unit => text().withDefault(const Constant('pcs'))();

  /// Paise.
  IntColumn get salePrice => integer().withDefault(const Constant(0))();

  /// Paise. Last known cost, used as the default when purchasing.
  IntColumn get purchasePrice => integer().withDefault(const Constant(0))();

  /// Thousandths. Null means Ramesh has not asked to be warned about this item.
  IntColumn get lowStockThreshold => integer().nullable()();

  TextColumn get category => text().nullable()();

  /// Reserved for GST. Unused in this version, present so adding tax later is
  /// a feature rather than a migration of live data.
  TextColumn get hsnCode => text().nullable()();

  /// Basis points. Reserved for GST; always 0 for now.
  IntColumn get taxRateBp => integer().withDefault(const Constant(0))();

  /// CACHE. Thousandths. Derived from stock_movements and never authoritative.
  /// Only InventoryDao writes this, and rebuildStockCache can recompute it.
  IntColumn get stockQty => integer().withDefault(const Constant(0))();
}

/// Append-only. Rows are never updated and `deleted_at` is never set on them;
/// a correction is a new movement with reason `reversal`.
@TableIndex(name: 'idx_movements_item', columns: {#itemId, #occurredAt})
@TableIndex(name: 'idx_movements_dirty', columns: {#isDirty})
@TableIndex(name: 'idx_movements_source', columns: {#sourceType, #sourceId})
class StockMovements extends Table with SyncedRow {
  TextColumn get itemId => text().references(Items, #id)();

  /// Thousandths, signed. Negative leaves the shop.
  IntColumn get qtyDelta => integer()();

  /// Paise per unit at the moment of the movement. Carried from the first
  /// movement onwards so profit stays traceable once reports exist.
  IntColumn get unitCost => integer().withDefault(const Constant(0))();

  /// A [MovementReason] wire value.
  TextColumn get reason => text()();

  /// The document that caused this, so any stock figure can be opened up.
  TextColumn get sourceType => text().nullable()();
  TextColumn get sourceId => text().nullable()();

  /// Business date, which is not always the date the row was created.
  IntColumn get occurredAt => integer()();

  TextColumn get note => text().nullable()();
}

/// Exactly one row per user.
class BusinessProfiles extends Table with SyncedRow {
  TextColumn get shopName => text().withDefault(const Constant(''))();
  TextColumn get ownerName => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get logoPath => text().nullable()();
  TextColumn get invoicePrefix => text().withDefault(const Constant(''))();
  IntColumn get invoiceNextNumber => integer().withDefault(const Constant(1))();
}

/// Local only. Never synced — it describes this device's progress, not data.
class SyncStates extends Table {
  TextColumn get entity => text()();

  /// Highest `server_updated_at` already pulled for this table.
  IntColumn get lastCursor => integer().withDefault(const Constant(0))();

  IntColumn get lastRunAt => integer().nullable()();
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {entity};
}

/// Local only, capped. Not a source of truth — a debugging trail so a bad
/// sync can be reconstructed weeks later.
class SyncLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get at => integer()();

  /// 'push' or 'pull'.
  TextColumn get direction => text()();
  TextColumn get entity => text()();
  IntColumn get rowCount => integer().withDefault(const Constant(0))();
  BoolColumn get ok => boolean()();
  TextColumn get detail => text().nullable()();
}

// ---------------------------------------------------------------------------
// Slice two: customers, bills, the money ledger.
// ---------------------------------------------------------------------------

/// Customers and suppliers are separate tables by decision, with an identical
/// column shape and a link between them, so a person who is both can be
/// merged later as a data migration rather than a redesign.
@TableIndex(name: 'idx_customers_dirty', columns: {#isDirty})
@TableIndex(name: 'idx_customers_name', columns: {#name})
class Customers extends Table with SyncedRow {
  TextColumn get name => text().withLength(min: 1, max: 160)();
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get note => text().nullable()();

  /// Reserved for GST.
  TextColumn get gstin => text().nullable()();

  /// The same person's row in `suppliers`, once that table exists.
  TextColumn get linkedSupplierId => text().nullable()();

  /// CACHE. Paise. Positive means they owe Ramesh. Derived from
  /// ledger_entries and rebuildable; only PartyDao writes it.
  IntColumn get balance => integer().withDefault(const Constant(0))();
}

/// Append-only, like stock_movements. Signed and account-tagged rather than
/// strictly double-entry: positive always means more is owed to Ramesh, or
/// money came in.
@TableIndex(name: 'idx_ledger_account', columns: {#accountType, #accountId, #occurredAt})
@TableIndex(name: 'idx_ledger_source', columns: {#sourceType, #sourceId})
@TableIndex(name: 'idx_ledger_dirty', columns: {#isDirty})
class LedgerEntries extends Table with SyncedRow {
  /// A [LedgerAccount] wire value.
  TextColumn get accountType => text()();

  /// The customer id when accountType is 'customer'. Null for cash, sales
  /// and the other impersonal accounts.
  TextColumn get accountId => text().nullable()();

  /// Paise, signed.
  IntColumn get amount => integer()();

  /// A [LedgerReason] wire value.
  TextColumn get reason => text()();

  TextColumn get sourceType => text().nullable()();
  TextColumn get sourceId => text().nullable()();
  IntColumn get occurredAt => integer()();
  TextColumn get note => text().nullable()();
}

@TableIndex(name: 'idx_bills_customer', columns: {#customerId})
@TableIndex(name: 'idx_bills_occurred', columns: {#occurredAt})
@TableIndex(name: 'idx_bills_dirty', columns: {#isDirty})
class Bills extends Table with SyncedRow {
  /// Allocated from business_profile at save time and then never recomputed,
  /// so changing the prefix later cannot rewrite an old bill.
  IntColumn get number => integer()();
  TextColumn get numberPrefix => text().withDefault(const Constant(''))();

  /// Null for a walk-in cash sale. Most counter sales are walk-ins, and
  /// forcing a customer would add a tap to every bill and fill the contact
  /// list with junk.
  TextColumn get customerId => text().nullable().references(Customers, #id)();

  /// Snapshot of the name at the time of billing, so a later rename does not
  /// silently change what an old bill says.
  TextColumn get customerName => text().nullable()();

  IntColumn get subtotal => integer().withDefault(const Constant(0))();

  /// A [DiscountType] wire value.
  TextColumn get discountType => text().withDefault(const Constant('none'))();

  /// Basis points for percent, paise for amount.
  IntColumn get discountValue => integer().withDefault(const Constant(0))();

  /// Paise. What the discount actually came to.
  IntColumn get discountAmount => integer().withDefault(const Constant(0))();

  IntColumn get total => integer().withDefault(const Constant(0))();

  /// CACHE. Paise. Sum of this bill's payments. Status is never stored — it
  /// is computed from total against this, so the two cannot disagree.
  IntColumn get amountPaid => integer().withDefault(const Constant(0))();

  IntColumn get occurredAt => integer()();
  TextColumn get note => text().nullable()();

  /// 0 on first save, incremented by each edit. Non-zero means the bill shows
  /// an "Edited" mark and has earlier versions in bill_revisions.
  IntColumn get revision => integer().withDefault(const Constant(0))();
}

@TableIndex(name: 'idx_bill_lines_bill', columns: {#billId})
@TableIndex(name: 'idx_bill_lines_item', columns: {#itemId})
@TableIndex(name: 'idx_bill_lines_dirty', columns: {#isDirty})
class BillLines extends Table with SyncedRow {
  TextColumn get billId => text().references(Bills, #id)();

  /// Null if the item was deleted from inventory afterwards; the name and
  /// price below are snapshots, so the bill still reads correctly.
  TextColumn get itemId => text().nullable().references(Items, #id)();

  TextColumn get name => text()();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();
  IntColumn get qty => integer()();
  IntColumn get unitPrice => integer()();

  /// Paise per unit at the time of sale, carried so profit stays traceable.
  IntColumn get unitCost => integer().withDefault(const Constant(0))();

  /// Set the first time the cost on this line is corrected, to what it was
  /// before. Never overwritten by a later correction, so the figure recorded
  /// at the time of sale can always be recovered. Null means never corrected.
  IntColumn get originalUnitCost => integer().nullable()();

  /// When the cost was last corrected. Null means never.
  IntColumn get costCorrectedAt => integer().nullable()();

  IntColumn get lineTotal => integer()();

  /// Reserved for GST.
  IntColumn get taxRateBp => integer().withDefault(const Constant(0))();

  IntColumn get position => integer().withDefault(const Constant(0))();
}

/// One row per superseded version of a bill.
///
/// The brief asks that editing an old bill leaves a trace, because that is
/// what protects Ramesh the first time a customer disputes one. There is no
/// grace period: a trace with exceptions is a trace that can be argued with.
@TableIndex(name: 'idx_bill_revisions_bill', columns: {#billId})
@TableIndex(name: 'idx_bill_revisions_dirty', columns: {#isDirty})
class BillRevisions extends Table with SyncedRow {
  TextColumn get billId => text().references(Bills, #id)();

  /// The revision number this snapshot replaced.
  IntColumn get revision => integer()();

  /// JSON of the bill and its lines as they stood. An archive, never queried
  /// field by field.
  TextColumn get snapshot => text()();

  IntColumn get replacedAt => integer()();
}

@TableIndex(name: 'idx_payments_customer', columns: {#customerId})
@TableIndex(name: 'idx_payments_bill', columns: {#billId})
@TableIndex(name: 'idx_payments_dirty', columns: {#isDirty})
class Payments extends Table with SyncedRow {
  TextColumn get customerId => text().nullable().references(Customers, #id)();
  TextColumn get billId => text().nullable().references(Bills, #id)();

  /// Set instead of [customerId] when money went the other way.
  TextColumn get supplierId => text().nullable().references(Suppliers, #id)();
  TextColumn get purchaseId => text().nullable().references(Purchases, #id)();

  /// Paise. Positive is money coming in, negative is money going out, so the
  /// cash account is a plain sum over this column and never needs to know
  /// which kind of party was involved.
  IntColumn get amount => integer()();

  /// 'cash' | 'bank' | 'upi'
  TextColumn get method => text().withDefault(const Constant('cash'))();

  IntColumn get occurredAt => integer()();
  TextColumn get note => text().nullable()();
}

// ---------------------------------------------------------------------------
// Slice three: suppliers, purchases.
// ---------------------------------------------------------------------------

/// Deliberately a separate table from [Customers] rather than one `parties`
/// table with flags.
///
/// The same person is often both — a trader Ramesh buys from who also buys
/// from him — and keeping the rows apart is what stops "he owes me 4,000" and
/// "I owe him 9,000" from ever being netted into a single misleading -5,000.
/// The column shape is identical and [linkedCustomerId] joins the two, so
/// merging later is a data migration rather than a redesign.
@TableIndex(name: 'idx_suppliers_dirty', columns: {#isDirty})
@TableIndex(name: 'idx_suppliers_name', columns: {#name})
class Suppliers extends Table with SyncedRow {
  TextColumn get name => text().withLength(min: 1, max: 160)();
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get note => text().nullable()();

  /// Reserved for GST.
  TextColumn get gstin => text().nullable()();

  TextColumn get linkedCustomerId => text().nullable()();

  /// CACHE. Paise. Derived from ledger_entries and rebuildable; only
  /// PurchaseDao writes it.
  ///
  /// Signed the same way as every other ledger figure: positive means owed to
  /// Ramesh. A supplier he owes money to therefore sits at a NEGATIVE balance.
  /// Use `payable` in the domain layer to read it the way he thinks about it.
  /// The sign is not flipped here because `cache == SUM(ledger)` is the one
  /// invariant the rebuild checks, and an exception to it is how caches rot.
  IntColumn get balance => integer().withDefault(const Constant(0))();
}

/// What Ramesh bought. Stock goes up, and what he owes the supplier goes up.
///
/// Unlike a bill this carries no number of ours: the document that matters is
/// the supplier's own invoice, so [supplierBillNo] records theirs.
@TableIndex(name: 'idx_purchases_supplier', columns: {#supplierId})
@TableIndex(name: 'idx_purchases_occurred', columns: {#occurredAt})
@TableIndex(name: 'idx_purchases_dirty', columns: {#isDirty})
class Purchases extends Table with SyncedRow {
  TextColumn get supplierId => text().references(Suppliers, #id)();

  /// Snapshot of the name at the time, so a later rename does not change what
  /// an old purchase says.
  TextColumn get supplierName => text().nullable()();

  /// The supplier's own invoice number, as printed on their bill.
  TextColumn get supplierBillNo => text().nullable()();

  IntColumn get subtotal => integer().withDefault(const Constant(0))();
  TextColumn get discountType => text().withDefault(const Constant('none'))();
  IntColumn get discountValue => integer().withDefault(const Constant(0))();
  IntColumn get discountAmount => integer().withDefault(const Constant(0))();
  IntColumn get total => integer().withDefault(const Constant(0))();

  /// CACHE. Paise. Sum of this purchase's payments, stored positive.
  IntColumn get amountPaid => integer().withDefault(const Constant(0))();

  IntColumn get occurredAt => integer()();
  TextColumn get note => text().nullable()();

  /// 0 on first save, incremented by each edit. Non-zero means the purchase
  /// shows an "Edited" mark and has earlier versions in purchase_revisions.
  IntColumn get revision => integer().withDefault(const Constant(0))();
}

/// One row per superseded version of a purchase.
///
/// Slice four corrected a purchase by deleting it and entering it again, on the
/// grounds that nobody disputes an internal record. Editing in place changes
/// that: the figures that were true yesterday are overwritten, so what they
/// were has to be kept somewhere. Same shape as [BillRevisions].
@TableIndex(name: 'idx_purchase_revisions_purchase', columns: {#purchaseId})
@TableIndex(name: 'idx_purchase_revisions_dirty', columns: {#isDirty})
class PurchaseRevisions extends Table with SyncedRow {
  TextColumn get purchaseId => text().references(Purchases, #id)();

  /// The revision number this snapshot replaced.
  IntColumn get revision => integer()();

  /// JSON of the purchase and its lines as they stood. An archive, never
  /// queried field by field.
  TextColumn get snapshot => text()();

  IntColumn get replacedAt => integer()();
}

@TableIndex(name: 'idx_purchase_lines_purchase', columns: {#purchaseId})
@TableIndex(name: 'idx_purchase_lines_item', columns: {#itemId})
@TableIndex(name: 'idx_purchase_lines_dirty', columns: {#isDirty})
class PurchaseLines extends Table with SyncedRow {
  TextColumn get purchaseId => text().references(Purchases, #id)();

  /// Null if the item was deleted afterwards; the snapshot below still reads
  /// correctly.
  TextColumn get itemId => text().nullable().references(Items, #id)();

  TextColumn get name => text()();
  TextColumn get unit => text().withDefault(const Constant('pcs'))();
  IntColumn get qty => integer()();

  /// Paise per unit. On a purchase the price IS the cost, and this is the
  /// figure carried onto the stock movement so profit stays traceable.
  IntColumn get unitCost => integer()();

  IntColumn get lineTotal => integer()();

  /// Reserved for GST.
  IntColumn get taxRateBp => integer().withDefault(const Constant(0))();

  IntColumn get position => integer().withDefault(const Constant(0))();
}


// ---------------------------------------------------------------------------
// Slice six: expenses, other income, and moving money between cash and bank.
// ---------------------------------------------------------------------------

/// One table for all three because they are mirror images and share every
/// field Ramesh fills in. [kind] says which.
///
/// Carries no cached figure. What an entry did to cash and bank is in
/// `ledger_entries`, and cash and bank balances are sums over that.
@TableIndex(name: 'idx_money_entries_occurred', columns: {#occurredAt})
@TableIndex(name: 'idx_money_entries_dirty', columns: {#isDirty})
class MoneyEntries extends Table with SyncedRow {
  /// A [MoneyKind] wire value.
  TextColumn get kind => text()();

  /// Paise, always positive. Which way the money moved is [kind] and
  /// [method], never a sign — a negative expense is a typo, not an income.
  IntColumn get amount => integer()();

  /// Free text, null for a transfer. Not a foreign key: there is deliberately
  /// no categories table to set up before the first expense can be saved.
  TextColumn get category => text().nullable()();

  /// A [MoneyMethod] wire value. For a transfer, where the money came FROM.
  TextColumn get method => text().withDefault(const Constant('cash'))();

  /// Transfers only: where the money went.
  TextColumn get toMethod => text().nullable()();

  IntColumn get occurredAt => integer()();
  TextColumn get note => text().nullable()();
}
