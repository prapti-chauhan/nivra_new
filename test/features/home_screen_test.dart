import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/app/providers.dart';
import 'package:nivra_new/app/router.dart';
import 'package:nivra_new/core/clock.dart';
import 'package:nivra_new/core/theme.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/data/sync/connectivity_monitor.dart';
import 'package:nivra_new/data/sync/sync_service.dart';
import 'package:nivra_new/features/auth/auth_repository.dart';
import 'package:nivra_new/features/billing/bill_editor_screen.dart';
import 'package:nivra_new/features/money/money_entry_editor_screen.dart';
import 'package:nivra_new/features/reports/sales_report_screen.dart';

const user = NivraUser(id: 'user-1', email: 'ramesh@shop.in');

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  final now = DateTime(2026, 10, 15, 11, 0);

  setUp(() {
    db = AppDatabase.forTesting(
      NativeDatabase.memory(),
      clock: FixedClock(now.millisecondsSinceEpoch),
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((ref) => Stream.value(user)),
        syncServiceProvider.overrideWith(
          (ref) => SyncService(
            db: db,
            connectivity: FakeConnectivityMonitor(online: false),
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> openHome(WidgetTester tester) async {
    final router = container.read(routerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: NivraTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<String> sell({
    required String customerName,
    required int rupees,
    String? customerId,
    bool paid = true,
  }) =>
      BillingDao(db).saveBill(
        userId: user.id,
        customerId: customerId,
        customerName: customerName,
        paid: paid,
        lines: [
          BillLineDraft(
            itemId: null,
            name: 'Bolt',
            unit: 'pcs',
            qty: 1000,
            unitPrice: rupees * 100,
          ),
        ],
      );

  Future<String> addCustomer(String name) => PartyDao(db)
      .createCustomer(userId: user.id, name: name, phone: '9800000001');

  testWidgets('header shows the shop name and the two tabs', (tester) async {
    await BillingDao(db).updateProfile(userId: user.id, shopName: 'SS Traders');
    await openHome(tester);

    expect(find.text('SS Traders'), findsOneWidget);
    expect(find.text('Transaction Details'), findsOneWidget);
    expect(find.text('Party Details'), findsOneWidget);
    expect(find.byKey(const Key('home-settings')), findsOneWidget);
  });

  testWidgets('a bill is a card with a SALE chip, number, total and balance',
      (tester) async {
    await BillingDao(db).updateProfile(userId: user.id, invoicePrefix: 'INV-');
    await sell(customerName: 'Alpesh Wiring', rupees: 1200, paid: false,
        customerId: await addCustomer('Alpesh Wiring'));
    await openHome(tester);

    expect(find.text('Alpesh Wiring'), findsOneWidget);
    expect(find.text('SALE'), findsOneWidget);
    expect(find.text('#INV-1'), findsOneWidget);
    expect(find.text('15 Oct, 26'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(find.text('Balance'), findsOneWidget);
    // Unpaid: total and balance are the same figure.
    expect(find.text('₹1,200.00'), findsNWidgets(2));
  });

  testWidgets('quick links open billing and the reports', (tester) async {
    await openHome(tester);

    expect(find.text('Quick Links'), findsOneWidget);
    for (final label in ['Add Txn', 'Sale Report', 'Day Book', 'Profit & Loss']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await tester.tap(find.text('Sale Report'));
    await tester.pumpAndSettle();
    expect(find.byType(SalesReportScreen), findsOneWidget);
  });

  testWidgets('Add Txn and the Add New Sale button both start a bill',
      (tester) async {
    await openHome(tester);

    await tester.tap(find.text('Add Txn'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sale'));
    await tester.pumpAndSettle();
    expect(find.byType(BillEditorScreen), findsOneWidget);

    container.read(routerProvider).go('/bills');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('new-bill')), findsOneWidget);
    expect(find.text('Add New Sale'), findsOneWidget);
    await tester.tap(find.byKey(const Key('new-bill')));
    await tester.pumpAndSettle();
    expect(find.byType(BillEditorScreen), findsOneWidget);
  });

  testWidgets('Add Txn also offers an expense, paid at the counter',
      (tester) async {
    await openHome(tester);

    await tester.tap(find.text('Add Txn'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expense'));
    await tester.pumpAndSettle();
    expect(find.byType(MoneyEntryEditorScreen), findsOneWidget);
  });

  testWidgets('search finds a bill by customer name or by its number',
      (tester) async {
    await BillingDao(db).updateProfile(userId: user.id, invoicePrefix: 'INV-');
    await sell(customerName: 'Alpesh Wiring', rupees: 100);
    await sell(customerName: 'Indian Cardecor', rupees: 200);
    await openHome(tester);
    expect(find.text('Alpesh Wiring'), findsOneWidget);
    expect(find.text('Indian Cardecor'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('home-search')), 'cardecor');
    await tester.pumpAndSettle();
    expect(find.text('Alpesh Wiring'), findsNothing);
    expect(find.text('Indian Cardecor'), findsOneWidget);

    // Bill 1 was Alpesh's.
    await tester.enterText(find.byKey(const Key('home-search')), 'INV-1');
    await tester.pumpAndSettle();
    expect(find.text('Alpesh Wiring'), findsOneWidget);
    expect(find.text('Indian Cardecor'), findsNothing);
  });

  testWidgets('the filter narrows to unpaid bills', (tester) async {
    await sell(customerName: 'Cash Buyer', rupees: 100);
    await sell(
      customerName: 'Credit Buyer',
      rupees: 300,
      paid: false,
      customerId: await addCustomer('Credit Buyer'),
    );
    await openHome(tester);

    await tester.tap(find.byKey(const Key('home-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpaid'));
    await tester.pumpAndSettle();

    expect(find.text('Credit Buyer'), findsOneWidget);
    expect(find.text('Cash Buyer'), findsNothing);
  });

  testWidgets('Party Details lists customers with what they owe',
      (tester) async {
    await sell(
      customerName: 'Credit Buyer',
      rupees: 300,
      paid: false,
      customerId: await addCustomer('Credit Buyer'),
    );
    await openHome(tester);

    await tester.tap(find.text('Party Details'));
    await tester.pumpAndSettle();

    expect(find.text('Credit Buyer'), findsOneWidget);
    expect(find.text('owes you'), findsOneWidget);
    expect(find.text('SALE'), findsNothing);
  });

  testWidgets('the first tab is called Home', (tester) async {
    await openHome(tester);
    expect(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Home'),
    ), findsOneWidget);
  });
}
