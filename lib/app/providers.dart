import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../data/db/database.dart';
import '../data/remote/supabase_config.dart';
import '../data/remote/sync_api.dart';
import '../data/sync/connectivity_monitor.dart';
import '../data/sync/sync_service.dart';
import '../domain/sync_status.dart';
import '../features/auth/auth_repository.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final inventoryDaoProvider = Provider<InventoryDao>(
  (ref) => InventoryDao(ref.watch(databaseProvider)),
);

final syncDaoProvider = Provider<SyncDao>(
  (ref) => SyncDao(ref.watch(databaseProvider)),
);

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  if (!SupabaseConfig.isConfigured) return LocalOnlyAuthRepository();
  return SupabaseAuthRepository(sb.Supabase.instance.client.auth);
});

final syncServiceProvider = Provider<SyncService>((ref) {
  final service = SyncService(
    db: ref.watch(databaseProvider),
    connectivity: PlatformConnectivityMonitor(),
    api: SupabaseConfig.isConfigured
        ? SupabaseSyncApi(sb.Supabase.instance.client)
        : null,
  );
  ref.onDispose(service.dispose);
  return service;
});

final currentUserProvider = StreamProvider<NivraUser?>(
  (ref) => ref.watch(authRepositoryProvider).watchUser(),
);

final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  final service = ref.watch(syncServiceProvider);
  return service.status;
});

/// Pending count comes straight from the database rather than from the sync
/// service, so the badge is correct the instant a row is written — before any
/// network call is attempted.
final pendingCountProvider = StreamProvider<int>(
  (ref) => ref.watch(syncDaoProvider).watchPendingCount(),
);

final itemSearchProvider = NotifierProvider<ItemSearch, String>(ItemSearch.new);

class ItemSearch extends Notifier<String> {
  @override
  String build() => '';

  void update(String value) => state = value;
}

final itemsProvider = StreamProvider<List<Item>>((ref) {
  final search = ref.watch(itemSearchProvider);
  return ref.watch(inventoryDaoProvider).watchItems(search: search);
});

final itemProvider = StreamProvider.family<Item?, String>(
  (ref, id) => ref.watch(inventoryDaoProvider).watchItem(id),
);

final itemMovementsProvider =
    StreamProvider.family<List<StockMovement>, String>(
  (ref, id) => ref.watch(inventoryDaoProvider).watchMovements(id),
);

final syncLogProvider = StreamProvider<List<SyncLog>>(
  (ref) => ref.watch(syncDaoProvider).watchLog(limit: 60),
);

// --- slice two: customers and billing --------------------------------------

final partyDaoProvider = Provider<PartyDao>(
  (ref) => PartyDao(ref.watch(databaseProvider)),
);

final billingDaoProvider = Provider<BillingDao>(
  (ref) => BillingDao(ref.watch(databaseProvider)),
);

/// Search term inside the bill editor. Separate from the items screen's own
/// search so leaving a half-typed bill does not disturb the item list.
final billItemSearchProvider =
    NotifierProvider<BillItemSearch, String>(BillItemSearch.new);

class BillItemSearch extends Notifier<String> {
  @override
  String build() => '';

  void update(String value) => state = value;
}

final billItemResultsProvider = StreamProvider<List<Item>>((ref) {
  final search = ref.watch(billItemSearchProvider);
  return ref.watch(inventoryDaoProvider).watchItems(search: search);
});

final billsSearchProvider =
    NotifierProvider<BillsSearch, String>(BillsSearch.new);

class BillsSearch extends Notifier<String> {
  @override
  String build() => '';

  void update(String value) => state = value;
}

final billsProvider = StreamProvider<List<Bill>>((ref) {
  final search = ref.watch(billsSearchProvider);
  return ref.watch(billingDaoProvider).watchBills(search: search);
});

final billProvider = StreamProvider.family<Bill?, String>(
  (ref, id) => ref.watch(billingDaoProvider).watchBill(id),
);

final billLinesProvider = StreamProvider.family<List<BillLine>, String>(
  (ref, id) => ref.watch(billingDaoProvider).watchLines(id),
);

final billRevisionsProvider =
    StreamProvider.family<List<BillRevision>, String>(
  (ref, id) => ref.watch(billingDaoProvider).watchRevisions(id),
);

final billPaymentsProvider = StreamProvider.family<List<Payment>, String>(
  (ref, id) => ref.watch(billingDaoProvider).watchPayments(id),
);

final customerSearchProvider =
    NotifierProvider<CustomerSearch, String>(CustomerSearch.new);

class CustomerSearch extends Notifier<String> {
  @override
  String build() => '';

  void update(String value) => state = value;
}

final customersProvider = StreamProvider<List<Customer>>((ref) {
  final search = ref.watch(customerSearchProvider);
  return ref.watch(partyDaoProvider).watchCustomers(search: search);
});

final customerProvider = StreamProvider.family<Customer?, String>(
  (ref, id) => ref.watch(partyDaoProvider).watchCustomer(id),
);

final customerLedgerProvider =
    StreamProvider.family<List<LedgerEntry>, String>(
  (ref, id) => ref.watch(partyDaoProvider).watchLedger(id),
);

/// What the shop is owed in total.
final totalReceivableProvider = StreamProvider<int>(
  (ref) => ref.watch(partyDaoProvider).watchTotalReceivable(),
);

final businessProfileProvider = StreamProvider<BusinessProfile?>((ref) {
  final userId = ref.watch(currentUserProvider).value?.id;
  if (userId == null) return Stream.value(null);
  return ref.watch(billingDaoProvider).watchProfile(userId);
});
