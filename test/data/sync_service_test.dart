
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/clock.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/data/remote/sync_api.dart';
import 'package:nivra_new/data/sync/connectivity_monitor.dart';
import 'package:nivra_new/data/sync/sync_service.dart';
import 'package:nivra_new/domain/stock.dart';
import 'package:nivra_new/domain/sync_status.dart';

const userId = 'user-1';

/// An in-memory stand-in for Supabase: it stamps every row it accepts, which
/// is what the real server's trigger does.
class FakeSyncApi implements SyncApi {
  final Map<String, Map<String, Map<String, dynamic>>> tables = {};
  int _stamp = 0;

  /// Runs after rows are stored but before the acknowledgement is returned,
  /// to simulate an edit landing while the request is in flight.
  Future<void> Function()? onBeforeAck;

  Exception? failWith;
  int pushCalls = 0;

  void seed(String table, Map<String, dynamic> row) {
    _stamp++;
    tables.putIfAbsent(table, () => {})[row['id'] as String] = {
      ...row,
      SyncApi.serverStampColumn: _stamp,
    };
  }

  @override
  Future<List<RemoteAck>> push(
    String table,
    List<Map<String, dynamic>> rows,
  ) async {
    pushCalls++;
    if (failWith != null) throw failWith!;
    final acks = <RemoteAck>[];
    for (final row in rows) {
      _stamp++;
      final stored = {...row, SyncApi.serverStampColumn: _stamp};
      tables.putIfAbsent(table, () => {})[row['id'] as String] = stored;
      acks.add(RemoteAck(id: row['id'] as String, serverUpdatedAt: _stamp));
    }
    if (onBeforeAck != null) await onBeforeAck!();
    return acks;
  }

