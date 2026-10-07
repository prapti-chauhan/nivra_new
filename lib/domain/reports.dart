/// Report arithmetic. Pure Dart — no Drift, no Flutter, no clock.
///
/// Costing is the last purchase cost, frozen onto each bill line at the moment
/// of sale (docs/decisions.md D18). That choice is what makes every figure here
/// checkable by hand: profit is a sum over lines, each line carries the cost it
/// was sold against, and nothing is recomputed afterwards — so a past month's
/// profit never moves.
library;

import 'billing.dart';

enum ReportPeriod {
  today('Today'),
  thisWeek('This week'),
  thisMonth('This month'),
  lastMonth('Last month');

  const ReportPeriod(this.label);
  final String label;
}

/// A half-open span of time, `[fromMillis, toMillis)`, in UTC epoch
/// milliseconds. Half-open so a bill stamped exactly at midnight belongs to one
/// period and never to two.
class DateRange {
  const DateRange(this.fromMillis, this.toMillis);

  final int fromMillis;
  final int toMillis;

  bool contains(int millis) => millis >= fromMillis && millis < toMillis;
}

/// The boundaries of [period] as the shop keeps its days: local midnight, not
/// UTC midnight. A bill rung up at 11pm belongs to that day for Ramesh.
///
/// Weeks start on Monday.
DateRange rangeFor(ReportPeriod period, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);

  DateTime from;
  DateTime to;
  switch (period) {
    case ReportPeriod.today:
      from = today;
      to = DateTime(today.year, today.month, today.day + 1);
    case ReportPeriod.thisWeek:
      from = DateTime(today.year, today.month, today.day - (today.weekday - 1));
      to = DateTime(from.year, from.month, from.day + 7);
    case ReportPeriod.thisMonth:
      from = DateTime(today.year, today.month, 1);
      to = DateTime(today.year, today.month + 1, 1);
    case ReportPeriod.lastMonth:
      from = DateTime(today.year, today.month - 1, 1);
      to = DateTime(today.year, today.month, 1);
  }
  return DateRange(from.millisecondsSinceEpoch, to.millisecondsSinceEpoch);
}

/// One line of a bill as profit sees it.
class ProfitLine {
  const ProfitLine({
    required this.name,
    required this.unit,
    required this.qtyThousandths,
    required this.unitPricePaise,
    required this.unitCostPaise,
    required this.lineTotalPaise,
  });

  final String name;
  final String unit;
  final int qtyThousandths;
  final int unitPricePaise;

  /// What this line was sold against. Frozen at billing.
  final int unitCostPaise;
  final int lineTotalPaise;

  /// Same rounding rule as the price side, so cost and revenue can never
  /// disagree by a paisa about the same quantity.
  int get costPaise =>
      lineTotal(qtyThousandths: qtyThousandths, unitPricePaise: unitCostPaise);

  /// A cost of zero is almost never true. It means the item was never given a
  /// purchase price, and counting it as free would overstate profit.
  bool get costUnknown => unitCostPaise <= 0;
}

class BillProfit {
  const BillProfit({
    required this.billId,
    required this.label,
    required this.customerName,
    required this.occurredAt,
    required this.totalPaise,
    required this.lines,
  });

  final String billId;
  final String label;
  final String? customerName;
  final int occurredAt;

  /// What the customer was charged, after any bill-level discount.
  final int totalPaise;
  final List<ProfitLine> lines;

  int get costPaise => lines.fold<int>(0, (sum, l) => sum + l.costPaise);

  /// Revenue is the bill total, not the sum of line totals, so a discount is
  /// taken out of profit rather than ignored.
  int get profitPaise => totalPaise - costPaise;

  /// A bill with no lines on this device yet — its lines may still be arriving
  /// from a sync — has an unknown cost as surely as a line with a zero. Better
  /// to flag it than to book the whole bill as profit.
  int get unknownCostLines =>
      lines.isEmpty ? 1 : lines.where((l) => l.costUnknown).length;
}

