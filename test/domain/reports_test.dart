import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/domain/reports.dart';

int ms(DateTime d) => d.millisecondsSinceEpoch;

ProfitLine line({
  int qty = 1000,
  int price = 2500,
  int cost = 1800,
  String name = 'bolt',
}) =>
    ProfitLine(
      id: 'line-$name',
      name: name,
      unit: 'pcs',
      qtyThousandths: qty,
      unitPricePaise: price,
      unitCostPaise: cost,
      lineTotalPaise: (qty * price + 500) ~/ 1000,
    );

BillProfit bill({
  required int total,
  required List<ProfitLine> lines,
  String id = 'b1',
}) =>
    BillProfit(
      billId: id,
      label: 'INV-0001',
      customerName: null,
      occurredAt: 0,
      totalPaise: total,
      lines: lines,
    );

void main() {
  group('periods', () {
    // Wednesday 7 October 2026, mid-afternoon.
    final now = DateTime(2026, 10, 7, 15, 30);

    test('today is local midnight to local midnight', () {
      final r = rangeFor(ReportPeriod.today, now);
      expect(r.fromMillis, ms(DateTime(2026, 10, 7)));
      expect(r.toMillis, ms(DateTime(2026, 10, 8)));
    });

    test('a bill at 11:59pm is today and one at midnight is tomorrow', () {
      final r = rangeFor(ReportPeriod.today, now);
      expect(r.contains(ms(DateTime(2026, 10, 7, 23, 59, 59))), isTrue);
      expect(r.contains(ms(DateTime(2026, 10, 8))), isFalse);
      expect(r.contains(ms(DateTime(2026, 10, 7))), isTrue);
    });

    test('the week starts on Monday', () {
      final r = rangeFor(ReportPeriod.thisWeek, now);
      expect(r.fromMillis, ms(DateTime(2026, 10, 5)));
      expect(r.toMillis, ms(DateTime(2026, 10, 12)));
    });

    test('on a Monday the week starts that same day', () {
      final r = rangeFor(ReportPeriod.thisWeek, DateTime(2026, 10, 5, 9));
      expect(r.fromMillis, ms(DateTime(2026, 10, 5)));
    });

    test('on a Sunday the week started six days earlier', () {
      final r = rangeFor(ReportPeriod.thisWeek, DateTime(2026, 10, 11, 20));
      expect(r.fromMillis, ms(DateTime(2026, 10, 5)));
      expect(r.toMillis, ms(DateTime(2026, 10, 12)));
    });

    test('a week can span two months', () {
      final r = rangeFor(ReportPeriod.thisWeek, DateTime(2026, 10, 1, 9));
      expect(r.fromMillis, ms(DateTime(2026, 9, 28)));
      expect(r.toMillis, ms(DateTime(2026, 10, 5)));
    });

    test('this month runs to the first of the next', () {
      final r = rangeFor(ReportPeriod.thisMonth, now);
      expect(r.fromMillis, ms(DateTime(2026, 10, 1)));
      expect(r.toMillis, ms(DateTime(2026, 11, 1)));
    });

    test('december rolls into january', () {
      final r = rangeFor(ReportPeriod.thisMonth, DateTime(2026, 12, 20));
      expect(r.toMillis, ms(DateTime(2027, 1, 1)));
    });

    test('last month is the whole previous month', () {
      final r = rangeFor(ReportPeriod.lastMonth, now);
      expect(r.fromMillis, ms(DateTime(2026, 9, 1)));
      expect(r.toMillis, ms(DateTime(2026, 10, 1)));
    });

    test('last month in january is december of the year before', () {
      final r = rangeFor(ReportPeriod.lastMonth, DateTime(2027, 1, 15));
      expect(r.fromMillis, ms(DateTime(2026, 12, 1)));
      expect(r.toMillis, ms(DateTime(2027, 1, 1)));
    });

    test('february in a leap year has 29 days', () {
      final r = rangeFor(ReportPeriod.thisMonth, DateTime(2028, 2, 10));
      final days = (r.toMillis - r.fromMillis) / Duration.millisecondsPerDay;
      expect(days, 29);
    });
  });

  group('profit', () {
    test('a line is price minus the cost it was sold against', () {
      // 4 at Rs 25 sold against Rs 18: Rs 100 revenue, Rs 72 cost.
      final l = line(qty: 4000, price: 2500, cost: 1800);
      expect(l.costPaise, 7200);
      final b = bill(total: 10000, lines: [l]);
      expect(b.profitPaise, 2800);
    });

    test('cost rounds the same way revenue does', () {
      // 1.5 kg at Rs 10.33 is 1549.5 paise and must become 1550, not 1549.
      final l = line(qty: 1500, price: 1033, cost: 1033);
      expect(l.costPaise, 1550);
    });

    test('a bill discount comes out of profit instead of being ignored', () {
      // Lines total Rs 100, cost Rs 72, but a Rs 10 discount means the
      // customer paid Rs 90. Profit is 90 - 72, not 100 - 72.
      final b = bill(
        total: 9000,
        lines: [line(qty: 4000, price: 2500, cost: 1800)],
      );
      expect(b.profitPaise, 1800);
    });

    test('profit can be negative when something is sold under cost', () {
      final b = bill(
        total: 4000,
        lines: [line(qty: 4000, price: 1000, cost: 1800)],
      );
      expect(b.profitPaise, -3200);
    });

    test('a zero cost is flagged, not treated as free', () {
      final b = bill(total: 10000, lines: [line(cost: 0)]);
      expect(b.unknownCostLines, 1);
      expect(summarise([b]).hasUnknownCost, isTrue);
    });

    test('a bill with no lines yet is flagged rather than booked as profit', () {
      final b = bill(total: 10000, lines: const []);
      expect(b.unknownCostLines, 1);
    });

    test('a bill with known costs raises no flag', () {
      expect(summarise([bill(total: 2500, lines: [line()])]).hasUnknownCost,
          isFalse);
    });
  });

  group('summary', () {
    test('adds bills up', () {
      final s = summarise([
        bill(total: 10000, lines: [line(qty: 4000, price: 2500, cost: 1800)]),
        bill(
          id: 'b2',
          total: 5000,
          lines: [line(qty: 2000, price: 2500, cost: 1800)],
        ),
      ]);
      expect(s.billCount, 2);
      expect(s.salesPaise, 15000);
      expect(s.costPaise, 10800);
      expect(s.profitPaise, 4200);
    });

    test('counts how many bills carry an unknown cost', () {
      final s = summarise([
        bill(total: 1, lines: [line(cost: 0), line(cost: 0)]),
        bill(id: 'b2', total: 1, lines: [line()]),
      ]);
      expect(s.unknownCostLines, 2);
      expect(s.unknownCostBills, 1);
    });

    test('margin is a whole percent of sales', () {
      final s = summarise([
        bill(total: 10000, lines: [line(qty: 4000, price: 2500, cost: 1800)]),
      ]);
      expect(s.marginPercent, 28);
    });

    test('there is no margin on no sales', () {
      expect(ProfitSummary.empty.marginPercent, isNull);
    });
  });

  group('stock value', () {
    test('is quantity at the last cost', () {
      expect(stockValuePaise(qtyThousandths: 24000, unitCostPaise: 1800), 43200);
    });

    test('negative stock is worth nothing, not less than nothing', () {
      expect(stockValuePaise(qtyThousandths: -3000, unitCostPaise: 1800), 0);
    });

    test('an item with no cost contributes nothing', () {
      expect(stockValuePaise(qtyThousandths: 24000, unitCostPaise: 0), 0);
    });
  });

  group('days of stock left', () {
    test('divides stock by the recent selling rate', () {
      // 12 left, 90 sold over 30 days is 3 a day: 4 days.
      expect(
        daysOfStockLeft(
          qtyThousandths: 12000,
          soldInWindowThousandths: 90000,
          windowDays: 30,
        ),
        4,
      );
    });

    test('rounds down — better to order a day early than a day late', () {
      expect(
        daysOfStockLeft(
          qtyThousandths: 13000,
          soldInWindowThousandths: 90000,
          windowDays: 30,
        ),
        4,
      );
    });

    test('says nothing when nothing sold, rather than inventing a rate', () {
      expect(
        daysOfStockLeft(
          qtyThousandths: 5000,
          soldInWindowThousandths: 0,
          windowDays: 30,
        ),
        isNull,
      );
    });

    test('an empty shelf is zero days however slowly it sells', () {
      expect(
        daysOfStockLeft(
          qtyThousandths: 0,
          soldInWindowThousandths: 1000,
          windowDays: 30,
        ),
        0,
      );
    });
  });

  group('reorder urgency', () {
    ReorderEntry entry(
      String name, {
      required int qty,
      int threshold = 10000,
      int sold = 0,
    }) =>
        ReorderEntry(
          itemId: name,
          name: name,
          unit: 'pcs',
          qtyThousandths: qty,
          thresholdThousandths: threshold,
          soldInWindowThousandths: sold,
          windowDays: 30,
        );

    test('out of stock comes before anything merely low', () {
      final list = [
        entry('low', qty: 2000, sold: 300000),
        entry('out', qty: 0),
      ]..sort(compareUrgency);
      expect(list.first.name, 'out');
    });

    test('among low items, the one that runs out soonest is first', () {
      final list = [
        entry('slow', qty: 8000, sold: 30000), // 8 days
        entry('fast', qty: 8000, sold: 240000), // 1 day
      ]..sort(compareUrgency);
      expect(list.first.name, 'fast');
    });

    test('an item with a known rate outranks one with none', () {
      final list = [
        entry('unknown', qty: 1000),
        entry('known', qty: 8000, sold: 30000),
      ]..sort(compareUrgency);
      expect(list.first.name, 'known');
    });

    test('with no rates to compare, furthest under threshold is first', () {
      final list = [
        entry('near', qty: 9000),
        entry('far', qty: 1000),
      ]..sort(compareUrgency);
      expect(list.first.name, 'far');
    });
  });
}
