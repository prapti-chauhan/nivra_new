import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../data/db/database.dart';
import '../data/pdf/invoice_fonts.dart';
import '../data/pdf/invoice_fonts_flutter.dart';
import '../data/pdf/invoice_from_rows.dart';
import '../data/pdf/invoice_pdf.dart';
import '../data/reports/report_queries.dart';
import '../domain/cashbook.dart';
import '../domain/invoice.dart';
import '../domain/reports.dart';
import '../data/remote/supabase_config.dart';
import '../data/remote/sync_api.dart';
import '../data/sync/connectivity_monitor.dart';
import '../data/sync/logo_sync.dart';
import '../data/sync/sync_service.dart';
import '../domain/sync_status.dart';
import '../features/auth/auth_repository.dart';
import '../features/settings/logo_picker.dart';

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

/// This phone's copy of the shop logo, kept apart from the database.
final logoFilesProvider = Provider<LogoFiles>(
  (ref) => LogoFiles(() async {
    final base = await getApplicationDocumentsDirectory();
    return Directory('${base.path}/logo');
  }),
);

final logoPickerProvider = Provider<LogoPicker>(
  (ref) => ImagePickerLogoPicker(),
);

/// The logo as bytes, or null when there is none or the file has gone.
final logoBytesProvider = FutureProvider<Uint8List?>((ref) async {
  final path = ref.watch(
    businessProfileProvider.select((profile) => profile.value?.logoPath),
  );
  return ref.watch(logoFilesProvider).read(path);
});

final syncServiceProvider = Provider<SyncService>((ref) {
  final db = ref.watch(databaseProvider);
  final configured = SupabaseConfig.isConfigured;
  final service = SyncService(
    db: db,
    connectivity: PlatformConnectivityMonitor(),
    api: configured ? SupabaseSyncApi(sb.Supabase.instance.client) : null,
    logoSync: configured
        ? LogoSync(
            db: db,
            storage: SupabaseLogoStorage(sb.Supabase.instance.client),
            files: ref.watch(logoFilesProvider),
          )
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

final purchaseRevisionsProvider =
    StreamProvider.family<List<PurchaseRevision>, String>(
  (ref, id) => ref.watch(purchaseDaoProvider).watchRevisions(id),
);

// ---------------------------------------------------------------------------
// Reports.
// ---------------------------------------------------------------------------

final reportQueriesProvider = Provider<ReportQueries>(
  (ref) => ReportQueries(ref.watch(databaseProvider)),
);

/// Which span the reports are looking at. Shared by every report screen so
/// choosing "This month" once means the profit screen agrees with the sales
/// screen it was opened from.
final reportPeriodProvider =
    NotifierProvider<ReportPeriodChoice, ReportSpan>(ReportPeriodChoice.new);

class ReportPeriodChoice extends Notifier<ReportSpan> {
  @override
  ReportSpan build() => const ReportSpan.preset(ReportPeriod.today);

  void choose(ReportPeriod period) => state = ReportSpan.preset(period);

  void chooseCustom({required DateTime firstDay, required DateTime lastDay}) =>
      state = ReportSpan.custom(firstDay: firstDay, lastDay: lastDay);
}

/// "Now" always comes from the database's clock, never `DateTime.now()`, so a
/// test that pins the clock pins the report boundaries too.
DateTime _now(Ref ref) => DateTime.fromMillisecondsSinceEpoch(
      ref.read(databaseProvider).clock.nowMillis(),
    );

/// Every live bill in the chosen period, with its lines. The sales screen and
/// the profit screen are two views of this one list, which is what guarantees
/// they cannot disagree.
final billProfitsProvider = StreamProvider<List<BillProfit>>((ref) {
  final span = ref.watch(reportPeriodProvider);
  final range = span.rangeAt(_now(ref));
  return ref.watch(reportQueriesProvider).watchBillProfits(range);
});

final profitSummaryProvider = Provider<ProfitSummary>(
  (ref) => summarise(ref.watch(billProfitsProvider).value ?? const []),
);

final moneyDaoProvider = Provider<MoneyDao>(
  (ref) => MoneyDao(ref.watch(databaseProvider)),
);

/// Expenses, other income and transfers in the chosen period. Shares the
/// period with sales and profit so the P&L cannot mix two different spans.
final moneyEntriesProvider = StreamProvider<List<MoneyEntry>>((ref) {
  final span = ref.watch(reportPeriodProvider);
  final range = span.rangeAt(_now(ref));
  return ref.watch(reportQueriesProvider).watchMoneyEntries(range);
});

int _sumOf(List<MoneyEntry> entries, MoneyKind kind) => entries
    .where((e) => e.kind == kind.wire)
    .fold<int>(0, (sum, e) => sum + e.amount);

/// Sales, cost of goods, other income and expenses for the period. Transfers
/// are in neither side: moving money between cash and bank is not earning or
/// spending it.
final profitAndLossProvider = Provider<ProfitAndLoss>((ref) {
  final goods = ref.watch(profitSummaryProvider);
  final entries = ref.watch(moneyEntriesProvider).value ?? const <MoneyEntry>[];
  return ProfitAndLoss(
    salesPaise: goods.salesPaise,
    costOfGoodsPaise: goods.costPaise,
    otherIncomePaise: _sumOf(entries, MoneyKind.income),
    expensesPaise: _sumOf(entries, MoneyKind.expense),
  );
});

final cashPositionProvider = StreamProvider<CashPosition>(
  (ref) => ref.watch(moneyDaoProvider).watchCashPosition(),
);

final cashLedgerProvider = StreamProvider.family<List<LedgerEntry>, MoneyMethod>(
  (ref, method) => ref.watch(moneyDaoProvider).watchAccountLedger(method),
);

final moneyEntryProvider = StreamProvider.family<MoneyEntry?, String>(
  (ref, id) => ref.watch(moneyDaoProvider).watchEntry(id),
);

final recentCategoriesProvider =
    StreamProvider.family<List<String>, MoneyKind>(
  (ref, kind) => ref.watch(moneyDaoProvider).watchRecentCategories(kind),
);

final owedToYouProvider = StreamProvider<List<Customer>>(
  (ref) => ref.watch(reportQueriesProvider).watchOwedToYou(),
);

final youOweProvider = StreamProvider<List<Supplier>>(
  (ref) => ref.watch(reportQueriesProvider).watchYouOwe(),
);

final stockItemsProvider = StreamProvider<List<Item>>(
  (ref) => ref.watch(reportQueriesProvider).watchStockItems(),
);

/// How far back "how fast is this selling" looks. A month smooths out a slow
/// week without hiding a real change in demand.
const int reorderWindowDays = 30;

final reorderProvider = StreamProvider<List<ReorderEntry>>((ref) {
  final since = _now(ref).subtract(const Duration(days: reorderWindowDays));
  return ref.watch(reportQueriesProvider).watchReorder(
        sinceMillis: since.millisecondsSinceEpoch,
        windowDays: reorderWindowDays,
      );
});

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
  final logo = await ref.watch(logoBytesProvider.future);
  return renderInvoicePdf(doc, fonts, logo: logo);
});
