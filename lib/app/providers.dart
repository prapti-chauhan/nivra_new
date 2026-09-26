import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import 'dart:typed_data';

import '../data/db/database.dart';
import '../data/pdf/invoice_fonts.dart';
import '../data/pdf/invoice_fonts_flutter.dart';
import '../data/pdf/invoice_from_rows.dart';
import '../data/pdf/invoice_pdf.dart';
import '../domain/invoice.dart';
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


// ---------------------------------------------------------------------------
// Suppliers and purchases.
// ---------------------------------------------------------------------------

final purchaseDaoProvider = Provider<PurchaseDao>(
  (ref) => PurchaseDao(ref.watch(databaseProvider)),
);

final supplierSearchProvider =
    NotifierProvider<SupplierSearch, String>(SupplierSearch.new);

class SupplierSearch extends Notifier<String> {
  @override
  String build() => '';

  void update(String value) => state = value;
}

final suppliersProvider = StreamProvider<List<Supplier>>((ref) {
  final search = ref.watch(supplierSearchProvider);
  return ref.watch(purchaseDaoProvider).watchSuppliers(search: search);
});

final supplierProvider = StreamProvider.family<Supplier?, String>(
  (ref, id) => ref.watch(purchaseDaoProvider).watchSupplier(id),
);

final supplierLedgerProvider = StreamProvider.family<List<LedgerEntry>, String>(
  (ref, id) => ref.watch(purchaseDaoProvider).watchSupplierLedger(id),
);

/// What the shop owes in total, positive.
final totalPayableProvider = StreamProvider<int>(
  (ref) => ref.watch(purchaseDaoProvider).watchTotalPayable(),
);

/// Search inside the purchase editor, kept apart from the bill editor's so a
/// half-finished purchase and a half-finished bill never disturb each other.
final purchaseItemSearchProvider =
    NotifierProvider<PurchaseItemSearch, String>(PurchaseItemSearch.new);

class PurchaseItemSearch extends Notifier<String> {
  @override
  String build() => '';

  void update(String value) => state = value;
}

final purchaseItemResultsProvider = StreamProvider<List<Item>>((ref) {
  final search = ref.watch(purchaseItemSearchProvider);
  if (search.trim().isEmpty) return Stream.value(const <Item>[]);
  return ref.watch(inventoryDaoProvider).watchItems(search: search);
});

final purchasesSearchProvider =
    NotifierProvider<PurchasesSearch, String>(PurchasesSearch.new);

class PurchasesSearch extends Notifier<String> {
  @override
  String build() => '';

  void update(String value) => state = value;
}

final purchasesProvider = StreamProvider<List<Purchase>>((ref) {
  final search = ref.watch(purchasesSearchProvider);
  return ref.watch(purchaseDaoProvider).watchPurchases(search: search);
});

final purchasesForSupplierProvider =
    StreamProvider.family<List<Purchase>, String>(
  (ref, id) => ref.watch(purchaseDaoProvider).watchPurchasesFor(id),
);

final purchaseProvider = StreamProvider.family<Purchase?, String>(
  (ref, id) => ref.watch(purchaseDaoProvider).watchPurchase(id),
);

final purchaseLinesProvider =
    StreamProvider.family<List<PurchaseLine>, String>(
  (ref, id) => ref.watch(purchaseDaoProvider).watchPurchaseLines(id),
);

// ---------------------------------------------------------------------------
// The bill PDF.
// ---------------------------------------------------------------------------

/// Parsed once per run. Font parsing is not free and the bytes never change.
final invoiceFontsProvider = FutureProvider<InvoiceFonts>(
  (ref) => loadInvoiceFontsFromAssets(),
);

/// What the customer's copy will say, assembled from the stored rows.
///
/// Null while the bill is still loading, so callers can tell "not ready" from
/// "no such bill".
final invoiceDocumentProvider =
    Provider.family<InvoiceDocument?, String>((ref, billId) {
  final bill = ref.watch(billProvider(billId)).value;
  if (bill == null) return null;

  final lines = ref.watch(billLinesProvider(billId)).value ?? const <BillLine>[];
  final profile = ref.watch(businessProfileProvider).value;
  final customerId = bill.customerId;
  final customer =
      customerId == null ? null : ref.watch(customerProvider(customerId)).value;

  return invoiceFromRows(
    bill: bill,
    lines: lines,
    customer: customer,
    profile: profile,
  );
});

/// Rendered fresh every time rather than cached to disk.
///
/// A bill can be revised, and a stored PDF would quietly show superseded
/// numbers — exactly wrong for the dispute this document is meant to settle.
final invoicePdfProvider =
    FutureProvider.family<Uint8List?, String>((ref, billId) async {
  final doc = ref.watch(invoiceDocumentProvider(billId));
  if (doc == null) return null;
  final fonts = await ref.watch(invoiceFontsProvider.future);
  return renderInvoicePdf(doc, fonts);
});