class ProfitSummary {
  const ProfitSummary({
    required this.billCount,
    required this.salesPaise,
    required this.costPaise,
    required this.unknownCostLines,
    required this.unknownCostBills,
  });

  static const empty = ProfitSummary(
    billCount: 0,
    salesPaise: 0,
    costPaise: 0,
    unknownCostLines: 0,
    unknownCostBills: 0,
  );

  final int billCount;
  final int salesPaise;
  final int costPaise;

  /// Lines sold with no cost on record. Above zero, profit is overstated by up
  /// to the revenue of those lines, and the screen says so.
  final int unknownCostLines;
  final int unknownCostBills;

  int get profitPaise => salesPaise - costPaise;
  bool get hasUnknownCost => unknownCostLines > 0;

  /// Whole percent of sales, or null when there were no sales to take a
  /// percentage of.
  int? get marginPercent =>
      salesPaise <= 0 ? null : (profitPaise * 100 / salesPaise).round();
}

ProfitSummary summarise(Iterable<BillProfit> bills) {
  var count = 0;
  var sales = 0;
  var cost = 0;
  var unknownLines = 0;
  var unknownBills = 0;
  for (final bill in bills) {
    count++;
    sales += bill.totalPaise;
    cost += bill.costPaise;
    final unknown = bill.unknownCostLines;
    unknownLines += unknown;
    if (unknown > 0) unknownBills++;
  }
  return ProfitSummary(
    billCount: count,
    salesPaise: sales,
    costPaise: cost,
    unknownCostLines: unknownLines,
    unknownCostBills: unknownBills,
  );
}

// ---------------------------------------------------------------------------
// Stock
// ---------------------------------------------------------------------------

/// What stock on hand is worth at the cost he last paid. Negative stock counts
/// as nothing rather than as a negative asset — a miscount on the shelf should
/// not shrink the figure below what is actually there.
int stockValuePaise({required int qtyThousandths, required int unitCostPaise}) {
  if (qtyThousandths <= 0 || unitCostPaise <= 0) return 0;
  return lineTotal(
    qtyThousandths: qtyThousandths,
    unitPricePaise: unitCostPaise,
  );
}

/// How many days the current stock lasts at the recent selling rate, or null
/// when nothing sold in the window and so there is no rate to speak of.
///
/// "12 left" is a number he has to interpret. "12 left, about 4 days" tells him
/// whether to order today or next week — which is the whole point of a warning.
int? daysOfStockLeft({
  required int qtyThousandths,
  required int soldInWindowThousandths,
  required int windowDays,
}) {
  if (windowDays <= 0 || soldInWindowThousandths <= 0) return null;
  if (qtyThousandths <= 0) return 0;
  final perDay = soldInWindowThousandths / windowDays;
  return (qtyThousandths / perDay).floor();
}

class ReorderEntry {
  const ReorderEntry({
    required this.itemId,
    required this.name,
    required this.unit,
    required this.qtyThousandths,
    required this.thresholdThousandths,
    required this.soldInWindowThousandths,
    required this.windowDays,
  });

  final String itemId;
  final String name;
  final String unit;
  final int qtyThousandths;
  final int thresholdThousandths;
  final int soldInWindowThousandths;
  final int windowDays;

  bool get isOut => qtyThousandths <= 0;

  int? get daysLeft => daysOfStockLeft(
        qtyThousandths: qtyThousandths,
        soldInWindowThousandths: soldInWindowThousandths,
        windowDays: windowDays,
      );
}

/// Most urgent first: out of stock, then fewest days left, then — for items
/// with no recent sales to judge by — the ones furthest under their threshold.
int compareUrgency(ReorderEntry a, ReorderEntry b) {
  if (a.isOut != b.isOut) return a.isOut ? -1 : 1;
  final ad = a.daysLeft;
  final bd = b.daysLeft;
  if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
  if (ad != null && bd == null) return -1;
  if (ad == null && bd != null) return 1;
  final aGap = a.thresholdThousandths - a.qtyThousandths;
  final bGap = b.thresholdThousandths - b.qtyThousandths;
  return bGap.compareTo(aGap);
}
