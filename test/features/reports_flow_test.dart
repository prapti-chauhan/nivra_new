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

const user = NivraUser(id: 'user-1', email: 'ramesh@shop.in');

/// Drives the real router, because the thing worth checking is not that each
/// report screen draws but that a row in one tab can open a bill that lives in
/// another and still come back.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late FixedClock clock;

  final now = DateTime(2026, 10, 7, 15, 30);

  setUp(() {
    clock = FixedClock(now.millisecondsSinceEpoch);
    db = AppDatabase.forTesting(NativeDatabase.memory(), clock: clock);
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

  Future<void> openApp(WidgetTester tester, String location) async {
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
    router.go(location);
    await tester.pumpAndSettle();
  }

  Future<String> sellBolts({int cost = 1800}) async {
    // With no prefix a bill is just "1", which is not a string worth asserting
    // on. A real shop sets one, so the test does too.
    await BillingDao(db).updateProfile(userId: user.id, invoicePrefix: 'INV-');
    final inventory = InventoryDao(db);
    final id = await inventory.createItem(
      userId: user.id,
      name: '16mm hex bolt',
      salePrice: 2500,
      purchasePrice: cost,
      openingStock: 100000,
    );
    return BillingDao(db).saveBill(
      userId: user.id,
      lines: [
        BillLineDraft(
          itemId: id,
          name: '16mm hex bolt',
          unit: 'pcs',
          qty: 4000,
          unitPrice: 2500,
          unitCost: cost,
        ),
      ],
    );
  }

  testWidgets('the overview shows sales and profit read from real bills',
      (tester) async {
    await sellBolts();
    await openApp(tester, '/reports');

    expect(find.text('Sales'), findsOneWidget);
    expect(find.text('₹100.00'), findsWidgets);
    expect(find.text('Profit on goods'), findsOneWidget);
    // With no expenses recorded, goods profit and net profit are the same
    // figure, so it legitimately appears on both tiles.
    expect(find.text('₹28.00'), findsNWidgets(2));
    expect(find.text('28% of sales'), findsOneWidget);
  });

  testWidgets('a line with no cost warns instead of quietly inflating profit',
      (tester) async {
    await sellBolts(cost: 0);
    await openApp(tester, '/reports');

    expect(find.textContaining('no cost on record'), findsOneWidget);
  });

  testWidgets('profit opens into the bill and the line it came from',
      (tester) async {
    await sellBolts();
    await openApp(tester, '/reports');

    await tester.tap(find.text('Profit on goods'));
    await tester.pumpAndSettle();

    expect(find.text('Profit'), findsWidgets);
    expect(find.text('INV-1'), findsOneWidget);

    await tester.tap(find.text('INV-1'));
    await tester.pumpAndSettle();

    // The line, with the cost it was sold against, openly stated.
    expect(find.text('16mm hex bolt'), findsOneWidget);
    expect(find.textContaining('cost ₹18.00'), findsOneWidget);
  });

  testWidgets('a bill opened from a report comes back to the report',
      (tester) async {
    await sellBolts();
    await openApp(tester, '/reports/sales');

    expect(find.byType(ListTile), findsOneWidget);
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();

    // Now on the bill itself, which lives in the Bills tab.
    expect(find.text('Bill'), findsNothing);
    expect(find.byIcon(Icons.share_outlined), findsOneWidget);

    final router = container.read(routerProvider);
    router.pop();
    await tester.pumpAndSettle();

    // And back on the sales report, not stranded in the Bills tab.
    expect(find.text('Sales'), findsWidgets);
    expect(find.byType(ListTile), findsOneWidget);
    expect(
      router.state.matchedLocation,
      '/reports/sales',
    );
  });

  testWidgets('the tab bar has a Reports destination', (tester) async {
    await openApp(tester, '/bills');
    expect(find.text('Reports'), findsOneWidget);

    await tester.tap(find.text('Reports'));
    await tester.pumpAndSettle();

    expect(container.read(routerProvider).state.matchedLocation, '/reports');
  });

  testWidgets('who owes what keeps the two directions apart', (tester) async {
    await PartyDao(db).createCustomer(
      userId: user.id,
      name: 'Ramesh Kumar',
      openingBalance: 400000,
    );
    await PurchaseDao(db).createSupplier(
      userId: user.id,
      name: 'Verma Traders',
      openingPayable: 900000,
    );
    await openApp(tester, '/reports/owed');

    expect(find.text('Owed to you'), findsOneWidget);
    expect(find.text('You owe'), findsOneWidget);
    expect(find.text('₹4,000.00'), findsWidgets);
    expect(find.text('₹9,000.00'), findsWidgets);
    // Never a single netted figure.
    expect(find.text('₹5,000.00'), findsNothing);
  });

  testWidgets('running low explains itself when nothing is tracked',
      (tester) async {
    await openApp(tester, '/reports/reorder');
    expect(find.textContaining('Nothing is running low'), findsOneWidget);
    expect(find.textContaining('low-stock level'), findsOneWidget);
  });
  testWidgets('a missing cost is corrected from the profit report',
      (tester) async {
    await sellBolts(cost: 0);
    await openApp(tester, '/reports/profit');
    expect(find.textContaining('no cost on record'), findsOneWidget);
    // Sold for Rs 100 against nothing, so all of it counts as profit.
    await tester.tap(find.text('INV-1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cost not recorded'), findsOneWidget);

    await tester.tap(find.text('16mm hex bolt'));
    await tester.pumpAndSettle();
    expect(find.text('Cost of 16mm hex bolt'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '18');
    await tester.tap(find.text('Save cost'));
    await tester.pumpAndSettle();

    expect(find.textContaining('no cost on record'), findsNothing);
    expect(find.textContaining('cost ₹18.00 (corrected)'), findsOneWidget);
    // Rs 100 less 4 x Rs 18 is Rs 28.
    expect(find.text('₹28.00'), findsWidgets);
  });

  testWidgets('a correction with nothing sensible entered is refused',
      (tester) async {
    await sellBolts(cost: 0);
    await openApp(tester, '/reports/profit');
    await tester.tap(find.text('INV-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('16mm hex bolt'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.text('Save cost'));
    await tester.pump();

    expect(find.textContaining('more than zero'), findsOneWidget);
    final line = await db.select(db.billLines).getSingle();
    expect(line.unitCost, 0);
  });
  testWidgets('a custom range picked from the calendar filters the report',
      (tester) async {
    await BillingDao(db).updateProfile(userId: user.id, invoicePrefix: 'INV-');
    final itemId = await InventoryDao(db).createItem(
      userId: user.id,
      name: 'bolt',
      salePrice: 2500,
      purchasePrice: 1800,
      openingStock: 100000,
    );
    Future<void> sell(DateTime when) => BillingDao(db).saveBill(
          userId: user.id,
          occurredAt: when.millisecondsSinceEpoch,
          lines: [
            BillLineDraft(
              itemId: itemId,
              name: 'bolt',
              unit: 'pcs',
              qty: 4000,
              unitPrice: 2500,
              unitCost: 1800,
            ),
          ],
        );
    await sell(DateTime(2026, 10, 2, 11)); // inside the range
    await sell(DateTime(2026, 10, 3, 18)); // the last day, in the evening
    await sell(DateTime(2026, 10, 4, 9)); // just outside
    await sell(DateTime(2026, 10, 7, 10)); // today

    await openApp(tester, '/reports/sales');
    expect(find.text('INV-4'), findsOneWidget, reason: 'today is shown first');
    expect(find.text('INV-1'), findsNothing);

    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2'));
    await tester.pump();
    await tester.tap(find.text('3'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The chip now says what is being shown, and the list agrees with it.
    expect(find.text('2 Oct - 3 Oct 2026'), findsWidgets);
    expect(find.text('INV-1'), findsOneWidget);
    expect(find.text('INV-2'), findsOneWidget,
        reason: 'the evening of the last day is still in');
    expect(find.text('INV-3'), findsNothing);
    expect(find.text('INV-4'), findsNothing);
  });

  testWidgets('cancelling the calendar keeps the span he had', (tester) async {
    await openApp(tester, '/reports/sales');
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('No bills today.'), findsOneWidget);
  });
}
