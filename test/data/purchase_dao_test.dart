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
}
