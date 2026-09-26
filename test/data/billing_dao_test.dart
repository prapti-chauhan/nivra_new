import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/clock.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/domain/billing.dart';

const userId = 'user-1';

void main() {
  late AppDatabase db;
  late InventoryDao inventory;
  late PartyDao parties;
  late BillingDao billing;
  late FixedClock clock;

  late String boltId;
  late String cementId;

  setUp(() async {
    clock = FixedClock(1700000000000);
    db = AppDatabase.forTesting(NativeDatabase.memory(), clock: clock);
    inventory = InventoryDao(db);
    parties = PartyDao(db);
    billing = BillingDao(db);

    boltId = await inventory.createItem(
      userId: userId,
      name: 'Hex bolt 16mm',
      salePrice: 1450,
      purchasePrice: 1000,
      openingStock: 100000,
    );
    cementId = await inventory.createItem(
      userId: userId,
      name: 'Cement bag 50kg',
      salePrice: 42000,
      purchasePrice: 38000,
      openingStock: 20000,
    );
  });

  tearDown(() => db.close());

  Future<int> stock(String id) async => (await inventory.findItem(id))!.stockQty;

  group('saving a cash sale', () {
    test('moves stock, records revenue, and needs no customer', () async {
      final billId = await billing.saveBill(
        userId: userId,
        lines: [
          BillLineDraft(
            itemId: boltId,
            name: 'Hex bolt 16mm',
            unit: 'pcs',
            qty: 3000,
            unitPrice: 1450,
            unitCost: 1000,
          ),
          BillLineDraft(
            itemId: cementId,
            name: 'Cement bag 50kg',
            unit: 'pcs',
            qty: 1000,
            unitPrice: 42000,
            unitCost: 38000,
          ),
        ],
      );

      final bill = await billing.findBill(billId);
      expect(bill!.total, 46350); // 3 * 14.50 + 1 * 420.00
      expect(bill.customerId, isNull);
      expect(bill.number, 1);
      expect(bill.amountPaid, 46350);
      expect(
        paymentStatusFor(totalPaise: bill.total, paidPaise: bill.amountPaid),
        PaymentStatus.paid,
      );

      expect(await stock(boltId), 97000);
      expect(await stock(cementId), 19000);
      expect(await inventory.stockFromLedger(boltId), 97000);

      // Each sold line names the bill that caused it.
      final movements = await inventory.watchMovements(boltId).first;
      final sale = movements.firstWhere((m) => m.reason == 'sale');
      expect(sale.sourceType, 'bill');
      expect(sale.sourceId, billId);
      expect(sale.unitCost, 1000, reason: 'cost carried for profit later');
    });

    test('numbers bills in sequence', () async {
      final line = BillLineDraft(
        itemId: boltId,
        name: 'Hex bolt 16mm',
        unit: 'pcs',
        qty: 1000,
        unitPrice: 1450,
      );
      final a = await billing.saveBill(userId: userId, lines: [line]);
      final b = await billing.saveBill(userId: userId, lines: [line]);
      final c = await billing.saveBill(userId: userId, lines: [line]);

      expect((await billing.findBill(a))!.number, 1);
      expect((await billing.findBill(b))!.number, 2);
      expect((await billing.findBill(c))!.number, 3);
    });

    test('applies a discount without letting the bill go negative', () async {
      final billId = await billing.saveBill(
        userId: userId,
        lines: [
          BillLineDraft(
            itemId: cementId,
            name: 'Cement bag 50kg',
            unit: 'pcs',
            qty: 2000,
            unitPrice: 42000,
          ),
        ],
        discount: const Discount(DiscountType.percent, 1000), // 10%
      );
      final bill = await billing.findBill(billId);
      expect(bill!.subtotal, 84000);
      expect(bill.discountAmount, 8400);
      expect(bill.total, 75600);
    });

    test('refuses an empty bill', () async {
      expect(
        () => billing.saveBill(userId: userId, lines: const []),
        throwsArgumentError,
      );
    });
  });

  group('credit sales', () {
    test('a credit bill raises what the customer owes', () async {
      final customerId =
          await parties.createCustomer(userId: userId, name: 'Sharma Traders');

      final billId = await billing.saveBill(
        userId: userId,
        customerId: customerId,
        customerName: 'Sharma Traders',
        paid: false,
        lines: [
          BillLineDraft(
            itemId: cementId,
            name: 'Cement bag 50kg',
            unit: 'pcs',
            qty: 5000,
            unitPrice: 42000,
          ),
        ],
      );

      final bill = await billing.findBill(billId);
      expect(bill!.total, 210000);
      expect(bill.amountPaid, 0);
      expect(
        paymentStatusFor(totalPaise: bill.total, paidPaise: bill.amountPaid),
        PaymentStatus.unpaid,
      );

      final customer = await parties.findCustomer(customerId);
      expect(customer!.balance, 210000, reason: 'positive means they owe him');
      expect(await parties.balanceFromLedger(customerId), 210000);
    });

    test('a payment clears the balance and marks the bill paid', () async {
      final customerId =
          await parties.createCustomer(userId: userId, name: 'Sharma Traders');
      final billId = await billing.saveBill(
        userId: userId,
        customerId: customerId,
        customerName: 'Sharma Traders',
        paid: false,
        lines: [
          BillLineDraft(
            itemId: cementId,
            name: 'Cement bag 50kg',
            unit: 'pcs',
            qty: 5000,
            unitPrice: 42000,
          ),
        ],
      );

      await billing.recordPayment(
        userId: userId,
        billId: billId,
        customerId: customerId,
        amount: 210000,
      );

      expect((await parties.findCustomer(customerId))!.balance, 0);
      expect((await billing.findBill(billId))!.amountPaid, 210000);
      expect(await billing.paidFromPayments(billId), 210000);
    });

    test('a part payment leaves the rest owing', () async {
      final customerId =
          await parties.createCustomer(userId: userId, name: 'Verma');
      final billId = await billing.saveBill(
        userId: userId,
        customerId: customerId,
        customerName: 'Verma',
        paid: false,
        lines: [
          BillLineDraft(
            itemId: cementId,
            name: 'Cement bag 50kg',
            unit: 'pcs',
            qty: 1000,
            unitPrice: 42000,
          ),
        ],
      );

      await billing.recordPayment(
        userId: userId,
        billId: billId,
        customerId: customerId,
        amount: 20000,
      );

      final bill = await billing.findBill(billId);
      expect(
        paymentStatusFor(totalPaise: bill!.total, paidPaise: bill.amountPaid),
        PaymentStatus.partial,
      );
      expect((await parties.findCustomer(customerId))!.balance, 22000);
    });

    test('refuses credit with nobody to owe the money', () async {
      expect(
        () => billing.saveBill(
          userId: userId,
          paid: false,
          lines: [
            BillLineDraft(
              itemId: boltId,
              name: 'Hex bolt 16mm',
              unit: 'pcs',
              qty: 1000,
              unitPrice: 1450,
            ),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('editing a bill leaves a trace', () {
    test('snapshots the old version and nets stock and balance correctly',
        () async {
      final customerId =
          await parties.createCustomer(userId: userId, name: 'Sharma Traders');

      // Typed 5 bags when he meant 2.
      final billId = await billing.saveBill(
        userId: userId,
        customerId: customerId,
        customerName: 'Sharma Traders',
        paid: false,
        lines: [
          BillLineDraft(
            itemId: cementId,
            name: 'Cement bag 50kg',
            unit: 'pcs',
            qty: 5000,
            unitPrice: 42000,
          ),
        ],
      );
      expect(await stock(cementId), 15000);
      expect((await parties.findCustomer(customerId))!.balance, 210000);

      clock.advance(60000);
      await billing.reviseBill(
        userId: userId,
        billId: billId,
        customerId: customerId,
        customerName: 'Sharma Traders',
        lines: [
          BillLineDraft(
            itemId: cementId,
            name: 'Cement bag 50kg',
            unit: 'pcs',
            qty: 2000,
            unitPrice: 42000,
          ),
        ],
      );

      final bill = await billing.findBill(billId);
      expect(bill!.total, 84000);
      expect(bill.revision, 1, reason: 'the bill is marked as edited');

      // Stock and balance end where they should, via reversal not mutation.
      expect(await stock(cementId), 18000);
      expect(await inventory.stockFromLedger(cementId), 18000);
      expect((await parties.findCustomer(customerId))!.balance, 84000);
      expect(await parties.balanceFromLedger(customerId), 84000);

      // The original is still readable.
      final revisions = await billing.watchRevisions(billId).first;
      expect(revisions, hasLength(1));
      final snapshot =
          jsonDecode(revisions.single.snapshot) as Map<String, dynamic>;
      expect(snapshot['total'], 210000);
      expect((snapshot['lines'] as List).single['qty'], 5000);

      // And the correction is visible in the item's history, not hidden.
      final movements = await inventory.watchMovements(cementId).first;
      expect(movements.where((m) => m.reason == 'sale'), hasLength(2));
      expect(movements.where((m) => m.reason == 'reversal'), hasLength(1));
    });

    test('nothing in the ledger is ever edited, only opposed', () async {
      final customerId =
          await parties.createCustomer(userId: userId, name: 'Sharma');
      final billId = await billing.saveBill(
        userId: userId,
        customerId: customerId,
        customerName: 'Sharma',
        paid: false,
        lines: [
          BillLineDraft(
            itemId: boltId,
            name: 'Hex bolt 16mm',
            unit: 'pcs',
            qty: 10000,
            unitPrice: 1450,
          ),
        ],
      );
      final before = await parties.watchLedger(customerId).first;

      await billing.reviseBill(
        userId: userId,
        billId: billId,
        customerId: customerId,
        customerName: 'Sharma',
        lines: [
          BillLineDraft(
            itemId: boltId,
            name: 'Hex bolt 16mm',
            unit: 'pcs',
            qty: 4000,
            unitPrice: 1450,
          ),
        ],
      );
      final after = await parties.watchLedger(customerId).first;

      // Every original row survives untouched; the correction is new rows.
      expect(after.length, greaterThan(before.length));
      for (final original in before) {
        final still = after.firstWhere((e) => e.id == original.id);
        expect(still.amount, original.amount);
        expect(still.reason, original.reason);
      }
    });
  });

  group('deleting a bill', () {
    test('returns the stock, clears the debt and reverses the payment',
        () async {
      final customerId =
          await parties.createCustomer(userId: userId, name: 'Walk-in regular');
      final billId = await billing.saveBill(
        userId: userId,
        customerId: customerId,
        customerName: 'Walk-in regular',
        lines: [
          BillLineDraft(
            itemId: boltId,
            name: 'Hex bolt 16mm',
            unit: 'pcs',
            qty: 6000,
            unitPrice: 1450,
          ),
        ],
      );
      expect(await stock(boltId), 94000);
      expect((await parties.findCustomer(customerId))!.balance, 0);

      clock.advance(1000);
      await billing.deleteBill(userId: userId, billId: billId);

      expect(await stock(boltId), 100000);
      expect(await inventory.stockFromLedger(boltId), 100000);
      expect((await parties.findCustomer(customerId))!.balance, 0);
      expect(await parties.balanceFromLedger(customerId), 0);
      expect((await billing.findBill(billId))!.deletedAt, isNotNull);
      expect(await billing.watchBills().first, isEmpty);
    });

    test('burns the invoice number rather than reusing it', () async {
      final line = BillLineDraft(
        itemId: boltId,
        name: 'Hex bolt 16mm',
        unit: 'pcs',
        qty: 1000,
        unitPrice: 1450,
      );
      final first = await billing.saveBill(userId: userId, lines: [line]);
      await billing.deleteBill(userId: userId, billId: first);
      final second = await billing.saveBill(userId: userId, lines: [line]);

      expect((await billing.findBill(second))!.number, 2,
          reason: 'gaps are correct; reused invoice numbers start disputes');
    });

    test('an undo puts everything back', () async {
      final customerId =
          await parties.createCustomer(userId: userId, name: 'Undo test');
      final billId = await billing.saveBill(
        userId: userId,
        customerId: customerId,
        customerName: 'Undo test',
        paid: false,
        lines: [
          BillLineDraft(
            itemId: boltId,
            name: 'Hex bolt 16mm',
            unit: 'pcs',
            qty: 5000,
            unitPrice: 1450,
          ),
        ],
      );

      await billing.deleteBill(userId: userId, billId: billId);
      expect(await stock(boltId), 100000);

      await billing.restoreBill(userId: userId, billId: billId);
      expect(await stock(boltId), 95000);
      expect((await parties.findCustomer(customerId))!.balance, 7250);
      expect(await billing.watchBills().first, hasLength(1));
    });
  });

  group('caches never silently drift', () {
    test('a full rebuild finds nothing wrong after real activity', () async {
      final customerId =
          await parties.createCustomer(userId: userId, name: 'Sharma');
      final billId = await billing.saveBill(
        userId: userId,
        customerId: customerId,
        customerName: 'Sharma',
        paid: false,
        lines: [
          BillLineDraft(
            itemId: boltId,
            name: 'Hex bolt 16mm',
            unit: 'pcs',
            qty: 7000,
            unitPrice: 1450,
          ),
          BillLineDraft(
            itemId: cementId,
            name: 'Cement bag 50kg',
            unit: 'pcs',
            qty: 3000,
            unitPrice: 42000,
          ),
        ],
      );
      await billing.recordPayment(
        userId: userId,
        billId: billId,
        customerId: customerId,
        amount: 50000,
      );
      await billing.reviseBill(
        userId: userId,
        billId: billId,
        customerId: customerId,
        customerName: 'Sharma',
        lines: [
          BillLineDraft(
            itemId: boltId,
            name: 'Hex bolt 16mm',
            unit: 'pcs',
            qty: 2000,
            unitPrice: 1450,
          ),
        ],
      );

      final report = await db.rebuildAllCaches();
      expect(report.foundProblems, isFalse, reason: report.toString());
    });

    test('a corrupted balance is detected and repaired from the ledger',
        () async {
      final customerId =
          await parties.createCustomer(userId: userId, name: 'Sharma');
      await billing.saveBill(
        userId: userId,
        customerId: customerId,
        customerName: 'Sharma',
        paid: false,
        lines: [
          BillLineDraft(
            itemId: boltId,
            name: 'Hex bolt 16mm',
            unit: 'pcs',
            qty: 2000,
            unitPrice: 1450,
          ),
        ],
      );

      await db.customStatement(
        'UPDATE customers SET balance = 999999 WHERE id = ?',
        [customerId],
      );

      final report = await db.rebuildAllCaches();
      expect(report.balances, 1);
      expect((await parties.findCustomer(customerId))!.balance, 2900);
    });
  });
}
