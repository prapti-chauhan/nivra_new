import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../core/clock.dart';
import '../../core/ids.dart';
import '../../domain/billing.dart';
import '../../domain/stock.dart';
import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    Items,
    StockMovements,
    BusinessProfiles,
    Customers,
    LedgerEntries,
    Bills,
    BillLines,
    BillRevisions,
    Payments,
    SyncStates,
    SyncLogs,
  ],
  daos: [InventoryDao, PartyDao, BillingDao, SyncDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase({this._clock = const Clock()})
      : super(driftDatabase(name: 'nivra'));


  AppDatabase.forTesting(super.executor, {this._clock = const Clock()});

  final Clock _clock;

  Clock get clock => _clock;

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // Slice two. Named explicitly rather than createAll(): drift emits
            // CREATE TABLE IF NOT EXISTS but a bare CREATE INDEX, so
            // createAll() would fail on the indexes that already exist.
            for (final table in <TableInfo<Table, dynamic>>[
              customers,
              ledgerEntries,
              bills,
              billLines,
              billRevisions,
              payments,
            ]) {
              await m.createTable(table);
            }
            for (final index in [
              idxCustomersDirty,
              idxCustomersName,
              idxLedgerAccount,
              idxLedgerSource,
              idxLedgerDirty,
              idxBillsCustomer,
              idxBillsOccurred,
              idxBillsDirty,
              idxBillLinesBill,
              idxBillLinesItem,
              idxBillLinesDirty,
              idxBillRevisionsBill,
              idxBillRevisionsDirty,
              idxPaymentsCustomer,
              idxPaymentsBill,
              idxPaymentsDirty,
            ]) {
              await m.createIndex(index);
            }
          }
        },
        beforeOpen: (details) async {
          // References are declared across the schema; without this SQLite
          // silently ignores them.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  /// Recomputes every cached total from the ledgers that define them.
  /// Returns how many rows were wrong. Run after a sync, and on demand.
  Future<CacheRepairReport> rebuildAllCaches() async {
    final stock = await InventoryDao(this).rebuildStockCache();
    final balances = await PartyDao(this).rebuildBalanceCache();
    final paid = await BillingDao(this).rebuildAmountPaidCache();
    return CacheRepairReport(stock: stock, balances: balances, billsPaid: paid);
  }
}

/// The only thing in the app allowed to write stock movements.
///
/// Every write goes through [applyMovement], which appends the movement and
/// adjusts the cached `items.stock_qty` inside one transaction. The cache is
/// an optimisation over `SUM(qty_delta)` and nothing else may touch it;
/// [rebuildStockCache] proves the two still agree.
@DriftAccessor(tables: [Items, StockMovements])
class InventoryDao extends DatabaseAccessor<AppDatabase> with _$InventoryDaoMixin {
  InventoryDao(super.db);

  Clock get _clock => attachedDatabase.clock;

  // --- reads ---------------------------------------------------------------

  Stream<List<Item>> watchItems({String search = ''}) {
    final query = select(items)..where((t) => t.deletedAt.isNull());
    final term = search.trim();
    if (term.isNotEmpty) {
      final pattern = '%${term.toLowerCase()}%';
      query.where(
        (t) => t.name.lower().like(pattern) | t.code.lower().like(pattern),
      );
    }
    query.orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.watch();
  }

