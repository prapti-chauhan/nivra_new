import 'package:drift/drift.dart';

import '../../domain/billing.dart';
import '../../domain/reports.dart';
import '../db/database.dart';

/// Everything the reports read. Read-only: nothing here may write a row, which
/// is what lets a report be trusted not to have changed the numbers it shows.
///
/// Deliberately a plain class over [AppDatabase] rather than a Drift accessor,
/// so it needs no code generation and cannot reach for an insert by habit.
class ReportQueries {
  ReportQueries(this._db);

  final AppDatabase _db;

  /// Every live bill in [range] with the lines it was sold from.
  ///
  /// A left join, so a bill whose lines have not arrived yet still counts
  /// toward sales instead of vanishing from the total.
  Stream<List<BillProfit>> watchBillProfits(DateRange range) {
    final bills = _db.bills;
    final lines = _db.billLines;

    final query = _db.select(bills).join([
      leftOuterJoin(
        lines,
        lines.billId.equalsExp(bills.id) & lines.deletedAt.isNull(),
      ),
    ])
      ..where(
        bills.deletedAt.isNull() &
            bills.occurredAt.isBiggerOrEqualValue(range.fromMillis) &
            bills.occurredAt.isSmallerThanValue(range.toMillis),
      )
      ..orderBy([
        OrderingTerm.desc(bills.occurredAt),
        OrderingTerm.desc(bills.createdAt),
        OrderingTerm.asc(lines.position),
      ]);

    return query.watch().map((rows) {
      final order = <String>[];
      final byBill = <String, Bill>{};
      final linesByBill = <String, List<ProfitLine>>{};

      for (final row in rows) {
        final bill = row.readTable(bills);
        if (!byBill.containsKey(bill.id)) {
          byBill[bill.id] = bill;
          order.add(bill.id);
        }
        final line = row.readTableOrNull(lines);
        final list = linesByBill.putIfAbsent(bill.id, () => <ProfitLine>[]);
        if (line != null) {
          list.add(ProfitLine(
            id: line.id,
            name: line.name,
            unit: line.unit,
            qtyThousandths: line.qty,
            unitPricePaise: line.unitPrice,
            unitCostPaise: line.unitCost,
            lineTotalPaise: line.lineTotal,
            originalUnitCostPaise: line.originalUnitCost,
          ));
        }
      }

      return [
        for (final id in order)
          BillProfit(
            billId: id,
            label: invoiceLabel(
              prefix: byBill[id]!.numberPrefix,
              number: byBill[id]!.number,
            ),
            customerName: byBill[id]!.customerName,
            occurredAt: byBill[id]!.occurredAt,
            totalPaise: byBill[id]!.total,
            lines: linesByBill[id]!,
          ),
      ];
    });
  }

  /// Every live expense, income and transfer dated inside [range], newest
  /// first. Deleted entries are gone from it; an edited one appears once, at its
  /// current figures.
  Stream<List<MoneyEntry>> watchMoneyEntries(DateRange range) {
    final query = _db.select(_db.moneyEntries)
      ..where((t) =>
          t.deletedAt.isNull() &
          t.occurredAt.isBiggerOrEqualValue(range.fromMillis) &
          t.occurredAt.isSmallerThanValue(range.toMillis))
      ..orderBy([
        (t) => OrderingTerm.desc(t.occurredAt),
        (t) => OrderingTerm.desc(t.createdAt),
      ]);
    return query.watch();
  }

  /// Customers who owe Ramesh, biggest first.
  Stream<List<Customer>> watchOwedToYou() {
    final query = _db.select(_db.customers)
      ..where((t) => t.deletedAt.isNull() & t.balance.isBiggerThanValue(0))
      ..orderBy([(t) => OrderingTerm.desc(t.balance)]);
    return query.watch();
  }

  /// Suppliers Ramesh owes, biggest first. Their stored balance is negative —
  /// see `payableFromBalance`.
  Stream<List<Supplier>> watchYouOwe() {
    final query = _db.select(_db.suppliers)
      ..where((t) => t.deletedAt.isNull() & t.balance.isSmallerThanValue(0))
      ..orderBy([(t) => OrderingTerm.asc(t.balance)]);
    return query.watch();
  }

  /// Every live item, for the stock-on-hand report.
  Stream<List<Item>> watchStockItems() {
    final query = _db.select(_db.items)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.asc(t.name)]);
    return query.watch();
  }

  /// Items at or under the threshold Ramesh set, with how fast each has been
  /// selling.
  ///
  /// Sales are counted by `created_at`, not `occurred_at`. Editing a bill
  /// writes a reversal stamped "now" and re-applies the sale at the bill's
  /// original date; counting by `occurred_at` would keep the reversal and drop
  /// the re-sale, and an edited bill would read as negative demand.
  /// Only movements caused by a bill count — a deleted purchase is also a
  /// "reversal", and is not a sale.
  Stream<List<ReorderEntry>> watchReorder({
    required int sinceMillis,
    required int windowDays,
  }) {
    return _db
        .customSelect(
          '''
          SELECT i.id, i.name, i.unit, i.stock_qty, i.low_stock_threshold,
            COALESCE((
              SELECT -SUM(m.qty_delta) FROM stock_movements m
              WHERE m.item_id = i.id
                AND m.source_type = 'bill'
                AND m.created_at >= ?
            ), 0) AS sold
          FROM items i
          WHERE i.deleted_at IS NULL
            AND i.low_stock_threshold IS NOT NULL
            AND i.stock_qty <= i.low_stock_threshold
          ''',
          variables: [Variable<int>(sinceMillis)],
          readsFrom: {_db.items, _db.stockMovements},
        )
        .watch()
        .map((rows) {
      final entries = [
        for (final row in rows)
          ReorderEntry(
            itemId: row.read<String>('id'),
            name: row.read<String>('name'),
            unit: row.read<String>('unit'),
            qtyThousandths: row.read<int>('stock_qty'),
            thresholdThousandths: row.read<int>('low_stock_threshold'),
            // A net negative means more was reversed than sold in the window;
            // that is not demand, so it reads as none.
            soldInWindowThousandths:
                row.read<int>('sold') < 0 ? 0 : row.read<int>('sold'),
            windowDays: windowDays,
          ),
      ];
      entries.sort(compareUrgency);
      return entries;
    });
  }
}