  @override
  Future<List<Map<String, dynamic>>> pull(
    String table, {
    required int since,
    int limit = 500,
  }) async {
    if (failWith != null) throw failWith!;
    final rows = (tables[table] ?? {})
        .values
        .where((r) => (r[SyncApi.serverStampColumn] as int) > since)
        .toList()
      ..sort((a, b) => (a[SyncApi.serverStampColumn] as int)
          .compareTo(b[SyncApi.serverStampColumn] as int));
    return rows.take(limit).map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

void main() {
  late AppDatabase db;
  late InventoryDao inventory;
  late SyncDao syncDao;
  late FakeSyncApi api;
  late FakeConnectivityMonitor net;
  late SyncService sync;
  late FixedClock clock;

  setUp(() {
    clock = FixedClock(1700000000000);
    db = AppDatabase.forTesting(NativeDatabase.memory(), clock: clock);
    inventory = InventoryDao(db);
    syncDao = SyncDao(db);
    api = FakeSyncApi();
    net = FakeConnectivityMonitor();
    sync = SyncService(db: db, connectivity: net, api: api, clock: clock);
  });

  tearDown(() async {
    await sync.stop();
    await db.close();
  });

  group('push', () {
    test('sends dirty rows and marks them settled', () async {
      final id = await inventory.createItem(
        userId: userId,
        name: 'Hex bolt',
        salePrice: 1400,
        openingStock: 20000,
      );
      expect(await syncDao.pendingCount(), 2); // the item and its movement

      sync.start(userId);
      await sync.syncNow();

      expect(await syncDao.pendingCount(), 0);
      expect(api.tables['items']![id]!['name'], 'Hex bolt');
      expect(api.tables['stock_movements']!.length, 1);

      final stored = await inventory.findItem(id);
      expect(stored!.isDirty, isFalse);
      expect(stored.serverUpdatedAt, greaterThan(0));
    });

    test('never pushes the stock cache, only the movements behind it', () async {
      final id = await inventory.createItem(
        userId: userId,
        name: 'PVC pipe',
        openingStock: 30000,
      );
      sync.start(userId);
      await sync.syncNow();

      expect(api.tables['items']![id]!.containsKey('stock_qty'), isFalse);
      final movement = api.tables['stock_movements']!.values.single;
      expect(movement['qty_delta'], 30000);
    });

    test('keeps a row dirty when it is edited while the push is in flight',
        () async {
      final id = await inventory.createItem(userId: userId, name: 'Cement');
      sync.start(userId);

      api.onBeforeAck = () async {
        clock.advance(1000);
        await inventory.updateItem(id: id, name: 'Cement 50kg');
        api.onBeforeAck = null;
      };

      await sync.syncNow();

      // The edit must survive: marking it clean would lose the new name.
      final stored = await inventory.findItem(id);
      expect(stored!.name, 'Cement 50kg');
      expect(stored.isDirty, isTrue);
    });
  });

  group('pull', () {
    test('applies server rows and advances the cursor', () async {
      api.seed('items', {
        'id': 'remote-1',
        'user_id': userId,
        'created_at': 1,
        'updated_at': 1,
        'deleted_at': null,
        'name': 'Pulled item',
        'code': 'P1',
        'unit': 'pcs',
        'sale_price': 5000,
        'purchase_price': 4000,
        'low_stock_threshold': null,
        'category': null,
        'hsn_code': null,
        'tax_rate_bp': 0,
      });

      sync.start(userId);
      await sync.syncNow();

      final item = await inventory.findItem('remote-1');
      expect(item, isNotNull);
      expect(item!.name, 'Pulled item');
      expect(item.isDirty, isFalse);
      expect(await syncDao.cursorFor('items'), greaterThan(0));

      // A second cycle must not re-apply the same rows.
      final cursorAfterFirst = await syncDao.cursorFor('items');
      await sync.syncNow();
      expect(await syncDao.cursorFor('items'), cursorAfterFirst);
    });

    test('discards a pulled row that has unsynced local edits', () async {
      final id = await inventory.createItem(userId: userId, name: 'Local name');
      api.seed('items', {
        'id': id,
        'user_id': userId,
        'created_at': 1,
        'updated_at': 1,
        'deleted_at': null,
        'name': 'Stale server name',
        'unit': 'pcs',
        'sale_price': 0,
        'purchase_price': 0,
        'tax_rate_bp': 0,
      });

      // Pull only: never let the push clean the row first.
      api.failWith = null;
      final cursor = await syncDao.cursorFor('items');
      expect(cursor, 0);

      sync.start(userId);
      await sync.syncNow();

      final item = await inventory.findItem(id);
      expect(item!.name, 'Local name');
    });

    test('rebuilds the stock cache from pulled movements', () async {
      // A fresh install: items and movements arrive, stock_qty does not.
      api.seed('items', {
        'id': 'item-9',
        'user_id': userId,
        'created_at': 1,
        'updated_at': 1,
        'deleted_at': null,
        'name': 'Restored item',
        'unit': 'pcs',
        'sale_price': 1000,
        'purchase_price': 800,
        'tax_rate_bp': 0,
      });
      for (final delta in [40000, -5000, -2500]) {
        api.seed('stock_movements', {
          'id': 'mv-$delta',
          'user_id': userId,
          'created_at': 1,
          'updated_at': 1,
          'deleted_at': null,
          'item_id': 'item-9',
          'qty_delta': delta,
          'unit_cost': 800,
          'reason': MovementReason.purchase.wire,
          'source_type': null,
          'source_id': null,
          'occurred_at': 1,
          'note': null,
        });
      }

      sync.start(userId);
      await sync.syncNow();

      final item = await inventory.findItem('item-9');
      expect(item!.stockQty, 32500);
      expect(await inventory.stockFromLedger('item-9'), 32500);
    });
  });

  group('without a backend configured', () {
    test('local writes never look like they are waiting to be sent', () async {
      final localOnly = SyncService(db: db, connectivity: net, clock: clock);
      addTearDown(localOnly.stop);

      await localOnly.start(userId);
      expect(localOnly.currentStatus.phase, SyncPhase.inactive);

      await inventory.createItem(userId: userId, name: 'Local item');
      // Let the pending-count stream deliver.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(localOnly.currentStatus.phase, SyncPhase.inactive);
    });
  });

  group('when things go wrong', () {
    test('offline is reported as offline, and nothing is lost', () async {
      await inventory.createItem(userId: userId, name: 'Washer');
      net.online = false;

      sync.start(userId);
      await sync.syncNow();

      expect(sync.currentStatus.phase, SyncPhase.offline);
      expect(sync.currentStatus.pendingCount, 1);
      expect(api.pushCalls, 0);
      expect(await syncDao.pendingCount(), 1);
    });

    test('a transient failure stays offline rather than alarming anyone',
        () async {
      await inventory.createItem(userId: userId, name: 'Nail');
      api.failWith = TransientSyncException('connection reset');

      sync.start(userId);
      await sync.syncNow();

      expect(sync.currentStatus.phase, SyncPhase.offline);
      expect(await syncDao.pendingCount(), 1);
    });

    test('a rejected payload surfaces as a real failure with a message',
        () async {
      await inventory.createItem(userId: userId, name: 'Bad row');
      api.failWith = PermanentSyncException('column "name" violates not-null');

      sync.start(userId);
      await sync.syncNow();

      expect(sync.currentStatus.phase, SyncPhase.failed);
      expect(sync.currentStatus.message, contains('not-null'));

      final log = await syncDao.watchLog().first;
      expect(log.any((entry) => !entry.ok), isTrue);
    });
  });
}
