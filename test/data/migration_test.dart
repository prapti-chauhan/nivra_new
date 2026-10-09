@Tags(['migration'])
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/clock.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/domain/cashbook.dart';

import '../generated_migrations/schema.dart';
import '../generated_migrations/schema_v2.dart' as v2;
import '../generated_migrations/schema_v3.dart' as v3;
import '../generated_migrations/schema_v4.dart' as v4;

/// Ramesh already has the app on his phone with real bills in it. A fresh
/// install exercises `createAll` and would never touch `onUpgrade`, so without
/// these tests a broken migration would only ever appear on his device.
void main() {
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  test('a v2 database upgrades to the current schema with the expected shape', () async {
    final connection = await verifier.startAt(2);
    final db = AppDatabase.forTesting(connection, clock: FixedClock(1700000000000));
    await verifier.migrateAndValidate(db, 5);
    await db.close();
  });

  test('data written under v2 survives the upgrade', () async {
    // File-backed on purpose: this is exactly what happens on the phone —
    // the old build wrote a database, the new build opens the same file.
    final dir = await Directory.systemTemp.createTemp('nivra_migration');
    final file = File('${dir.path}/nivra.sqlite');

    final old = v2.DatabaseAtV2(NativeDatabase(file));
    // Letting drift open the v2 database normally is what stamps
    // user_version = 2. Calling createAll() by hand does not, and the file
    // would then look brand-new on reopen and run onCreate instead of
    // onUpgrade — which is not what happens on a phone that already has data.
    await old.customSelect('SELECT 1').get();
    await old.customStatement(
      "INSERT INTO customers (id, user_id, created_at, updated_at, is_dirty, "
      "name, balance) VALUES ('c1', 'u1', 1, 1, 0, 'Ramesh Kumar', 42000)",
    );
    await old.customStatement(
      "INSERT INTO items (id, user_id, created_at, updated_at, is_dirty, "
      "name, unit, sale_price, purchase_price, tax_rate_bp, stock_qty) "
      "VALUES ('i1', 'u1', 1, 1, 0, '16mm hex bolt', 'pcs', 2500, 1800, 0, 24000)",
    );
    await old.customStatement(
      "INSERT INTO payments (id, user_id, created_at, updated_at, is_dirty, "
      "amount, method, occurred_at) "
      "VALUES ('p1', 'u1', 1, 1, 0, 50000, 'cash', 1)",
    );
    await old.close();

    // Reopening the same file under the current schema runs onUpgrade.
    final upgraded = AppDatabase.forTesting(
      NativeDatabase(file),
      clock: FixedClock(1700000000000),
    );

    final customers = await upgraded.customSelect(
      'SELECT name, balance FROM customers',
      readsFrom: {},
    ).getSingle();
    expect(customers.read<String>('name'), 'Ramesh Kumar');
    expect(customers.read<int>('balance'), 42000);

    final items = await upgraded
        .customSelect('SELECT stock_qty FROM items', readsFrom: {})
        .getSingle();
    expect(items.read<int>('stock_qty'), 24000);

    // The payment survived and gained its two new, empty, columns.
    final payment = await upgraded.customSelect(
      'SELECT amount, supplier_id, purchase_id FROM payments',
      readsFrom: {},
    ).getSingle();
    expect(payment.read<int>('amount'), 50000);
    expect(payment.read<String?>('supplier_id'), isNull);
    expect(payment.read<String?>('purchase_id'), isNull);

    // And the tables that did not exist before are usable.
    final supplierId = await PurchaseDao(upgraded)
        .createSupplier(userId: 'u1', name: 'Verma Traders');
    expect(supplierId, isNotEmpty);

    await upgraded.close();
    await dir.delete(recursive: true);
  });

  test('the new tables work after an upgrade, not only after a fresh install',
      () async {
    final connection = await verifier.startAt(2);
    final db = AppDatabase.forTesting(
      connection,
      clock: FixedClock(1700000000000),
    );
    await verifier.migrateAndValidate(db, 5);

    final dao = PurchaseDao(db);
    final itemId = await InventoryDao(db).createItem(
      userId: 'u1',
      name: 'bolt',
      salePrice: 2500,
      purchasePrice: 1800,
    );
    final supplierId =
        await dao.createSupplier(userId: 'u1', name: 'Verma Traders');
    await dao.savePurchase(
      userId: 'u1',
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

    expect((await dao.findSupplier(supplierId))!.balance, -90000);
    await db.close();
  });

  test('a v3 database upgrades to the current schema with the expected shape', () async {
    final connection = await verifier.startAt(3);
    final db = AppDatabase.forTesting(connection, clock: FixedClock(1700000000000));
    await verifier.migrateAndValidate(db, 5);
    await db.close();
  });

  test('a database two versions behind still reaches the current schema', () async {
    // A phone that skipped an update goes 2 -> 5 in one open. Each step is
    // guarded by `from < N`, and this is what proves they chain.
    final connection = await verifier.startAt(2);
    final db = AppDatabase.forTesting(connection, clock: FixedClock(1700000000000));
    await verifier.migrateAndValidate(db, 5);
    await db.close();
  });

  test('data written under v3 survives, and money entries then work', () async {
    final dir = await Directory.systemTemp.createTemp('nivra_migration_v3');
    final file = File('${dir.path}/nivra.sqlite');

    final old = v3.DatabaseAtV3(NativeDatabase(file));
    await old.customSelect('SELECT 1').get();
    await old.customStatement(
      "INSERT INTO suppliers (id, user_id, created_at, updated_at, is_dirty, "
      "name, balance) VALUES ('s1', 'u1', 1, 1, 0, 'Verma Traders', -90000)",
    );
    await old.customStatement(
      "INSERT INTO ledger_entries (id, user_id, created_at, updated_at, "
      "is_dirty, account_type, amount, reason, occurred_at) "
      "VALUES ('l1', 'u1', 1, 1, 0, 'cash', 250000, 'payment_in', 1)",
    );
    await old.close();

    final upgraded = AppDatabase.forTesting(
      NativeDatabase(file),
      clock: FixedClock(1700000000000),
    );

    final supplier = await upgraded
        .customSelect('SELECT name, balance FROM suppliers', readsFrom: {})
        .getSingle();
    expect(supplier.read<String>('name'), 'Verma Traders');
    expect(supplier.read<int>('balance'), -90000);

    // The cash that was already in the ledger is still the till, and a new
    // expense moves it.
    final dao = MoneyDao(upgraded);
    expect(await dao.balanceOf(MoneyMethod.cash), 250000);
    await dao.addEntry(
      userId: 'u1',
      kind: MoneyKind.expense,
      amount: 5000,
      category: 'Tea',
    );
    expect(await dao.balanceOf(MoneyMethod.cash), 245000);

    await upgraded.close();
    await dir.delete(recursive: true);
  });
  test('a v4 database gains the cost-correction columns, empty', () async {
    final dir = await Directory.systemTemp.createTemp('nivra_migration_v4');
    final file = File('${dir.path}/nivra.sqlite');

    final old = v4.DatabaseAtV4(NativeDatabase(file));
    await old.customSelect('SELECT 1').get();
    await old.customStatement(
      "INSERT INTO bills (id, user_id, created_at, updated_at, is_dirty, "
      "number, occurred_at) VALUES ('b1', 'u1', 1, 1, 0, 1, 1)",
    );
    await old.customStatement(
      "INSERT INTO bill_lines (id, user_id, created_at, updated_at, is_dirty, "
      "bill_id, name, qty, unit_price, unit_cost, line_total) "
      "VALUES ('l1', 'u1', 1, 1, 0, 'b1', 'bolt', 1000, 2500, 1800, 2500)",
    );
    await old.close();

    final upgraded = AppDatabase.forTesting(
      NativeDatabase(file),
      clock: FixedClock(1700000000000),
    );
    final line = await upgraded
        .customSelect(
          'SELECT unit_cost, original_unit_cost, cost_corrected_at '
          'FROM bill_lines',
          readsFrom: {},
        )
        .getSingle();
    expect(line.read<int>('unit_cost'), 1800);
    expect(line.read<int?>('original_unit_cost'), isNull);
    expect(line.read<int?>('cost_corrected_at'), isNull);
    await upgraded.close();
  });
}

