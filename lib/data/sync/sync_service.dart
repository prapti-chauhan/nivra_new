import 'dart:async';

import '../../core/clock.dart';
import '../../domain/sync_status.dart';
import '../db/database.dart';
import '../remote/mappers.dart';
import '../remote/sync_api.dart';
import 'connectivity_monitor.dart';

/// Pushes what this device has changed, pulls what it has not seen, and keeps
/// Ramesh informed about which of those is true right now.
///
/// One device holds the account at a time, so there is no merge step. A row
/// that is dirty locally is by definition newer than the server's copy, and a
/// pulled row that collides with a dirty one is discarded rather than merged.
class SyncService {
  SyncService({
    required AppDatabase db,
    required this.connectivity,
    SyncApi? api,
    Clock clock = const Clock(),
  })  : _db = db,
        // ignore: prefer_initializing_formals
        _api = api,
        // ignore: prefer_initializing_formals
        _clock = clock,
        _syncDao = SyncDao(db);

  final AppDatabase _db;
  final SyncApi? _api;
  final Clock _clock;
  final SyncDao _syncDao;
  final ConnectivityMonitor connectivity;

  final _status = StreamController<SyncStatus>.broadcast();
  StreamSubscription<int>? _pendingSub;
  StreamSubscription<bool>? _onlineSub;
  Timer? _retryTimer;

  String? _userId;
  bool _running = false;
  SyncStatus _current = const SyncStatus.inactive();

  Stream<SyncStatus> get status => _status.stream;
  SyncStatus get currentStatus => _current;

  bool get isConfigured => _api != null;

  /// Begins watching for work and for the network coming back.
  Future<void> start(String userId) async {
    _userId = userId;

    await _pendingSub?.cancel();
    _pendingSub = _syncDao.watchPendingCount().listen((pending) {
      // Never silently downgrade a failure into a tidy "pending".
      if (_current.phase == SyncPhase.failed) {
        _emit(_current.copyWith(pendingCount: pending));
        return;
      }
      _emit(
        _current.copyWith(
          pendingCount: pending,
          phase: switch (_current.phase) {
            // `inactive` means there is no backend to be behind, so a local
            // write must not turn the indicator into "1 waiting".
            SyncPhase.inactive ||
            SyncPhase.syncing ||
            SyncPhase.offline =>
              _current.phase,
            _ => pending > 0 ? SyncPhase.pending : SyncPhase.synced,
          },
        ),
      );
      if (pending > 0) unawaited(syncNow());
    });

    await _onlineSub?.cancel();
    _onlineSub = connectivity.onChange.listen((online) {
      if (online) {
        unawaited(syncNow());
      } else {
        _emit(_current.copyWith(phase: SyncPhase.offline));
      }
    });

    await syncNow();
  }

  Future<void> stop() async {
    _userId = null;
    await _pendingSub?.cancel();
    await _onlineSub?.cancel();
    _retryTimer?.cancel();
    _pendingSub = null;
    _onlineSub = null;
    _emit(const SyncStatus.inactive());
  }

  Future<void> dispose() async {
    await stop();
    connectivity.dispose();
    await _status.close();
  }

