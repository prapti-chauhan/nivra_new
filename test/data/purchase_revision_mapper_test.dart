import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/clock.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/data/remote/mappers.dart';
import 'package:nivra_new/domain/cashbook.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(
      NativeDatabase.memory(),
      clock: FixedClock(1700000000000),
    );
  });

  tearDown(() => db.close());

  test('a purchase revision and the edit count travel both ways', () async {
    final dao = PurchaseDao(db);
    final supplier = await dao.createSupplier(userId: 'u1', name: 'Verma');
    const line = PurchaseLineDraft(
      itemId: null,
      name: 'bolt',
      unit: 'pcs',
      qty: 1000,
      unitCost: 500,
    );
    final id = await dao.savePurchase(
      userId: 'u1',
      supplierId: supplier,
      lines: [line],
    );
    await dao.revisePurchase(
      userId: 'u1',
      purchaseId: id,
      supplierId: supplier,
      lines: [line],
    );

    final purchase = (await dao.findPurchase(id))!;
    final purchaseJson = BillingMappers.purchaseToJson(purchase);
    expect(purchaseJson['revision'], 1);
    expect(BillingMappers.purchaseFromJson(purchaseJson).revision.value, 1);

    final revision = (await db.select(db.purchaseRevisions).get()).single;
    final json = BillingMappers.purchaseRevisionToJson(revision);
    expect(json['purchase_id'], id);
    expect(json['revision'], 0);
    final back = BillingMappers.purchaseRevisionFromJson(json);
    expect(back.purchaseId.value, id);
    expect(back.snapshot.value, revision.snapshot);
    expect(back.replacedAt.value, revision.replacedAt);
    expect(back.isDirty.value, isFalse, reason: 'a pulled row is settled');
  });

  test('a purchase from a server that predates revisions reads as unedited',
      () {
    final back = BillingMappers.purchaseFromJson({
      'id': 'p1',
      'user_id': 'u1',
      'supplier_id': 's1',
      'total': 500,
    });
    expect(back.revision.value, 0);
  });

  test('signing out wipes every table, not only the first slices\'', () async {
    final dao = PurchaseDao(db);
    final supplier = await dao.createSupplier(userId: 'u1', name: 'Verma');
    const line = PurchaseLineDraft(
      itemId: null,
      name: 'bolt',
      unit: 'pcs',
      qty: 1000,
      unitCost: 500,
    );
    final purchase = await dao.savePurchase(
      userId: 'u1',
      supplierId: supplier,
      lines: [line],
      amountPaid: 100,
    );
    await dao.revisePurchase(
      userId: 'u1',
      purchaseId: purchase,
      supplierId: supplier,
      lines: [line],
    );
    await MoneyDao(db).addEntry(
      userId: 'u1',
      kind: MoneyKind.expense,
      amount: 100,
      category: 'Tea',
    );

    await SyncDao(db).wipeAll();

    for (final table in [
      'suppliers',
      'purchases',
      'purchase_lines',
      'purchase_revisions',
      'money_entries',
      'payments',
      'ledger_entries',
      'stock_movements',
    ]) {
      final row = await db
          .customSelect('SELECT COUNT(*) AS n FROM $table', readsFrom: {})
          .getSingle();
      expect(row.read<int>('n'), 0, reason: '$table should be empty');
    }
  });
}
