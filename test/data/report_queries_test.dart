import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/clock.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/data/reports/report_queries.dart';
import 'package:nivra_new/domain/billing.dart';
import 'package:nivra_new/domain/reports.dart';

const userId = 'user-1';

void main() {
  late AppDatabase db;
  late FixedClock clock;
  late InventoryDao inventory;
  late BillingDao billing;
  late PartyDao parties;
  late PurchaseDao purchases;
  late ReportQueries reports;

  // Wednesday 7 October 2026, 3:30pm local.
  final now = DateTime(2026, 10, 7, 15, 30);
  final everything = DateRange(0, DateTime(2100).millisecondsSinceEpoch);

  setUp(() {
    clock = FixedClock(now.millisecondsSinceEpoch);
    db = AppDatabase.forTesting(NativeDatabase.memory(), clock: clock);
    inventory = InventoryDao(db);
    billing = BillingDao(db);
    parties = PartyDao(db);
    purchases = PurchaseDao(db);
    reports = ReportQueries(db);
  });

  tearDown(() => db.close());

  Future<String> item({
    String name = 'bolt',
    int price = 2500,
    int cost = 1800,
    int stock = 100000,
    int? threshold,
  }) =>
      inventory.createItem(
        userId: userId,
        name: name,
        salePrice: price,
        purchasePrice: cost,
        openingStock: stock,
        lowStockThreshold: threshold,
      );

  BillLineDraft draft(
    String itemId, {
    int qty = 4000,
    int price = 2500,
    int cost = 1800,
    String name = 'bolt',
  }) =>
      BillLineDraft(
        itemId: itemId,
        name: name,
        unit: 'pcs',
        qty: qty,
        unitPrice: price,
        unitCost: cost,
      );

  Future<List<BillProfit>> profits([DateRange? range]) =>
      reports.watchBillProfits(range ?? everything).first;

  group('profit', () {
    test('reads sales and cost back off the bill that was saved', () async {
      final id = await item();
      await billing.saveBill(userId: userId, lines: [draft(id)]);

      final s = summarise(await profits());
      // 4 at Rs 25 = Rs 100 revenue, sold against Rs 18 = Rs 72 cost.
      expect(s.billCount, 1);
      expect(s.salesPaise, 10000);
      expect(s.costPaise, 7200);
      expect(s.profitPaise, 2800);
      expect(s.hasUnknownCost, isFalse);
    });

    test('a discount comes out of profit', () async {
      final id = await item();
      await billing.saveBill(
        userId: userId,
        lines: [draft(id)],
        discount: const Discount(DiscountType.amount, 1000),
      );
      final s = summarise(await profits());
      expect(s.salesPaise, 9000);
      expect(s.profitPaise, 1800);
    });

    test('only bills inside the period count', () async {
      final id = await item();
      clock.setTo(DateTime(2026, 9, 30, 12).millisecondsSinceEpoch);
      await billing.saveBill(userId: userId, lines: [draft(id)]);
      clock.setTo(now.millisecondsSinceEpoch);
      await billing.saveBill(userId: userId, lines: [draft(id, qty: 2000)]);

      final month = await profits(rangeFor(ReportPeriod.thisMonth, now));
      final lastMonth = await profits(rangeFor(ReportPeriod.lastMonth, now));
      expect(summarise(month).salesPaise, 5000);
      expect(summarise(lastMonth).salesPaise, 10000);
    });

    test('a deleted bill drops out', () async {
      final id = await item();
      final billId = await billing.saveBill(userId: userId, lines: [draft(id)]);
      await billing.deleteBill(userId: userId, billId: billId);
      expect(await profits(), isEmpty);
    });

    test('an edited bill is counted once, at its current figures', () async {
      final a = await item(name: 'A');
      final b = await item(name: 'B', price: 4000, cost: 3000);
      final billId = await billing.saveBill(
        userId: userId,
        lines: [draft(a, name: 'A')],
      );
      await billing.reviseBill(
        userId: userId,
        billId: billId,
        lines: [
          draft(a, name: 'A'),
          draft(b, qty: 1000, price: 4000, cost: 3000, name: 'B'),
        ],
      );

      final list = await profits();
      expect(list, hasLength(1));
      expect(list.single.lines, hasLength(2));
      // Rs 100 + Rs 40 revenue; Rs 72 + Rs 30 cost.
      expect(list.single.totalPaise, 14000);
      expect(list.single.profitPaise, 3800);
    });

    test('a line sold with no cost is flagged', () async {
      final id = await item(cost: 0);
      await billing.saveBill(
        userId: userId,
        lines: [draft(id, cost: 0)],
      );
      final s = summarise(await profits());
      expect(s.hasUnknownCost, isTrue);
      expect(s.unknownCostBills, 1);
    });

    test('a later price change does not rewrite past profit', () async {
      final id = await item(cost: 1800);
      await billing.saveBill(userId: userId, lines: [draft(id, cost: 1800)]);

      final supplier =
          await purchases.createSupplier(userId: userId, name: 'Verma');
      await purchases.savePurchase(
        userId: userId,
        supplierId: supplier,
        lines: [
          PurchaseLineDraft(
            itemId: id,
            name: 'bolt',
            unit: 'pcs',
            qty: 10000,
            unitCost: 2400,
          ),
        ],
      );

      // The item now costs Rs 24, but the bill was sold against Rs 18 and
      // stays that way — this is the property that makes a past month stable.
      expect((await inventory.findItem(id))!.purchasePrice, 2400);
      expect(summarise(await profits()).profitPaise, 2800);
    });

    test('sales agree with the sales account in the ledger', () async {
      final a = await item(name: 'A');
      final b = await item(name: 'B', price: 4000, cost: 3000);
      final first = await billing.saveBill(
        userId: userId,
        lines: [draft(a, name: 'A')],
      );
      await billing.saveBill(
        userId: userId,
        lines: [draft(b, qty: 3000, price: 4000, cost: 3000, name: 'B')],
        discount: const Discount(DiscountType.percent, 500),
      );
      await billing.reviseBill(
        userId: userId,
        billId: first,
        lines: [draft(a, qty: 6000, name: 'A')],
      );
      final third = await billing.saveBill(
        userId: userId,
        lines: [draft(a, qty: 1000, name: 'A')],
      );
      await billing.deleteBill(userId: userId, billId: third);

      final ledgerSales = await db.customSelect(
        "SELECT COALESCE(SUM(amount), 0) AS total FROM ledger_entries "
        "WHERE account_type = 'sales'",
        readsFrom: {db.ledgerEntries},
      ).getSingle();

      // Two independent routes to the same number: summing live bills, and
      // summing the ledger with every reversal included. If they ever differ
      // a report is lying about money.
      expect(
        summarise(await profits()).salesPaise,
        ledgerSales.read<int>('total'),
      );
    });
  });

  group('owed', () {
    test('lists customers who owe, biggest first', () async {
      final small = await parties.createCustomer(
          userId: userId, name: 'Small', openingBalance: 10000);
      final big = await parties.createCustomer(
          userId: userId, name: 'Big', openingBalance: 90000);
      await parties.createCustomer(userId: userId, name: 'Square');

      final list = await reports.watchOwedToYou().first;
      expect(list.map((c) => c.id), [big, small]);
    });

    test('lists suppliers he owes, biggest first', () async {
      await purchases.createSupplier(userId: userId, name: 'Square');
      final small = await purchases.createSupplier(
          userId: userId, name: 'Small', openingPayable: 10000);
      final big = await purchases.createSupplier(
          userId: userId, name: 'Big', openingPayable: 90000);

      final list = await reports.watchYouOwe().first;
      expect(list.map((s) => s.id), [big, small]);
    });
  });

  group('reorder', () {
    Future<List<ReorderEntry>> reorder() => reports
        .watchReorder(
          sinceMillis: now.subtract(const Duration(days: 30)).millisecondsSinceEpoch,
          windowDays: 30,
        )
        .first;

    test('only items with a threshold ever appear', () async {
      await item(name: 'tracked', stock: 2000, threshold: 5000);
      await item(name: 'untracked', stock: 1000);
      final list = await reorder();
      expect(list.map((e) => e.name), ['tracked']);
    });

    test('an item above its threshold is left alone', () async {
      await item(stock: 8000, threshold: 5000);
      expect(await reorder(), isEmpty);
    });

    test('an item exactly at its threshold appears', () async {
      await item(stock: 5000, threshold: 5000);
      expect(await reorder(), hasLength(1));
    });

    test('says how fast it has been selling', () async {
      final id = await item(stock: 100000, threshold: 20000);
      // 90 sold in the window leaves 10, under the threshold of 20.
      await billing.saveBill(userId: userId, lines: [draft(id, qty: 90000)]);
      final entry = (await reorder()).single;
      expect(entry.soldInWindowThousandths, 90000);
      // 10 left at 3 a day is 3 days.
      expect(entry.daysLeft, 3);
    });

    test('an edited bill does not read as negative demand', () async {
      final id = await item(stock: 100000, threshold: 95000);
      final billId =
          await billing.saveBill(userId: userId, lines: [draft(id, qty: 10000)]);
      clock.advance(const Duration(days: 2).inMilliseconds);
      await billing.reviseBill(
        userId: userId,
        billId: billId,
        lines: [draft(id, qty: 10000)],
      );
      // Sold 10, reversed 10, sold 10 again: demand is 10, not 0 and not -10.
      final entry = (await reorder()).single;
      expect(entry.soldInWindowThousandths, 10000);
    });

    test('a deleted purchase is not mistaken for a sale', () async {
      final id = await item(stock: 1000, threshold: 5000);
      final supplier =
          await purchases.createSupplier(userId: userId, name: 'Verma');
      final purchaseId = await purchases.savePurchase(
        userId: userId,
        supplierId: supplier,
        lines: [
          PurchaseLineDraft(
            itemId: id,
            name: 'bolt',
            unit: 'pcs',
            qty: 50000,
            unitCost: 1800,
          ),
        ],
      );
      await purchases.deletePurchase(userId: userId, purchaseId: purchaseId);

      final entry = (await reorder()).single;
      expect(entry.soldInWindowThousandths, 0);
      expect(entry.daysLeft, isNull);
    });

    test('most urgent comes first', () async {
      await item(name: 'out', stock: 0, threshold: 5000);
      await item(name: 'low', stock: 2000, threshold: 5000);
      final list = await reorder();
      expect(list.first.name, 'out');
    });
  });
}
