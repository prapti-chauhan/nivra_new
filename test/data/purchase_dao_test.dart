import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/clock.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/domain/billing.dart';

const userId = 'user-1';

void main() {
  late AppDatabase db;
  late PurchaseDao dao;
  late InventoryDao inventory;
  late FixedClock clock;

  setUp(() {
    clock = FixedClock(1700000000000);
    db = AppDatabase.forTesting(NativeDatabase.memory(), clock: clock);
    dao = PurchaseDao(db);
    inventory = InventoryDao(db);
  });

  tearDown(() => db.close());

  Future<String> anItem({int cost = 1000, int stock = 0}) => inventory.createItem(
        userId: userId,
        name: '16mm hex bolt',
        salePrice: 1400,
        purchasePrice: cost,
        openingStock: stock,
      );

  Future<int> stockOf(String id) async => (await inventory.findItem(id))!.stockQty;
  Future<int> balanceOf(String id) async => (await dao.findSupplier(id))!.balance;

  group('suppliers', () {
    test('an opening payable is a ledger row, not a column', () async {
      final id = await dao.createSupplier(
        userId: userId,
        name: 'Verma Traders',
        openingPayable: 900000,
      );

      // The one global sign rule: positive is owed TO Ramesh, so a supplier
      // he owes sits negative.
      expect(await balanceOf(id), -900000);
      expect(payableFromBalance(await balanceOf(id)), 900000);
      expect(await dao.balanceFromLedger(id), -900000);
    });

    test('a supplier with no opening balance owes nothing either way', () async {
      final id = await dao.createSupplier(userId: userId, name: 'Verma Traders');
      expect(await balanceOf(id), 0);
    });

    test('deleting is soft, and restorable', () async {
      final id = await dao.createSupplier(userId: userId, name: 'Verma Traders');
      await dao.setSupplierDeleted(id, deleted: true);
      expect((await dao.findSupplier(id))!.deletedAt, isNotNull);
      await dao.setSupplierDeleted(id, deleted: false);
      expect((await dao.findSupplier(id))!.deletedAt, isNull);
    });
  });

  group('savePurchase', () {
    test('stock goes up and the payable goes up', () async {
      final itemId = await anItem(stock: 10000);
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');

      await dao.savePurchase(
        userId: userId,
        supplierId: supplierId,
        supplierName: 'Verma Traders',
        lines: [
          PurchaseLineDraft(
            itemId: itemId,
            name: '16mm hex bolt',
            unit: 'pcs',
            qty: 50000,
            unitCost: 1800,
          ),
        ],
      );

      expect(await stockOf(itemId), 60000);
      // 50 at Rs 18 is Rs 900.
      expect(payableFromBalance(await balanceOf(supplierId)), 90000);
    });

    test('the cached balance agrees with the ledger', () async {
      final itemId = await anItem();
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');
      await dao.savePurchase(
        userId: userId,
        supplierId: supplierId,
        lines: [
          PurchaseLineDraft(
            itemId: itemId,
            name: 'bolt',
            unit: 'pcs',
            qty: 10000,
            unitCost: 1800,
          ),
        ],
      );
      expect(await balanceOf(supplierId), await dao.balanceFromLedger(supplierId));
    });

    test('what he paid this time becomes the item cost next time', () async {
      final itemId = await anItem(cost: 1000);
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');

      await dao.savePurchase(
        userId: userId,
        supplierId: supplierId,
        lines: [
          PurchaseLineDraft(
            itemId: itemId,
            name: 'bolt',
            unit: 'pcs',
            qty: 10000,
            unitCost: 1850,
          ),
        ],
      );

      expect((await inventory.findItem(itemId))!.purchasePrice, 1850);
    });

    test('the movement carries the cost that was actually paid', () async {
      final itemId = await anItem();
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');
      await dao.savePurchase(
        userId: userId,
        supplierId: supplierId,
        lines: [
          PurchaseLineDraft(
            itemId: itemId,
            name: 'bolt',
            unit: 'pcs',
            qty: 10000,
            unitCost: 1850,
          ),
        ],
      );

      final movements = await (db.select(db.stockMovements)
            ..where((t) => t.reason.equals('purchase')))
          .get();
      expect(movements.single.unitCost, 1850);
      expect(movements.single.qtyDelta, 10000);
    });

    test('paying at the counter settles part of it', () async {
      final itemId = await anItem();
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');

      final purchaseId = await dao.savePurchase(
        userId: userId,
        supplierId: supplierId,
        lines: [
          PurchaseLineDraft(
            itemId: itemId,
            name: 'bolt',
            unit: 'pcs',
            qty: 50000,
            unitCost: 1800,
          ),
        ],
        amountPaid: 30000,
      );

      // Rs 900 bought, Rs 300 handed over, Rs 600 still owed.
      expect((await dao.findPurchase(purchaseId))!.amountPaid, 30000);
      expect(payableFromBalance(await balanceOf(supplierId)), 60000);
    });

    test('a discount reduces what is owed', () async {
      final itemId = await anItem();
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');

      final purchaseId = await dao.savePurchase(
        userId: userId,
        supplierId: supplierId,
        lines: [
          PurchaseLineDraft(
            itemId: itemId,
            name: 'bolt',
            unit: 'pcs',
            qty: 50000,
            unitCost: 1800,
          ),
        ],
        discount: const Discount(DiscountType.percent, 1000),
      );

      final purchase = (await dao.findPurchase(purchaseId))!;
      expect(purchase.subtotal, 90000);
      expect(purchase.discountAmount, 9000);
      expect(purchase.total, 81000);
      expect(payableFromBalance(await balanceOf(supplierId)), 81000);
    });

    test('a purchase with no lines is refused', () async {
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');
      expect(
        () => dao.savePurchase(
          userId: userId,
          supplierId: supplierId,
          lines: const [],
        ),
        throwsArgumentError,
      );
    });
  });

  group('paying a supplier', () {
    test('reduces the payable and takes money out of cash', () async {
      final supplierId = await dao.createSupplier(
        userId: userId,
        name: 'Verma Traders',
        openingPayable: 90000,
      );

      await dao.recordSupplierPayment(
        userId: userId,
        supplierId: supplierId,
        amount: 50000,
      );

      expect(payableFromBalance(await balanceOf(supplierId)), 40000);

      final cash = await (db.select(db.ledgerEntries)
            ..where((t) => t.accountType.equals('cash')))
          .get();
      // Money going out is a negative cash row, so the cash account is a
      // plain sum that never needs to know who was paid.
      expect(cash.single.amount, -50000);
    });

    test('the stored payment is negative, because the money left', () async {
      final supplierId = await dao.createSupplier(
        userId: userId,
        name: 'Verma Traders',
        openingPayable: 90000,
      );
      await dao.recordSupplierPayment(
        userId: userId,
        supplierId: supplierId,
        amount: 50000,
      );
      final row = await db.select(db.payments).getSingle();
      expect(row.amount, -50000);
      expect(row.supplierId, supplierId);
      expect(row.customerId, isNull);
    });

    test('a zero or negative payment is refused', () async {
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');
      expect(
        () => dao.recordSupplierPayment(
          userId: userId,
          supplierId: supplierId,
          amount: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => dao.recordSupplierPayment(
          userId: userId,
          supplierId: supplierId,
          amount: -100,
        ),
        throwsArgumentError,
      );
    });

    test('supplier payments do not leak into a bill', () async {
      final supplierId = await dao.createSupplier(
        userId: userId,
        name: 'Verma Traders',
        openingPayable: 90000,
      );
      await dao.recordSupplierPayment(
        userId: userId,
        supplierId: supplierId,
        amount: 50000,
      );
      // Nothing to repair: no bill claims this money.
      expect(await BillingDao(db).rebuildAmountPaidCache(), 0);
    });
  });

  group('deletePurchase', () {
    test('puts the stock back and clears what was owed', () async {
      final itemId = await anItem(stock: 10000);
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');

      final purchaseId = await dao.savePurchase(
        userId: userId,
        supplierId: supplierId,
        lines: [
          PurchaseLineDraft(
            itemId: itemId,
            name: 'bolt',
            unit: 'pcs',
            qty: 50000,
            unitCost: 1800,
          ),
        ],
      );

      clock.advance(60000);
      await dao.deletePurchase(userId: userId, purchaseId: purchaseId);

      expect(await stockOf(itemId), 10000);
      expect(await balanceOf(supplierId), 0);
      expect((await dao.findPurchase(purchaseId))!.deletedAt, isNotNull);
    });

    test('the original rows are untouched; reversal is new rows', () async {
      final itemId = await anItem();
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');
      final purchaseId = await dao.savePurchase(
        userId: userId,
        supplierId: supplierId,
        lines: [
          PurchaseLineDraft(
            itemId: itemId,
            name: 'bolt',
            unit: 'pcs',
            qty: 50000,
            unitCost: 1800,
          ),
        ],
      );
      await dao.deletePurchase(userId: userId, purchaseId: purchaseId);

      final movements = await db.select(db.stockMovements).get();
      final purchaseMovements =
          movements.where((m) => m.reason == 'purchase').toList();
      final reversals = movements.where((m) => m.reason == 'reversal').toList();
      expect(purchaseMovements.single.qtyDelta, 50000);
      expect(reversals.single.qtyDelta, -50000);
    });

    test('money already paid is given back too', () async {
      final itemId = await anItem();
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');
      final purchaseId = await dao.savePurchase(
        userId: userId,
        supplierId: supplierId,
        lines: [
          PurchaseLineDraft(
            itemId: itemId,
            name: 'bolt',
            unit: 'pcs',
            qty: 50000,
            unitCost: 1800,
          ),
        ],
        amountPaid: 30000,
      );

      await dao.deletePurchase(userId: userId, purchaseId: purchaseId);

      expect(await balanceOf(supplierId), 0);
      final cashTotal = (await (db.select(db.ledgerEntries)
                ..where((t) => t.accountType.equals('cash')))
              .get())
          .fold<int>(0, (sum, e) => sum + e.amount);
      expect(cashTotal, 0);
    });

    test('deleting twice does nothing the second time', () async {
      final itemId = await anItem();
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');
      final purchaseId = await dao.savePurchase(
        userId: userId,
        supplierId: supplierId,
        lines: [
          PurchaseLineDraft(
            itemId: itemId,
            name: 'bolt',
            unit: 'pcs',
            qty: 50000,
            unitCost: 1800,
          ),
        ],
      );
      await dao.deletePurchase(userId: userId, purchaseId: purchaseId);
      final stockAfterFirst = await stockOf(itemId);
      await dao.deletePurchase(userId: userId, purchaseId: purchaseId);
      expect(await stockOf(itemId), stockAfterFirst);
      expect(await balanceOf(supplierId), 0);
    });
  });

  group('cache repair', () {
    test('a corrupted supplier balance is found and fixed', () async {
      final supplierId = await dao.createSupplier(
        userId: userId,
        name: 'Verma Traders',
        openingPayable: 90000,
      );

      // Simulate the cache drifting away from the ledger.
      await db.customUpdate(
        'UPDATE suppliers SET balance = 12345 WHERE id = ?',
        variables: [Variable<String>(supplierId)],
      );

      expect(await dao.rebuildSupplierBalanceCache(), 1);
      expect(await balanceOf(supplierId), -90000);
      // And a second run finds nothing left to fix.
      expect(await dao.rebuildSupplierBalanceCache(), 0);
    });

    test('a corrupted purchase amount_paid is found and fixed', () async {
      final itemId = await anItem();
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');
      final purchaseId = await dao.savePurchase(
        userId: userId,
        supplierId: supplierId,
        lines: [
          PurchaseLineDraft(
            itemId: itemId,
            name: 'bolt',
            unit: 'pcs',
            qty: 50000,
            unitCost: 1800,
          ),
        ],
        amountPaid: 30000,
      );

      await db.customUpdate(
        'UPDATE purchases SET amount_paid = 999 WHERE id = ?',
        variables: [Variable<String>(purchaseId)],
      );

      expect(await dao.rebuildPurchasePaidCache(), 1);
      expect((await dao.findPurchase(purchaseId))!.amountPaid, 30000);
      expect(await dao.rebuildPurchasePaidCache(), 0);
    });

    test('a clean database reports nothing wrong', () async {
      final itemId = await anItem();
      final supplierId =
          await dao.createSupplier(userId: userId, name: 'Verma Traders');
      await dao.savePurchase(
        userId: userId,
        supplierId: supplierId,
        lines: [
          PurchaseLineDraft(
            itemId: itemId,
            name: 'bolt',
            unit: 'pcs',
            qty: 50000,
            unitCost: 1800,
          ),
        ],
        amountPaid: 30000,
      );

      final report = await db.rebuildAllCaches();
      expect(report.foundProblems, isFalse, reason: report.toString());
    });
  });
  group('editing a purchase', () {
    PurchaseLineDraft line(String itemId, {int qty = 10000, int cost = 1000}) =>
        PurchaseLineDraft(
          itemId: itemId,
          name: '16mm hex bolt',
          unit: 'pcs',
          qty: qty,
          unitCost: cost,
        );

    Future<int> cashOut() async => (await db
            .customSelect(
              "SELECT COALESCE(SUM(amount), 0) AS s FROM ledger_entries "
              "WHERE account_type = 'cash'",
              readsFrom: {db.ledgerEntries},
            )
            .getSingle())
        .read<int>('s');

    test('stock and the payable follow the new figures', () async {
      final supplier = await dao.createSupplier(userId: userId, name: 'Verma');
      final item = await anItem();
      final id = await dao.savePurchase(
        userId: userId,
        supplierId: supplier,
        lines: [line(item, qty: 10000, cost: 1000)], // 10 at 10.00 = 100.00
      );
      expect(await stockOf(item), 10000);
      expect(await balanceOf(supplier), -10000);

      await dao.revisePurchase(
        userId: userId,
        purchaseId: id,
        supplierId: supplier,
        lines: [line(item, qty: 8000, cost: 1250)], // 8 at 12.50 = 100.00
      );
      expect(await stockOf(item), 8000);
      expect(await balanceOf(supplier), -10000);

      await dao.revisePurchase(
        userId: userId,
        purchaseId: id,
        supplierId: supplier,
        lines: [line(item, qty: 10000, cost: 1500)], // 150.00
      );
      expect(await stockOf(item), 10000);
      expect(await balanceOf(supplier), -15000);
      expect(await dao.balanceFromLedger(supplier), -15000,
          reason: 'the cache and the ledger agree after two edits');
    });

    test('keeps the old version and counts the edit', () async {
      final supplier = await dao.createSupplier(userId: userId, name: 'Verma');
      final item = await anItem();
      final id = await dao.savePurchase(
        userId: userId,
        supplierId: supplier,
        supplierBillNo: 'A-17',
        lines: [line(item, qty: 10000, cost: 1000)],
      );
      clock.advance(5000);
      await dao.revisePurchase(
        userId: userId,
        purchaseId: id,
        supplierId: supplier,
        supplierBillNo: 'A-71',
        lines: [line(item, qty: 5000, cost: 1000)],
      );

      final purchase = (await dao.findPurchase(id))!;
      expect(purchase.revision, 1);
      expect(purchase.supplierBillNo, 'A-71');
      expect(purchase.total, 5000);
      expect(purchase.isDirty, isTrue);

      final revisions = await db.select(db.purchaseRevisions).get();
      expect(revisions, hasLength(1));
      expect(revisions.single.revision, 0);
      expect(revisions.single.isDirty, isTrue);
      final snapshot = jsonDecode(revisions.single.snapshot) as Map;
      expect(snapshot['total'], 10000);
      expect(snapshot['supplier_bill_no'], 'A-17');
      expect((snapshot['lines'] as List).single['qty'], 10000);

      final live = await dao.purchaseLinesFor(id);
      expect(live, hasLength(1));
      expect(live.single.qty, 5000);
      final all = await (db.select(db.purchaseLines)
            ..where((t) => t.purchaseId.equals(id)))
          .get();
      expect(all, hasLength(2), reason: 'the old line is kept, marked deleted');
    });

    test('never edits a ledger or movement row, only adds opposing ones',
        () async {
      final supplier = await dao.createSupplier(userId: userId, name: 'Verma');
      final item = await anItem();
      final id = await dao.savePurchase(
        userId: userId,
        supplierId: supplier,
        lines: [line(item)],
      );
      final ledgerBefore = await db.select(db.ledgerEntries).get();
      final movesBefore = await db.select(db.stockMovements).get();

      await dao.revisePurchase(
        userId: userId,
        purchaseId: id,
        supplierId: supplier,
        lines: [line(item, qty: 4000)],
      );

      final ledgerAfter = await db.select(db.ledgerEntries).get();
      for (final before in ledgerBefore) {
        final now = ledgerAfter.firstWhere((e) => e.id == before.id);
        expect(now.amount, before.amount);
        expect(now.updatedAt, before.updatedAt);
        expect(now.deletedAt, isNull);
      }
      expect(ledgerAfter.length, greaterThan(ledgerBefore.length));
      final movesAfter = await db.select(db.stockMovements).get();
      for (final before in movesBefore) {
        final now = movesAfter.firstWhere((m) => m.id == before.id);
        expect(now.qtyDelta, before.qtyDelta);
      }
      expect(movesAfter.length, greaterThan(movesBefore.length));
    });

    test('payments already made are left alone', () async {
      final supplier = await dao.createSupplier(userId: userId, name: 'Verma');
      final item = await anItem();
      final id = await dao.savePurchase(
        userId: userId,
        supplierId: supplier,
        lines: [line(item)], // 100.00
        amountPaid: 4000,
      );
      final cashBefore = await cashOut();
      expect(cashBefore, -4000);

      await dao.revisePurchase(
        userId: userId,
        purchaseId: id,
        supplierId: supplier,
        lines: [line(item, cost: 2000)], // 200.00
      );

      expect((await dao.findPurchase(id))!.amountPaid, 4000);
      expect(await cashOut(), cashBefore, reason: 'the money really left');
      expect(await balanceOf(supplier), -16000, reason: '200.00 less 40.00');
    });

    test('editing below what was paid shows an overpayment, not a lost payment',
        () async {
      final supplier = await dao.createSupplier(userId: userId, name: 'Verma');
      final item = await anItem();
      final id = await dao.savePurchase(
        userId: userId,
        supplierId: supplier,
        lines: [line(item)], // 100.00
        amountPaid: 10000,
      );
      await dao.revisePurchase(
        userId: userId,
        purchaseId: id,
        supplierId: supplier,
        lines: [line(item, qty: 5000)], // 50.00
      );
      expect(await balanceOf(supplier), 5000,
          reason: 'he has paid 50.00 more than he owes; the supplier owes him');
      expect((await dao.findPurchase(id))!.amountPaid, 10000);
    });

    test('moves to another supplier only while nothing has been paid',
        () async {
      final verma = await dao.createSupplier(userId: userId, name: 'Verma');
      final gupta = await dao.createSupplier(userId: userId, name: 'Gupta');
      final item = await anItem();

      final unpaid = await dao.savePurchase(
        userId: userId,
        supplierId: verma,
        lines: [line(item)],
      );
      await dao.revisePurchase(
        userId: userId,
        purchaseId: unpaid,
        supplierId: gupta,
        lines: [line(item)],
      );
      expect(await balanceOf(verma), 0);
      expect(await balanceOf(gupta), -10000);
      expect(await dao.balanceFromLedger(verma), 0);
      expect(await dao.balanceFromLedger(gupta), -10000);

      final paid = await dao.savePurchase(
        userId: userId,
        supplierId: verma,
        lines: [line(item)],
        amountPaid: 2500,
      );
      await expectLater(
        dao.revisePurchase(
          userId: userId,
          purchaseId: paid,
          supplierId: gupta,
          lines: [line(item)],
        ),
        throwsStateError,
      );
      // And the refused attempt changed nothing.
      expect((await dao.findPurchase(paid))!.supplierId, verma);
      expect((await dao.findPurchase(paid))!.revision, 0);
      expect(await balanceOf(verma), -7500);
    });

    test('an item takes its cost from an edit only on its newest purchase',
        () async {
      final supplier = await dao.createSupplier(userId: userId, name: 'Verma');
      final item = await anItem(cost: 500);
      final older = await dao.savePurchase(
        userId: userId,
        supplierId: supplier,
        occurredAt: 1700000000000,
        lines: [line(item, cost: 1000)],
      );
      final newer = await dao.savePurchase(
        userId: userId,
        supplierId: supplier,
        occurredAt: 1700000100000,
        lines: [line(item, cost: 1200)],
      );
      expect((await inventory.findItem(item))!.purchasePrice, 1200);

      await dao.revisePurchase(
        userId: userId,
        purchaseId: older,
        supplierId: supplier,
        lines: [line(item, cost: 900)],
      );
      expect((await inventory.findItem(item))!.purchasePrice, 1200,
          reason: 'correcting an old delivery must not undo the newer price');

      await dao.revisePurchase(
        userId: userId,
        purchaseId: newer,
        supplierId: supplier,
        lines: [line(item, cost: 1300)],
      );
      expect((await inventory.findItem(item))!.purchasePrice, 1300);
    });

    test('deleting an edited purchase puts everything back to zero', () async {
      final supplier = await dao.createSupplier(userId: userId, name: 'Verma');
      final item = await anItem();
      final id = await dao.savePurchase(
        userId: userId,
        supplierId: supplier,
        lines: [line(item)],
      );
      await dao.revisePurchase(
        userId: userId,
        purchaseId: id,
        supplierId: supplier,
        lines: [line(item, qty: 7000, cost: 1300)],
      );
      await dao.revisePurchase(
        userId: userId,
        purchaseId: id,
        supplierId: supplier,
        lines: [line(item, qty: 3000, cost: 1100)],
      );
      await dao.deletePurchase(userId: userId, purchaseId: id);

      expect(await stockOf(item), 0);
      expect(await balanceOf(supplier), 0);
      expect(await dao.balanceFromLedger(supplier), 0);
    });

    test('leaves no cache wrong for the rebuild to find', () async {
      final supplier = await dao.createSupplier(userId: userId, name: 'Verma');
      final item = await anItem();
      final id = await dao.savePurchase(
        userId: userId,
        supplierId: supplier,
        lines: [line(item)],
        amountPaid: 3000,
      );
      await dao.revisePurchase(
        userId: userId,
        purchaseId: id,
        supplierId: supplier,
        lines: [line(item, qty: 6000)],
      );
      final report = await db.rebuildAllCaches();
      expect(report.foundProblems, isFalse, reason: report.toString());
    });

    test('refuses an empty purchase, a missing one and a deleted one',
        () async {
      final supplier = await dao.createSupplier(userId: userId, name: 'Verma');
      final item = await anItem();
      final id = await dao.savePurchase(
        userId: userId,
        supplierId: supplier,
        lines: [line(item)],
      );
      expect(
        () => dao.revisePurchase(
          userId: userId,
          purchaseId: id,
          supplierId: supplier,
          lines: const [],
        ),
        throwsArgumentError,
      );
      expect(
        () => dao.revisePurchase(
          userId: userId,
          purchaseId: 'nope',
          supplierId: supplier,
          lines: [line(item)],
        ),
        throwsStateError,
      );
      await dao.deletePurchase(userId: userId, purchaseId: id);
      expect(
        () => dao.revisePurchase(
          userId: userId,
          purchaseId: id,
          supplierId: supplier,
          lines: [line(item)],
        ),
        throwsStateError,
      );
    });
  });
}