  Future<Item?> findItem(String id) =>
      (select(items)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<Item?> watchItem(String id) =>
      (select(items)..where((t) => t.id.equals(id))).watchSingleOrNull();

  /// Newest first — this is what makes a stock number openable.
  Stream<List<StockMovement>> watchMovements(String itemId) {
    final query = select(stockMovements)
      ..where((t) => t.itemId.equals(itemId))
      ..orderBy([
        (t) => OrderingTerm(expression: t.occurredAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
      ]);
    return query.watch();
  }

  /// The authoritative stock figure, computed rather than read from the cache.
  Future<int> stockFromLedger(String itemId) async {
    final sum = stockMovements.qtyDelta.sum();
    final row = await (selectOnly(stockMovements)
          ..addColumns([sum])
          ..where(stockMovements.itemId.equals(itemId)))
        .getSingle();
    return row.read(sum) ?? 0;
  }

  // --- writes --------------------------------------------------------------

  /// Creates an item and, when [openingStock] is non-zero, its opening
  /// movement. Opening stock is a movement rather than a column so that
  /// correcting it later leaves a trace instead of overwriting history.
  Future<String> createItem({
    required String userId,
    required String name,
    String? code,
    String unit = 'pcs',
    int salePrice = 0,
    int purchasePrice = 0,
    int? lowStockThreshold,
    String? category,
    int openingStock = 0,
  }) async {
    final id = newId();
    final now = _clock.nowMillis();

    await transaction(() async {
      await into(items).insert(
        ItemsCompanion.insert(
          id: id,
          userId: userId,
          createdAt: now,
          updatedAt: now,
          name: name,
          code: Value(code),
          unit: Value(unit),
          salePrice: Value(salePrice),
          purchasePrice: Value(purchasePrice),
          lowStockThreshold: Value(lowStockThreshold),
          category: Value(category),
        ),
      );

      if (openingStock != 0) {
        await _insertMovement(
          userId: userId,
          itemId: id,
          qtyDelta: openingStock,
          unitCost: purchasePrice,
          reason: MovementReason.opening,
          occurredAt: now,
          now: now,
        );
      }
    });

    return id;
  }

  Future<void> updateItem({
    required String id,
    String? name,
    String? code,
    String? unit,
    int? salePrice,
    int? purchasePrice,
    int? lowStockThreshold,
    bool clearLowStockThreshold = false,
    String? category,
  }) async {
    final now = _clock.nowMillis();
    await (update(items)..where((t) => t.id.equals(id))).write(
      ItemsCompanion(
        name: name == null ? const Value.absent() : Value(name),
        code: code == null ? const Value.absent() : Value(code),
        unit: unit == null ? const Value.absent() : Value(unit),
        salePrice: salePrice == null ? const Value.absent() : Value(salePrice),
        purchasePrice:
            purchasePrice == null ? const Value.absent() : Value(purchasePrice),
        lowStockThreshold: clearLowStockThreshold
            ? const Value(null)
            : (lowStockThreshold == null
                ? const Value.absent()
                : Value(lowStockThreshold)),
        category: category == null ? const Value.absent() : Value(category),
        updatedAt: Value(now),
        isDirty: const Value(true),
      ),
    );
  }

  /// Soft delete. The row stays so the delete can reach the server and so it
  /// can be undone; movements are untouched because history did happen.
  Future<void> setItemDeleted(String id, {required bool deleted}) async {
    final now = _clock.nowMillis();
    await (update(items)..where((t) => t.id.equals(id))).write(
      ItemsCompanion(
        deletedAt: deleted ? Value(now) : const Value(null),
        updatedAt: Value(now),
        isDirty: const Value(true),
      ),
    );
  }

  /// The single entry point for changing stock.
  Future<String> applyMovement({
    required String userId,
    required String itemId,
    required int qtyDelta,
    required MovementReason reason,
    int unitCost = 0,
    MovementSource? source,
    String? sourceId,
    int? occurredAt,
    String? note,
  }) async {
    final now = _clock.nowMillis();
    late String movementId;
    await transaction(() async {
      movementId = await _insertMovement(
        userId: userId,
        itemId: itemId,
        qtyDelta: qtyDelta,
        unitCost: unitCost,
        reason: reason,
        source: source,
        sourceId: sourceId,
        occurredAt: occurredAt ?? now,
        note: note,
        now: now,
      );
    });
    return movementId;
  }

  /// Must only be called from inside a transaction.
  Future<String> _insertMovement({
    required String userId,
    required String itemId,
    required int qtyDelta,
    required int unitCost,
    required MovementReason reason,
    required int occurredAt,
    required int now,
    MovementSource? source,
    String? sourceId,
    String? note,
  }) async {
    final id = newId();

    await into(stockMovements).insert(
      StockMovementsCompanion.insert(
        id: id,
        userId: userId,
        createdAt: now,
        updatedAt: now,
        itemId: itemId,
        qtyDelta: qtyDelta,
        unitCost: Value(unitCost),
        reason: reason.wire,
        sourceType: Value(source?.wire),
        sourceId: Value(sourceId),
        occurredAt: occurredAt,
        note: Value(note),
      ),
    );

    // The cache moves with the ledger, in the same transaction, or not at all.
    // `updated_at` and `is_dirty` are deliberately NOT touched here: stock_qty
    // is local-only and never pushed, so a cache change is not a sync event.
    await customUpdate(
      'UPDATE items SET stock_qty = stock_qty + ? WHERE id = ?',
      variables: [Variable<int>(qtyDelta), Variable<String>(itemId)],
      updates: {items},
      updateKind: UpdateKind.update,
    );

    return id;
  }

  /// Recomputes every cached stock figure from the ledger.
  ///
  /// Returns the number of items whose cache was wrong. Anything above zero is
  /// a bug worth chasing, but the number on screen is correct again either way.
  /// Run after a pull, and on demand.
  Future<int> rebuildStockCache() async {
    return customUpdate(
      '''
      UPDATE items
         SET stock_qty = COALESCE(
               (SELECT SUM(m.qty_delta) FROM stock_movements m
                 WHERE m.item_id = items.id), 0)
       WHERE stock_qty != COALESCE(
               (SELECT SUM(m.qty_delta) FROM stock_movements m
                 WHERE m.item_id = items.id), 0)
      ''',
      updates: {items},
      updateKind: UpdateKind.update,
    );
  }
}

/// Names of the synced tables, in the order they must be pushed so that a row
/// never reaches Supabase before the row it points at.
class SyncTables {
  const SyncTables._();
  static const String items = 'items';
  static const String stockMovements = 'stock_movements';
  static const String businessProfiles = 'business_profiles';
  static const String customers = 'customers';
  static const String bills = 'bills';
  static const String billLines = 'bill_lines';
  static const String billRevisions = 'bill_revisions';
  static const String ledgerEntries = 'ledger_entries';
  static const String payments = 'payments';

  /// Push order matters: a row must never reach Supabase before the row it
  /// points at. bill_lines reference bills and items; payments reference both
  /// bills and customers.
  static const List<String> pushOrder = [
    businessProfiles,
    items,
    customers,
    bills,
    billLines,
    stockMovements,
    ledgerEntries,
    payments,
    billRevisions,
  ];
}

/// What a cache rebuild found. Anything above zero is a bug worth chasing,
/// but the numbers on screen are correct again either way.
class CacheRepairReport {
  const CacheRepairReport({
    required this.stock,
    required this.balances,
    required this.billsPaid,
  });

  final int stock;
  final int balances;
  final int billsPaid;

  int get total => stock + balances + billsPaid;
  bool get foundProblems => total > 0;

  @override
  String toString() =>
      'rebuilt stock=$stock balances=$balances billsPaid=$billsPaid';
}

/// Everything sync needs from the local database: which rows are waiting,
/// how to mark them settled, where each table's pull cursor is, and the log.
@DriftAccessor(
  tables: [
    Items,
    StockMovements,
    BusinessProfiles,
    Customers,
    LedgerEntries,
    Bills,
    BillLines,
    BillRevisions,
    Payments,
    SyncStates,
    SyncLogs,
  ],
)
class SyncDao extends DatabaseAccessor<AppDatabase> with _$SyncDaoMixin {
  SyncDao(super.db);

  Clock get _clock => attachedDatabase.clock;

  // --- what is waiting -----------------------------------------------------

  Future<List<Item>> dirtyItems({int limit = 200}) =>
      (select(items)..where((t) => t.isDirty.equals(true))..limit(limit)).get();

  Future<List<StockMovement>> dirtyMovements({int limit = 200}) =>
      (select(stockMovements)
            ..where((t) => t.isDirty.equals(true))
            ..orderBy([(t) => OrderingTerm(expression: t.createdAt)])
            ..limit(limit))
          .get();

  Future<List<BusinessProfile>> dirtyProfiles({int limit = 5}) =>
      (select(businessProfiles)
            ..where((t) => t.isDirty.equals(true))
            ..limit(limit))
          .get();

  Future<List<Customer>> dirtyCustomers({int limit = 200}) =>
      (select(customers)..where((t) => t.isDirty.equals(true))..limit(limit))
          .get();

  Future<List<Bill>> dirtyBills({int limit = 200}) =>
      (select(bills)
            ..where((t) => t.isDirty.equals(true))
            ..orderBy([(t) => OrderingTerm(expression: t.createdAt)])
            ..limit(limit))
          .get();

  Future<List<BillLine>> dirtyBillLines({int limit = 500}) =>
      (select(billLines)
            ..where((t) => t.isDirty.equals(true))
            ..orderBy([(t) => OrderingTerm(expression: t.createdAt)])
            ..limit(limit))
          .get();

  Future<List<BillRevision>> dirtyBillRevisions({int limit = 200}) =>
      (select(billRevisions)
            ..where((t) => t.isDirty.equals(true))
            ..limit(limit))
          .get();

  Future<List<LedgerEntry>> dirtyLedgerEntries({int limit = 500}) =>
      (select(ledgerEntries)
            ..where((t) => t.isDirty.equals(true))
            ..orderBy([(t) => OrderingTerm(expression: t.createdAt)])
            ..limit(limit))
          .get();

  Future<List<Payment>> dirtyPayments({int limit = 200}) =>
      (select(payments)
            ..where((t) => t.isDirty.equals(true))
            ..orderBy([(t) => OrderingTerm(expression: t.createdAt)])
            ..limit(limit))
          .get();

  static const String _pendingSql = '''
    SELECT
      (SELECT COUNT(*) FROM items WHERE is_dirty = 1) +
      (SELECT COUNT(*) FROM stock_movements WHERE is_dirty = 1) +
      (SELECT COUNT(*) FROM business_profiles WHERE is_dirty = 1) +
      (SELECT COUNT(*) FROM customers WHERE is_dirty = 1) +
      (SELECT COUNT(*) FROM bills WHERE is_dirty = 1) +
      (SELECT COUNT(*) FROM bill_lines WHERE is_dirty = 1) +
      (SELECT COUNT(*) FROM bill_revisions WHERE is_dirty = 1) +
      (SELECT COUNT(*) FROM ledger_entries WHERE is_dirty = 1) +
      (SELECT COUNT(*) FROM payments WHERE is_dirty = 1) AS pending
  ''';

  Future<int> pendingCount() async {
    final row = await customSelect(
      _pendingSql,
      readsFrom: _allSyncedTables,
    ).getSingle();
    return row.read<int>('pending');
  }

  /// Drives the sync indicator. Ramesh can always see this.
  Stream<int> watchPendingCount() {
    return customSelect(
      _pendingSql,
      readsFrom: _allSyncedTables,
    ).watchSingle().map((row) => row.read<int>('pending'));
  }

  // --- settling a push -----------------------------------------------------

  /// Clears the dirty flag only if the row has not been edited since it was
  /// read for pushing. Without the `updated_at` guard, an edit made while the
  /// request was in flight would be marked as synced and never sent.
  Future<void> markPushed({
    required String table,
    required String id,
    required int pushedUpdatedAt,
    required int serverUpdatedAt,
  }) async {
    await customUpdate(
      'UPDATE $table SET is_dirty = 0, server_updated_at = ? '
      'WHERE id = ? AND updated_at = ?',
      variables: [
        Variable<int>(serverUpdatedAt),
        Variable<String>(id),
        Variable<int>(pushedUpdatedAt),
      ],
      updates: {..._tablesFor(table)},
      updateKind: UpdateKind.update,
    );
  }

  Set<TableInfo> get _allSyncedTables => {
        items,
        stockMovements,
        businessProfiles,
        customers,
        bills,
        billLines,
        billRevisions,
        ledgerEntries,
        payments,
      };

  Set<TableInfo> _tablesFor(String table) => switch (table) {
        SyncTables.items => {items},
        SyncTables.stockMovements => {stockMovements},
        SyncTables.businessProfiles => {businessProfiles},
        SyncTables.customers => {customers},
        SyncTables.bills => {bills},
        SyncTables.billLines => {billLines},
        SyncTables.billRevisions => {billRevisions},
        SyncTables.ledgerEntries => {ledgerEntries},
        SyncTables.payments => {payments},
        _ => const {},
      };

  // --- applying a pull -----------------------------------------------------

  /// True when the local row has unsynced edits, in which case a pulled
  /// version is discarded. One device writes at a time, so a dirty local row
  /// is by definition newer than anything the server can hand back.
  Future<bool> isLocallyDirty(String table, String id) async {
    final row = await customSelect(
      'SELECT is_dirty FROM $table WHERE id = ?',
      variables: [Variable<String>(id)],
      readsFrom: {..._tablesFor(table)},
    ).getSingleOrNull();
    if (row == null) return false;
    return row.read<int>('is_dirty') == 1;
  }

  Future<void> upsertPulledItem(ItemsCompanion row) =>
      into(items).insertOnConflictUpdate(row);

  Future<void> upsertPulledMovement(StockMovementsCompanion row) =>
      into(stockMovements).insertOnConflictUpdate(row);

  Future<void> upsertPulledProfile(BusinessProfilesCompanion row) =>
      into(businessProfiles).insertOnConflictUpdate(row);

  Future<void> upsertPulledCustomer(CustomersCompanion row) =>
      into(customers).insertOnConflictUpdate(row);

  Future<void> upsertPulledBill(BillsCompanion row) =>
      into(bills).insertOnConflictUpdate(row);

  Future<void> upsertPulledBillLine(BillLinesCompanion row) =>
      into(billLines).insertOnConflictUpdate(row);

  Future<void> upsertPulledBillRevision(BillRevisionsCompanion row) =>
      into(billRevisions).insertOnConflictUpdate(row);

  Future<void> upsertPulledLedgerEntry(LedgerEntriesCompanion row) =>
      into(ledgerEntries).insertOnConflictUpdate(row);

  Future<void> upsertPulledPayment(PaymentsCompanion row) =>
      into(payments).insertOnConflictUpdate(row);

  // --- cursors -------------------------------------------------------------

  Future<int> cursorFor(String table) async {
    final row = await (select(syncStates)
          ..where((t) => t.entity.equals(table)))
        .getSingleOrNull();
    return row?.lastCursor ?? 0;
  }

  Future<void> setCursor(String table, int cursor) async {
    await into(syncStates).insertOnConflictUpdate(
      SyncStatesCompanion.insert(
        entity: table,
        lastCursor: Value(cursor),
        lastRunAt: Value(_clock.nowMillis()),
      ),
    );
  }

  Future<void> recordError(String table, String? error) async {
    await into(syncStates).insertOnConflictUpdate(
      SyncStatesCompanion.insert(
        entity: table,
        lastRunAt: Value(_clock.nowMillis()),
        lastError: Value(error),
      ),
    );
  }

  Future<int?> lastSyncedAt() async {
    final rows = await select(syncStates).get();
    final stamps = rows.map((r) => r.lastRunAt).nonNulls.toList();
    if (stamps.isEmpty) return null;
    stamps.sort();
    return stamps.last;
  }

  // --- the debugging trail -------------------------------------------------

  static const int _logCap = 1000;

  Future<void> log({
    required String direction,
    required String table,
    required int rowCount,
    required bool ok,
    String? detail,
  }) async {
    await into(syncLogs).insert(
      SyncLogsCompanion.insert(
        at: _clock.nowMillis(),
        direction: direction,
        entity: table,
        rowCount: Value(rowCount),
        ok: ok,
        detail: Value(detail),
      ),
    );
    await customStatement(
      'DELETE FROM sync_logs WHERE id <= '
      '(SELECT MAX(id) FROM sync_logs) - $_logCap',
    );
  }

  Stream<List<SyncLog>> watchLog({int limit = 100}) {
    return (select(syncLogs)
          ..orderBy([
            (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
          ])
          ..limit(limit))
        .watch();
  }

  /// Rows created before a Supabase project existed belong to a placeholder
  /// user. When a real account signs in for the first time it claims them,
  /// and they are marked dirty so they reach the server.
  Future<int> claimLocalRows({
    required String fromUserId,
    required String toUserId,
  }) async {
    if (fromUserId == toUserId) return 0;
    var claimed = 0;
    await transaction(() async {
      for (final table in SyncTables.pushOrder) {
        claimed += await customUpdate(
          'UPDATE $table SET user_id = ?, is_dirty = 1, server_updated_at = NULL '
          'WHERE user_id = ?',
          variables: [Variable<String>(toUserId), Variable<String>(fromUserId)],
          updates: {..._tablesFor(table)},
          updateKind: UpdateKind.update,
        );
      }
      // Cursors belong to the old identity's view of the server.
      await delete(syncStates).go();
    });
    return claimed;
  }

  /// Signing out must not leave one shop's data on screen for the next login.
  Future<void> wipeAll() async {
    await transaction(() async {
      // Reverse of the push order: children before parents.
      await delete(billRevisions).go();
      await delete(payments).go();
      await delete(ledgerEntries).go();
      await delete(stockMovements).go();
      await delete(billLines).go();
      await delete(bills).go();
      await delete(customers).go();
      await delete(items).go();
      await delete(businessProfiles).go();
      await delete(syncStates).go();
      await delete(syncLogs).go();
    });
  }
}

/// One line a bill is about to be saved with.
class BillLineDraft {
  const BillLineDraft({
    required this.itemId,
    required this.name,
    required this.unit,
    required this.qty,
    required this.unitPrice,
    this.unitCost = 0,
  });

  final String? itemId;
  final String name;
  final String unit;

  /// Thousandths.
  final int qty;

  /// Paise.
  final int unitPrice;

  /// Paise. What it cost Ramesh, carried so profit stays traceable.
  final int unitCost;

  int get total => lineTotal(qtyThousandths: qty, unitPricePaise: unitPrice);

  Map<String, dynamic> toSnapshot() => {
        'item_id': itemId,
        'name': name,
        'unit': unit,
        'qty': qty,
        'unit_price': unitPrice,
        'unit_cost': unitCost,
        'line_total': total,
      };
}

/// The only thing allowed to write ledger entries and customer balances.
///
/// Same discipline as stock: every write appends to the ledger and moves the
/// cached balance in one transaction, and [rebuildBalanceCache] proves the two
/// still agree.
@DriftAccessor(tables: [Customers, LedgerEntries, Payments])
class PartyDao extends DatabaseAccessor<AppDatabase> with _$PartyDaoMixin {
  PartyDao(super.db);

  Clock get _clock => attachedDatabase.clock;

  // --- reads ---------------------------------------------------------------

  Stream<List<Customer>> watchCustomers({String search = ''}) {
    final query = select(customers)..where((t) => t.deletedAt.isNull());
    final term = search.trim();
    if (term.isNotEmpty) {
      final pattern = '%${term.toLowerCase()}%';
      query.where((t) => t.name.lower().like(pattern) | t.phone.like(pattern));
    }
    query.orderBy([(t) => OrderingTerm(expression: t.name)]);
    return query.watch();
  }

  Future<Customer?> findCustomer(String id) =>
      (select(customers)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<Customer?> watchCustomer(String id) =>
      (select(customers)..where((t) => t.id.equals(id))).watchSingleOrNull();

  /// Newest first. This is what makes a balance openable.
  Stream<List<LedgerEntry>> watchLedger(String customerId) {
    final query = select(ledgerEntries)
      ..where((t) =>
          t.accountType.equals(LedgerAccount.customer.wire) &
          t.accountId.equals(customerId))
      ..orderBy([
        (t) => OrderingTerm(expression: t.occurredAt, mode: OrderingMode.desc),
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
      ]);
    return query.watch();
  }

  /// The authoritative balance, computed rather than read from the cache.
  Future<int> balanceFromLedger(String customerId) async {
    final sum = ledgerEntries.amount.sum();
    final row = await (selectOnly(ledgerEntries)
          ..addColumns([sum])
          ..where(ledgerEntries.accountType.equals(LedgerAccount.customer.wire) &
              ledgerEntries.accountId.equals(customerId)))
        .getSingle();
    return row.read(sum) ?? 0;
  }

  /// What the shop is owed in total, for the dashboard.
  Stream<int> watchTotalReceivable() {
    return customSelect(
      'SELECT COALESCE(SUM(balance), 0) AS owed FROM customers '
      'WHERE deleted_at IS NULL AND balance > 0',
      readsFrom: {customers},
    ).watchSingle().map((row) => row.read<int>('owed'));
  }

  // --- writes --------------------------------------------------------------

  Future<String> createCustomer({
    required String userId,
    required String name,
    String? phone,
    String? address,
    String? note,
    int openingBalance = 0,
  }) async {
    final id = newId();
    final now = _clock.nowMillis();

    await transaction(() async {
      await into(customers).insert(
        CustomersCompanion.insert(
          id: id,
          userId: userId,
          createdAt: now,
          updatedAt: now,
          name: name,
          phone: Value(phone),
          address: Value(address),
          note: Value(note),
        ),
      );
      if (openingBalance != 0) {
        // An opening balance is a ledger entry, not a column, for the same
        // reason opening stock is a movement: correcting it later must leave
        // a trace rather than overwrite what was there.
        await addLedgerEntry(
          userId: userId,
          account: LedgerAccount.customer,
          accountId: id,
          amount: openingBalance,
          reason: LedgerReason.opening,
          occurredAt: now,
        );
      }
    });

    return id;
  }

  Future<void> updateCustomer({
    required String id,
    String? name,
    String? phone,
    String? address,
    String? note,
  }) async {
    final now = _clock.nowMillis();
    await (update(customers)..where((t) => t.id.equals(id))).write(
      CustomersCompanion(
        name: name == null ? const Value.absent() : Value(name),
        phone: phone == null ? const Value.absent() : Value(phone),
        address: address == null ? const Value.absent() : Value(address),
        note: note == null ? const Value.absent() : Value(note),
        updatedAt: Value(now),
        isDirty: const Value(true),
      ),
    );
  }

  Future<void> setCustomerDeleted(String id, {required bool deleted}) async {
    final now = _clock.nowMillis();
    await (update(customers)..where((t) => t.id.equals(id))).write(
      CustomersCompanion(
        deletedAt: deleted ? Value(now) : const Value(null),
        updatedAt: Value(now),
        isDirty: const Value(true),
      ),
    );
  }

  /// The single entry point for changing what anyone owes.
  Future<String> addLedgerEntry({
    required String userId,
    required LedgerAccount account,
    String? accountId,
    required int amount,
    required LedgerReason reason,
    String? sourceType,
    String? sourceId,
    int? occurredAt,
    String? note,
  }) async {
    final id = newId();
    final now = _clock.nowMillis();

    await into(ledgerEntries).insert(
      LedgerEntriesCompanion.insert(
        id: id,
        userId: userId,
        createdAt: now,
        updatedAt: now,
        accountType: account.wire,
        accountId: Value(accountId),
        amount: amount,
        reason: reason.wire,
        sourceType: Value(sourceType),
        sourceId: Value(sourceId),
        occurredAt: occurredAt ?? now,
        note: Value(note),
      ),
    );

    if (account == LedgerAccount.customer && accountId != null) {
      // The cache moves with the ledger, in the same transaction, or not at
      // all. `balance` is local-only and never pushed, so this is not a sync
      // event and must not touch updated_at or is_dirty.
      await customUpdate(
        'UPDATE customers SET balance = balance + ? WHERE id = ?',
        variables: [Variable<int>(amount), Variable<String>(accountId)],
        updates: {customers},
        updateKind: UpdateKind.update,
      );
    }

    return id;
  }

  /// Recomputes every cached balance from the ledger. Returns how many were
  /// wrong.
  Future<int> rebuildBalanceCache() {
    return customUpdate(
      '''
      UPDATE customers
         SET balance = COALESCE((
               SELECT SUM(l.amount) FROM ledger_entries l
                WHERE l.account_type = 'customer' AND l.account_id = customers.id), 0)
       WHERE balance != COALESCE((
               SELECT SUM(l.amount) FROM ledger_entries l
                WHERE l.account_type = 'customer' AND l.account_id = customers.id), 0)
      ''',
      updates: {customers},
      updateKind: UpdateKind.update,
    );
  }
}

/// The only thing allowed to create, revise or delete a bill.
///
/// Saving a bill is one transaction that writes the bill, its lines, a stock
/// movement per line, and the ledger entries behind the money. Nothing else in
/// the app may write those four things for a bill, which is what keeps stock
/// and balances honest.
@DriftAccessor(tables: [
  Bills,
  BillLines,
  BillRevisions,
  Payments,
  LedgerEntries,
  Customers,
  Items,
  StockMovements,
  BusinessProfiles,
])
class BillingDao extends DatabaseAccessor<AppDatabase> with _$BillingDaoMixin {
  BillingDao(super.db);

  Clock get _clock => attachedDatabase.clock;
  InventoryDao get _inventory => InventoryDao(attachedDatabase);
  PartyDao get _parties => PartyDao(attachedDatabase);

  // --- reads ---------------------------------------------------------------

  Stream<List<Bill>> watchBills({String search = ''}) {
    final query = select(bills)..where((t) => t.deletedAt.isNull());
    final term = search.trim();
    if (term.isNotEmpty) {
      final pattern = '%${term.toLowerCase()}%';
      query.where((t) => t.customerName.lower().like(pattern));
    }
    query.orderBy([
      (t) => OrderingTerm(expression: t.occurredAt, mode: OrderingMode.desc),
      (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
    ]);
    return query.watch();
  }

  Stream<Bill?> watchBill(String id) =>
      (select(bills)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<Bill?> findBill(String id) =>
      (select(bills)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<List<BillLine>> watchLines(String billId) {
    final query = select(billLines)
      ..where((t) => t.billId.equals(billId) & t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm(expression: t.position)]);
    return query.watch();
  }

  Future<List<BillLine>> linesFor(String billId) =>
      (select(billLines)
            ..where((t) => t.billId.equals(billId) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm(expression: t.position)]))
          .get();

  Stream<List<BillRevision>> watchRevisions(String billId) {
    final query = select(billRevisions)
      ..where((t) => t.billId.equals(billId))
      ..orderBy([
        (t) => OrderingTerm(expression: t.revision, mode: OrderingMode.desc),
      ]);
    return query.watch();
  }

  Stream<List<Payment>> watchPayments(String billId) =>
      (select(payments)
            ..where((t) => t.billId.equals(billId) & t.deletedAt.isNull())
            ..orderBy([(t) => OrderingTerm(expression: t.occurredAt)]))
          .watch();

  /// What a bill has actually been paid, computed rather than cached.
  Future<int> paidFromPayments(String billId) async {
    final sum = payments.amount.sum();
    final row = await (selectOnly(payments)
          ..addColumns([sum])
          ..where(payments.billId.equals(billId) & payments.deletedAt.isNull()))
        .getSingle();
    return row.read(sum) ?? 0;
  }

  // --- writes --------------------------------------------------------------

  /// Saves a new bill and everything it causes.
  ///
  /// [paid] defaults the common case — a cash sale over the counter. Credit
  /// requires a customer, because an unpaid walk-in is a debt with nobody
  /// attached to it.
  Future<String> saveBill({
    required String userId,
    required List<BillLineDraft> lines,
    String? customerId,
    String? customerName,
    Discount discount = const Discount.none(),
    bool paid = true,
    int? amountPaid,
    String paymentMethod = 'cash',
    int? occurredAt,
    String? note,
  }) async {
    if (lines.isEmpty) {
      throw ArgumentError('A bill needs at least one line');
    }
    if (!paid && customerId == null) {
      throw ArgumentError('A credit bill needs a customer to owe the money');
    }

    final id = newId();
    final now = _clock.nowMillis();
    final when = occurredAt ?? now;

    await transaction(() async {
      final profile = await ensureProfile(userId);
      final number = profile.invoiceNextNumber;
      await _bumpInvoiceNumber(profile, number + 1, now);

      final totals = totalsFor(
        lineTotals: lines.map((l) => l.total),
        discount: discount,
      );

      await into(bills).insert(
        BillsCompanion.insert(
          id: id,
          userId: userId,
          createdAt: now,
          updatedAt: now,
          number: number,
          numberPrefix: Value(profile.invoicePrefix),
          customerId: Value(customerId),
          customerName: Value(customerName),
          subtotal: Value(totals.subtotal),
          discountType: Value(discount.type.wire),
          discountValue: Value(discount.value),
          discountAmount: Value(totals.discount),
          total: Value(totals.total),
          occurredAt: when,
          note: Value(note),
        ),
      );

      await _writeLinesAndEffects(
        userId: userId,
        billId: id,
        lines: lines,
        total: totals.total,
        customerId: customerId,
        occurredAt: when,
        now: now,
      );

      final settle = paid ? (amountPaid ?? totals.total) : (amountPaid ?? 0);
      if (settle > 0) {
        await recordPayment(
          userId: userId,
          billId: id,
          customerId: customerId,
          amount: settle,
          method: paymentMethod,
          occurredAt: when,
        );
      }
    });

    return id;
  }

  /// Replaces a bill's contents, leaving a trace.
  ///
  /// The previous version is snapshotted, every movement and sale ledger entry
  /// it caused is reversed by an opposing row, and the new version is written.
  /// Payments are deliberately left alone — the money really was received.
  Future<void> reviseBill({
    required String userId,
    required String billId,
    required List<BillLineDraft> lines,
    String? customerId,
    String? customerName,
    Discount discount = const Discount.none(),
    int? occurredAt,
    String? note,
  }) async {
    if (lines.isEmpty) {
      throw ArgumentError('A bill needs at least one line');
    }

    final now = _clock.nowMillis();

    await transaction(() async {
      final bill = await findBill(billId);
      if (bill == null) throw StateError('No such bill: $billId');

      final oldLines = await linesFor(billId);
      await _snapshot(userId: userId, bill: bill, lines: oldLines, now: now);
      await _reverseEffects(
        userId: userId,
        bill: bill,
        lines: oldLines,
        now: now,
        alsoReversePayments: false,
      );

      final totals = totalsFor(
        lineTotals: lines.map((l) => l.total),
        discount: discount,
      );
      final when = occurredAt ?? bill.occurredAt;

      await (update(bills)..where((t) => t.id.equals(billId))).write(
        BillsCompanion(
          customerId: Value(customerId),
          customerName: Value(customerName),
          subtotal: Value(totals.subtotal),
          discountType: Value(discount.type.wire),
          discountValue: Value(discount.value),
          discountAmount: Value(totals.discount),
          total: Value(totals.total),
          occurredAt: Value(when),
          note: Value(note),
          revision: Value(bill.revision + 1),
          updatedAt: Value(now),
          isDirty: const Value(true),
        ),
      );

      await _writeLinesAndEffects(
        userId: userId,
        billId: billId,
        lines: lines,
        total: totals.total,
        customerId: customerId,
        occurredAt: when,
        now: now,
      );
    });
  }

  /// Undoes a bill completely: stock comes back, the debt disappears, and any
  /// payment against it is reversed too. The invoice number stays burned —
  /// gaps in the sequence are correct, reused numbers are how disputes start.
  Future<void> deleteBill({
    required String userId,
    required String billId,
  }) async {
    final now = _clock.nowMillis();

    await transaction(() async {
      final bill = await findBill(billId);
      if (bill == null || bill.deletedAt != null) return;

      final lines = await linesFor(billId);
      await _reverseEffects(
        userId: userId,
        bill: bill,
        lines: lines,
        now: now,
        alsoReversePayments: true,
      );

      await (update(billLines)..where((t) => t.billId.equals(billId))).write(
        BillLinesCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          isDirty: const Value(true),
        ),
      );
      await (update(bills)..where((t) => t.id.equals(billId))).write(
        BillsCompanion(
          deletedAt: Value(now),
          amountPaid: const Value(0),
          updatedAt: Value(now),
          isDirty: const Value(true),
        ),
      );
    });
  }

  Future<void> restoreBill({
    required String userId,
    required String billId,
  }) async {
    final now = _clock.nowMillis();
    await transaction(() async {
      final bill = await findBill(billId);
      if (bill == null || bill.deletedAt == null) return;

      await (update(billLines)..where((t) => t.billId.equals(billId))).write(
        BillLinesCompanion(
          deletedAt: const Value(null),
          updatedAt: Value(now),
          isDirty: const Value(true),
        ),
      );
      await (update(bills)..where((t) => t.id.equals(billId))).write(
        BillsCompanion(
          deletedAt: const Value(null),
          updatedAt: Value(now),
          isDirty: const Value(true),
        ),
      );

      final lines = await linesFor(billId);
      await _applyEffects(
        userId: userId,
        billId: billId,
        lines: lines.map((l) => BillLineDraft(
              itemId: l.itemId,
              name: l.name,
              unit: l.unit,
              qty: l.qty,
              unitPrice: l.unitPrice,
              unitCost: l.unitCost,
            )),
        total: bill.total,
        customerId: bill.customerId,
        occurredAt: bill.occurredAt,
      );
    });
  }

  Future<String> recordPayment({
    required String userId,
    required int amount,
    String? billId,
    String? customerId,
    String method = 'cash',
    int? occurredAt,
    String? note,
  }) async {
    final id = newId();
    final now = _clock.nowMillis();
    final when = occurredAt ?? now;

    await transaction(() async {
      await into(payments).insert(
        PaymentsCompanion.insert(
          id: id,
          userId: userId,
          createdAt: now,
          updatedAt: now,
          customerId: Value(customerId),
          billId: Value(billId),
          amount: amount,
          method: Value(method),
          occurredAt: when,
          note: Value(note),
        ),
      );

      // Money in.
      await _parties.addLedgerEntry(
        userId: userId,
        account: method == 'cash' ? LedgerAccount.cash : LedgerAccount.bank,
        amount: amount,
        reason: LedgerReason.paymentIn,
        sourceType: 'payment',
        sourceId: id,
        occurredAt: when,
      );

      // And the customer owes that much less.
      if (customerId != null) {
        await _parties.addLedgerEntry(
          userId: userId,
          account: LedgerAccount.customer,
          accountId: customerId,
          amount: -amount,
          reason: LedgerReason.paymentIn,
          sourceType: 'payment',
          sourceId: id,
          occurredAt: when,
        );
      }

      if (billId != null) {
        await customUpdate(
          'UPDATE bills SET amount_paid = amount_paid + ? WHERE id = ?',
          variables: [Variable<int>(amount), Variable<String>(billId)],
          updates: {bills},
          updateKind: UpdateKind.update,
        );
      }
    });

    return id;
  }

  /// Recomputes every bill's cached amount_paid from its payments.
  Future<int> rebuildAmountPaidCache() {
    return customUpdate(
      '''
      UPDATE bills
         SET amount_paid = COALESCE((
               SELECT SUM(p.amount) FROM payments p
                WHERE p.bill_id = bills.id AND p.deleted_at IS NULL), 0)
       WHERE amount_paid != COALESCE((
               SELECT SUM(p.amount) FROM payments p
                WHERE p.bill_id = bills.id AND p.deleted_at IS NULL), 0)
      ''',
      updates: {bills},
      updateKind: UpdateKind.update,
    );
  }

  // --- internals -----------------------------------------------------------

  Future<void> _writeLinesAndEffects({
    required String userId,
    required String billId,
    required List<BillLineDraft> lines,
    required int total,
    required String? customerId,
    required int occurredAt,
    required int now,
  }) async {
    var position = 0;
    for (final line in lines) {
      await into(billLines).insert(
        BillLinesCompanion.insert(
          id: newId(),
          userId: userId,
          createdAt: now,
          updatedAt: now,
          billId: billId,
          itemId: Value(line.itemId),
          name: line.name,
          unit: Value(line.unit),
          qty: line.qty,
          unitPrice: line.unitPrice,
          unitCost: Value(line.unitCost),
          lineTotal: line.total,
          position: Value(position++),
        ),
      );
    }

    await _applyEffects(
      userId: userId,
      billId: billId,
      lines: lines,
      total: total,
      customerId: customerId,
      occurredAt: occurredAt,
    );
  }

  /// Stock out, money owed. Split out so restoring a bill can replay it.
  Future<void> _applyEffects({
    required String userId,
    required String billId,
    required Iterable<BillLineDraft> lines,
    required int total,
    required String? customerId,
    required int occurredAt,
  }) async {
    for (final line in lines) {
      if (line.itemId == null) continue;
      await _inventory.applyMovement(
        userId: userId,
        itemId: line.itemId!,
        qtyDelta: -line.qty,
        reason: MovementReason.sale,
        unitCost: line.unitCost,
        source: MovementSource.bill,
        sourceId: billId,
        occurredAt: occurredAt,
      );
    }

    await _parties.addLedgerEntry(
      userId: userId,
      account: LedgerAccount.sales,
      amount: total,
      reason: LedgerReason.sale,
      sourceType: 'bill',
      sourceId: billId,
      occurredAt: occurredAt,
    );

    if (customerId != null) {
      await _parties.addLedgerEntry(
        userId: userId,
        account: LedgerAccount.customer,
        accountId: customerId,
        amount: total,
        reason: LedgerReason.sale,
        sourceType: 'bill',
        sourceId: billId,
        occurredAt: occurredAt,
      );
    }
  }

  /// Writes opposing rows for everything a bill caused. Nothing is edited or
  /// deleted — the original rows stay exactly as they were.
  Future<void> _reverseEffects({
    required String userId,
    required Bill bill,
    required List<BillLine> lines,
    required int now,
    required bool alsoReversePayments,
  }) async {
    for (final line in lines) {
      if (line.itemId == null) continue;
      await _inventory.applyMovement(
        userId: userId,
        itemId: line.itemId!,
        qtyDelta: line.qty,
        reason: MovementReason.reversal,
        unitCost: line.unitCost,
        source: MovementSource.bill,
        sourceId: bill.id,
        occurredAt: now,
        note: 'Reversal of bill ${invoiceLabel(prefix: bill.numberPrefix, number: bill.number)}',
      );
    }

    final entries = await (select(ledgerEntries)
          ..where((t) =>
              t.sourceType.equals('bill') &
              t.sourceId.equals(bill.id) &
              t.reason.equals(LedgerReason.sale.wire)))
        .get();

    for (final entry in entries) {
      await _parties.addLedgerEntry(
        userId: userId,
        account: LedgerAccount.fromWire(entry.accountType),
        accountId: entry.accountId,
        amount: -entry.amount,
        reason: LedgerReason.saleReversal,
        sourceType: 'bill',
        sourceId: bill.id,
        occurredAt: now,
      );
    }

    if (!alsoReversePayments) return;

    final paid = await (select(payments)
          ..where((t) => t.billId.equals(bill.id) & t.deletedAt.isNull()))
        .get();

    for (final payment in paid) {
      await _parties.addLedgerEntry(
        userId: userId,
        account:
            payment.method == 'cash' ? LedgerAccount.cash : LedgerAccount.bank,
        amount: -payment.amount,
        reason: LedgerReason.paymentInReversal,
        sourceType: 'payment',
        sourceId: payment.id,
        occurredAt: now,
      );
      if (payment.customerId != null) {
        await _parties.addLedgerEntry(
          userId: userId,
          account: LedgerAccount.customer,
          accountId: payment.customerId,
          amount: payment.amount,
          reason: LedgerReason.paymentInReversal,
          sourceType: 'payment',
          sourceId: payment.id,
          occurredAt: now,
        );
      }
      await (update(payments)..where((t) => t.id.equals(payment.id))).write(
        PaymentsCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
          isDirty: const Value(true),
        ),
      );
    }
  }

  Future<void> _snapshot({
    required String userId,
    required Bill bill,
    required List<BillLine> lines,
    required int now,
  }) async {
    final snapshot = jsonEncode({
      'revision': bill.revision,
      'number': bill.number,
      'number_prefix': bill.numberPrefix,
      'customer_id': bill.customerId,
      'customer_name': bill.customerName,
      'subtotal': bill.subtotal,
      'discount_type': bill.discountType,
      'discount_value': bill.discountValue,
      'discount_amount': bill.discountAmount,
      'total': bill.total,
      'occurred_at': bill.occurredAt,
      'note': bill.note,
      'lines': [
        for (final l in lines)
          {
            'item_id': l.itemId,
            'name': l.name,
            'unit': l.unit,
            'qty': l.qty,
            'unit_price': l.unitPrice,
            'unit_cost': l.unitCost,
            'line_total': l.lineTotal,
          },
      ],
    });

    await into(billRevisions).insert(
      BillRevisionsCompanion.insert(
        id: newId(),
        userId: userId,
        createdAt: now,
        updatedAt: now,
        billId: bill.id,
        revision: bill.revision,
        snapshot: snapshot,
        replacedAt: now,
      ),
    );

    await (update(billLines)..where((t) => t.billId.equals(bill.id))).write(
      BillLinesCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        isDirty: const Value(true),
      ),
    );
  }

  Stream<BusinessProfile?> watchProfile(String userId) =>
      (select(businessProfiles)
            ..where((t) => t.userId.equals(userId))
            ..limit(1))
          .watchSingleOrNull();

  Future<void> updateProfile({
    required String userId,
    String? shopName,
    String? ownerName,
    String? phone,
    String? address,
    String? invoicePrefix,
  }) async {
    final profile = await ensureProfile(userId);
    final now = _clock.nowMillis();
    await (update(businessProfiles)..where((t) => t.id.equals(profile.id)))
        .write(
      BusinessProfilesCompanion(
        shopName: shopName == null ? const Value.absent() : Value(shopName),
        ownerName: ownerName == null ? const Value.absent() : Value(ownerName),
        phone: phone == null ? const Value.absent() : Value(phone),
        address: address == null ? const Value.absent() : Value(address),
        invoicePrefix: invoicePrefix == null
            ? const Value.absent()
            : Value(invoicePrefix),
        updatedAt: Value(now),
        isDirty: const Value(true),
      ),
    );
  }

  Future<BusinessProfile> ensureProfile(String userId) async {
    final existing = await (select(businessProfiles)
          ..where((t) => t.userId.equals(userId))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) return existing;

    final now = _clock.nowMillis();
    final id = newId();
    await into(businessProfiles).insert(
      BusinessProfilesCompanion.insert(
        id: id,
        userId: userId,
        createdAt: now,
        updatedAt: now,
      ),
    );
    return (select(businessProfiles)..where((t) => t.id.equals(id)))
        .getSingle();
  }

  Future<void> _bumpInvoiceNumber(
    BusinessProfile profile,
    int next,
    int now,
  ) async {
    await (update(businessProfiles)..where((t) => t.id.equals(profile.id)))
        .write(
      BusinessProfilesCompanion(
        invoiceNextNumber: Value(next),
        updatedAt: Value(now),
        isDirty: const Value(true),
      ),
    );
  }
}
