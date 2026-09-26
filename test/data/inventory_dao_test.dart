import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/clock.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/domain/stock.dart';

const userId = 'user-1';

void main() {
  late AppDatabase db;
  late InventoryDao dao;
  late FixedClock clock;

  setUp(() {
    clock = FixedClock(1700000000000);
    db = AppDatabase.forTesting(NativeDatabase.memory(), clock: clock);
    dao = InventoryDao(db);
  });

  tearDown(() => db.close());

  Future<int> cachedStock(String id) async => (await dao.findItem(id))!.stockQty;

  group('createItem', () {
    test('records opening stock as a movement, not a column', () async {
      final id = await dao.createItem(
        userId: userId,
        name: '16mm hex bolt',
        salePrice: 1400,
        purchasePrice: 1000,
        openingStock: 50000,
      );

      expect(await cachedStock(id), 50000);
      expect(await dao.stockFromLedger(id), 50000);

      final movements = await dao.watchMovements(id).first;
      expect(movements, hasLength(1));
      expect(movements.single.reason, MovementReason.opening.wire);
      expect(movements.single.qtyDelta, 50000);
      // Cost is carried from the very first movement so profit stays traceable.
      expect(movements.single.unitCost, 1000);
    });

    test('writes no movement when there is no opening stock', () async {
      final id = await dao.createItem(userId: userId, name: 'Cement bag');
      expect(await dao.watchMovements(id).first, isEmpty);
      expect(await cachedStock(id), 0);
    });
  });

  group('applyMovement', () {
    test('keeps the cache equal to the ledger across many movements', () async {
      final id = await dao.createItem(
        userId: userId,
        name: 'PVC pipe',
        openingStock: 100000,
      );

      await dao.applyMovement(
        userId: userId,
        itemId: id,
        qtyDelta: -2500,
        reason: MovementReason.sale,
        source: MovementSource.bill,
        sourceId: 'bill-1',
      );
      await dao.applyMovement(
        userId: userId,
        itemId: id,
        qtyDelta: 40000,
        reason: MovementReason.purchase,
        unitCost: 9000,
      );
      await dao.applyMovement(
        userId: userId,
        itemId: id,
        qtyDelta: -500,
        reason: MovementReason.adjustment,
        note: 'damaged',
      );

      expect(await cachedStock(id), 137000);
      expect(await dao.stockFromLedger(id), 137000);
    });

    test('allows stock to go negative rather than silently refusing', () async {
      // Ramesh sells from a shelf the app does not know about yet. Blocking
      // the sale would be worse than showing him a negative number he can fix.
      final id = await dao.createItem(userId: userId, name: 'Washer');
      await dao.applyMovement(
        userId: userId,
        itemId: id,
        qtyDelta: -3000,
        reason: MovementReason.sale,
      );
      expect(await cachedStock(id), -3000);
      expect(await dao.stockFromLedger(id), -3000);
    });

    test('links every movement back to the document that caused it', () async {
      final id = await dao.createItem(userId: userId, name: 'Hinge');
      await dao.applyMovement(
        userId: userId,
        itemId: id,
        qtyDelta: -1000,
        reason: MovementReason.sale,
        source: MovementSource.bill,
        sourceId: 'bill-42',
      );
      final movement = (await dao.watchMovements(id).first).single;
      expect(movement.sourceType, 'bill');
      expect(movement.sourceId, 'bill-42');
    });
  });

  group('rebuildStockCache', () {
    test('reports zero corrections when nothing has drifted', () async {
      final id = await dao.createItem(
        userId: userId,
        name: 'Nail 2 inch',
        openingStock: 10000,
      );
      await dao.applyMovement(
        userId: userId,
        itemId: id,
        qtyDelta: -1000,
        reason: MovementReason.sale,
      );

      expect(await dao.rebuildStockCache(), 0);
    });

    test('detects and repairs a corrupted cache from the ledger', () async {
      final id = await dao.createItem(
        userId: userId,
        name: 'Screw driver',
        openingStock: 8000,
      );

      // Simulate the bug this design exists to survive: something wrote the
      // cache without going through applyMovement.
      await db.customStatement(
        'UPDATE items SET stock_qty = 999999 WHERE id = ?',
        [id],
      );
      expect(await cachedStock(id), 999999);

      expect(await dao.rebuildStockCache(), 1);
      expect(await cachedStock(id), 8000);
      expect(await dao.stockFromLedger(id), 8000);
    });

    test('resets an item whose movements never existed', () async {
      final id = await dao.createItem(userId: userId, name: 'Tape');
      await db.customStatement(
        'UPDATE items SET stock_qty = 500 WHERE id = ?',
        [id],
      );
      expect(await dao.rebuildStockCache(), 1);
      expect(await cachedStock(id), 0);
    });
  });

  group('search and soft delete', () {
    test('matches on name and code, case-insensitively', () async {
      await dao.createItem(userId: userId, name: 'Hex Bolt 16mm', code: 'HB16');
      await dao.createItem(userId: userId, name: 'Cement Bag', code: 'CEM');

      expect(await dao.watchItems(search: 'bolt').first, hasLength(1));
      expect(await dao.watchItems(search: 'hb16').first, hasLength(1));
      expect(await dao.watchItems(search: 'BAG').first, hasLength(1));
      expect(await dao.watchItems(search: '').first, hasLength(2));
    });

    test('hides deleted items but keeps the row and its history', () async {
      final id = await dao.createItem(
        userId: userId,
        name: 'Old stock',
        openingStock: 5000,
      );
      await dao.setItemDeleted(id, deleted: true);

      expect(await dao.watchItems().first, isEmpty);
      expect(await dao.findItem(id), isNotNull);
      expect(await dao.watchMovements(id).first, hasLength(1));

      await dao.setItemDeleted(id, deleted: false);
      expect(await dao.watchItems().first, hasLength(1));
    });
  });
}