  /// Runs one full cycle. Safe to call from anywhere; overlapping calls
  /// collapse into the one already running.
  Future<void> syncNow() async {
    final api = _api;
    final userId = _userId;
    if (api == null || userId == null) {
      _emit(const SyncStatus.inactive());
      return;
    }
    if (_running) return;

    if (!await connectivity.isOnline()) {
      _emit(
        _current.copyWith(
          phase: SyncPhase.offline,
          pendingCount: await _syncDao.pendingCount(),
        ),
      );
      return;
    }

    _running = true;
    _retryTimer?.cancel();
    _emit(_current.copyWith(phase: SyncPhase.syncing));

    try {
      for (final table in SyncTables.pushOrder) {
        await _push(api, table);
      }
      for (final table in SyncTables.pushOrder) {
        await _pull(api, table);
      }

      // Movements, ledger entries and payments may have arrived from another
      // install. None of the totals they feed are ever pulled, so every cache
      // is recomputed from the rows that define it.
      final repair = await _db.rebuildAllCaches();
      if (repair.foundProblems) {
        await _syncDao.log(
          direction: 'pull',
          table: 'caches',
          rowCount: repair.total,
          ok: true,
          detail: repair.toString(),
        );
      }

      final pending = await _syncDao.pendingCount();
      _emit(
        SyncStatus(
          phase: pending > 0 ? SyncPhase.pending : SyncPhase.synced,
          pendingCount: pending,
          lastSyncedAtMillis: _clock.nowMillis(),
        ),
      );
    } on TransientSyncException catch (e) {
      // Not a failure Ramesh needs to see. The shop has bad coverage; that is
      // the normal case, and the work is still safe on the device.
      await _syncDao.log(
        direction: 'push',
        table: 'all',
        rowCount: 0,
        ok: false,
        detail: e.message,
      );
      _emit(
        _current.copyWith(
          phase: SyncPhase.offline,
          pendingCount: await _syncDao.pendingCount(),
        ),
      );
      _scheduleRetry();
    } on PermanentSyncException catch (e) {
      await _syncDao.log(
        direction: 'push',
        table: 'all',
        rowCount: 0,
        ok: false,
        detail: e.message,
      );
      _emit(
        SyncStatus(
          phase: SyncPhase.failed,
          pendingCount: await _syncDao.pendingCount(),
          lastSyncedAtMillis: _current.lastSyncedAtMillis,
          message: e.message,
        ),
      );
    } finally {
      _running = false;
    }
  }

  // --- push ----------------------------------------------------------------

  Future<void> _push(SyncApi api, String table) async {
    final (rows, stamps) = await _dirtyPayload(table);
    if (rows.isEmpty) return;

    final acks = await api.push(table, rows);
    for (final ack in acks) {
      final pushedUpdatedAt = stamps[ack.id];
      if (pushedUpdatedAt == null) continue;
      await _syncDao.markPushed(
        table: table,
        id: ack.id,
        pushedUpdatedAt: pushedUpdatedAt,
        serverUpdatedAt: ack.serverUpdatedAt,
      );
    }
    await _syncDao.log(
      direction: 'push',
      table: table,
      rowCount: acks.length,
      ok: true,
    );
  }

  /// Returns the payloads plus the `updated_at` each row had when it was read,
  /// so a row edited while the request was in flight is not marked as synced.
  Future<(List<Map<String, dynamic>>, Map<String, int>)> _dirtyPayload(
    String table,
  ) async {
    switch (table) {
      case SyncTables.items:
        final rows = await _syncDao.dirtyItems();
        return (
          rows.map(RowMappers.itemToJson).toList(),
          {for (final r in rows) r.id: r.updatedAt},
        );
      case SyncTables.stockMovements:
        final rows = await _syncDao.dirtyMovements();
        return (
          rows.map(RowMappers.movementToJson).toList(),
          {for (final r in rows) r.id: r.updatedAt},
        );
      case SyncTables.businessProfiles:
        final rows = await _syncDao.dirtyProfiles();
        return (
          rows.map(RowMappers.profileToJson).toList(),
          {for (final r in rows) r.id: r.updatedAt},
        );
      case SyncTables.customers:
        final rows = await _syncDao.dirtyCustomers();
        return (
          rows.map(BillingMappers.customerToJson).toList(),
          {for (final r in rows) r.id: r.updatedAt},
        );
      case SyncTables.bills:
        final rows = await _syncDao.dirtyBills();
        return (
          rows.map(BillingMappers.billToJson).toList(),
          {for (final r in rows) r.id: r.updatedAt},
        );
      case SyncTables.billLines:
        final rows = await _syncDao.dirtyBillLines();
        return (
          rows.map(BillingMappers.billLineToJson).toList(),
          {for (final r in rows) r.id: r.updatedAt},
        );
      case SyncTables.billRevisions:
        final rows = await _syncDao.dirtyBillRevisions();
        return (
          rows.map(BillingMappers.billRevisionToJson).toList(),
          {for (final r in rows) r.id: r.updatedAt},
        );
      case SyncTables.ledgerEntries:
        final rows = await _syncDao.dirtyLedgerEntries();
        return (
          rows.map(BillingMappers.ledgerToJson).toList(),
          {for (final r in rows) r.id: r.updatedAt},
        );
      case SyncTables.payments:
        final rows = await _syncDao.dirtyPayments();
        return (
          rows.map(BillingMappers.paymentToJson).toList(),
          {for (final r in rows) r.id: r.updatedAt},
        );
      case SyncTables.suppliers:
        final rows = await _syncDao.dirtySuppliers();
        return (
          rows.map(BillingMappers.supplierToJson).toList(),
          {for (final r in rows) r.id: r.updatedAt},
        );
      case SyncTables.purchases:
        final rows = await _syncDao.dirtyPurchases();
        return (
          rows.map(BillingMappers.purchaseToJson).toList(),
          {for (final r in rows) r.id: r.updatedAt},
        );
      case SyncTables.purchaseLines:
        final rows = await _syncDao.dirtyPurchaseLines();
        return (
          rows.map(BillingMappers.purchaseLineToJson).toList(),
          {for (final r in rows) r.id: r.updatedAt},
        );
      default:
        return (const <Map<String, dynamic>>[], const <String, int>{});
    }
  }

  // --- pull ----------------------------------------------------------------

  Future<void> _pull(SyncApi api, String table) async {
    final cursor = await _syncDao.cursorFor(table);
    final rows = await api.pull(table, since: cursor);
    if (rows.isEmpty) return;

    var highest = cursor;
    var applied = 0;
    var skipped = 0;

    await _db.transaction(() async {
      for (final json in rows) {
        final stamp = (json[SyncApi.serverStampColumn] as num?)?.toInt() ?? 0;
        if (stamp > highest) highest = stamp;

        final id = json['id'] as String?;
        if (id == null) continue;

        if (await _syncDao.isLocallyDirty(table, id)) {
          skipped++;
          continue;
        }

        switch (table) {
          case SyncTables.items:
            await _syncDao.upsertPulledItem(RowMappers.itemFromJson(json));
          case SyncTables.stockMovements:
            await _syncDao
                .upsertPulledMovement(RowMappers.movementFromJson(json));
          case SyncTables.businessProfiles:
            await _syncDao.upsertPulledProfile(RowMappers.profileFromJson(json));
          case SyncTables.customers:
            await _syncDao
                .upsertPulledCustomer(BillingMappers.customerFromJson(json));
          case SyncTables.bills:
            await _syncDao.upsertPulledBill(BillingMappers.billFromJson(json));
          case SyncTables.billLines:
            await _syncDao
                .upsertPulledBillLine(BillingMappers.billLineFromJson(json));
          case SyncTables.billRevisions:
            await _syncDao.upsertPulledBillRevision(
                BillingMappers.billRevisionFromJson(json));
          case SyncTables.ledgerEntries:
            await _syncDao
                .upsertPulledLedgerEntry(BillingMappers.ledgerFromJson(json));
          case SyncTables.payments:
            await _syncDao
                .upsertPulledPayment(BillingMappers.paymentFromJson(json));
          case SyncTables.suppliers:
            await _syncDao
                .upsertPulledSupplier(BillingMappers.supplierFromJson(json));
          case SyncTables.purchases:
            await _syncDao
                .upsertPulledPurchase(BillingMappers.purchaseFromJson(json));
          case SyncTables.purchaseLines:
            await _syncDao.upsertPulledPurchaseLine(
                BillingMappers.purchaseLineFromJson(json));
        }
        applied++;
      }
    });

    if (highest > cursor) await _syncDao.setCursor(table, highest);
    await _syncDao.log(
      direction: 'pull',
      table: table,
      rowCount: applied,
      ok: true,
      detail: skipped > 0 ? '$skipped kept local (unsynced edits)' : null,
    );
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 30), () {
      if (_userId != null) unawaited(syncNow());
    });
  }

  void _emit(SyncStatus status) {
    _current = status;
    if (!_status.isClosed) _status.add(status);
  }
}
