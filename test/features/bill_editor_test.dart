import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:nivra_new/app/providers.dart';
import 'package:nivra_new/core/theme.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/data/sync/connectivity_monitor.dart';
import 'package:nivra_new/data/sync/sync_service.dart';
import 'package:nivra_new/domain/billing.dart';
import 'package:nivra_new/features/auth/auth_repository.dart';
import 'package:nivra_new/features/billing/bill_draft.dart';
import 'package:nivra_new/features/billing/bill_editor_screen.dart';

const testUser = NivraUser(id: 'user-1', email: 'ramesh@shop.in');

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late String boltId;
  late String cementId;
  String? savedBillId;

  Widget harness() {
    final router = GoRouter(
      initialLocation: '/bills/new',
      routes: [
        GoRoute(
          path: '/bills/new',
          builder: (_, _) => const BillEditorScreen(),
        ),
        GoRoute(
          path: '/bills/:id',
          builder: (_, state) {
            savedBillId = state.pathParameters['id'];
            return const Scaffold(body: Text('SAVED'));
          },
        ),
      ],
    );
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: NivraTheme.light(),
        routerConfig: router,
      ),
    );
  }

  setUp(() async {
    savedBillId = null;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((ref) => Stream.value(testUser)),
        syncServiceProvider.overrideWith(
          (ref) => SyncService(
            db: db,
            connectivity: FakeConnectivityMonitor(online: false),
          ),
        ),
      ],
    );

    final inventory = container.read(inventoryDaoProvider);
    boltId = await inventory.createItem(
      userId: testUser.id,
      name: 'Hex bolt 16mm',
      code: 'HB16',
      salePrice: 1450,
      purchasePrice: 1000,
      openingStock: 100000,
    );
    cementId = await inventory.createItem(
      userId: testUser.id,
      name: 'Cement bag 50kg',
      code: 'CEM',
      salePrice: 42000,
      purchasePrice: 38000,
      openingStock: 20000,
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  testWidgets('one tap on a result puts it on the bill', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('bill-result-$boltId')));
    await tester.pumpAndSettle();

    final draft = container.read(billDraftProvider);
    expect(draft.lines, hasLength(1));
    expect(draft.lines.single.qty, 1000, reason: 'quantity defaults to 1');
    expect(draft.totals.total, 1450);
    expect(find.byKey(const Key('bill-total')), findsOneWidget);
  });

  testWidgets('tapping the same result again means two of those, not two lines',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(Key('bill-result-$boltId')));
      await tester.pumpAndSettle();
    }

    final draft = container.read(billDraftProvider);
    expect(draft.lines, hasLength(1));
    expect(draft.lines.single.qty, 3000);
    expect(draft.totals.total, 4350);
  });

  testWidgets('the search clears after each add so the next item is ready',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('bill-item-search')), 'cem');
    await tester.pumpAndSettle();
    expect(find.text('Hex bolt 16mm'), findsNothing);

    await tester.tap(find.byKey(Key('bill-result-$cementId')));
    await tester.pumpAndSettle();

    // Search reset, so the next item is two characters away rather than
    // needing a manual clear first.
    expect(container.read(billItemSearchProvider), '');
    expect(find.text('Hex bolt 16mm'), findsOneWidget);
  });

  testWidgets('a bill starts as a cash sale with nobody attached',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text('Cash sale'), findsOneWidget);
    expect(container.read(billDraftProvider).customerId, isNull);
    expect(container.read(billDraftProvider).credit, isFalse);
  });

  testWidgets('credit is refused until somebody is there to owe the money',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('bill-result-$boltId')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('bill-credit-toggle')));
    await tester.pumpAndSettle();

    expect(container.read(billDraftProvider).credit, isFalse);
    expect(find.text('Credit needs a customer. Who owes you?'), findsOneWidget);
  });

  testWidgets('saving writes the bill, moves stock and records the payment',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('bill-result-$boltId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('bill-result-$boltId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('bill-result-$cementId')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('bill-save')));
    await tester.pump();
    // The write really touches SQLite, which the fake-async zone will not let
    // progress, and the save button's spinner means pumpAndSettle would never
    // return. So: let real time pass, then pump the navigation through.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();
    await tester.pump();

    expect(savedBillId, isNotNull, reason: 'should land on the bill it made');

    final bill = await container.read(billingDaoProvider).findBill(savedBillId!);
    expect(bill!.total, 44900); // 2 * 14.50 + 420.00
    expect(bill.amountPaid, 44900, reason: 'cash sale is paid by default');
    expect(
      paymentStatusFor(totalPaise: bill.total, paidPaise: bill.amountPaid),
      PaymentStatus.paid,
    );

    final inventory = container.read(inventoryDaoProvider);
    expect((await inventory.findItem(boltId))!.stockQty, 98000);
    expect((await inventory.findItem(cementId))!.stockQty, 19000);

    expect(container.read(billDraftProvider).isEmpty, isTrue,
        reason: 'the next bill starts empty');
  });

  testWidgets('the save button cannot fire on an empty bill', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('bill-save')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('No items yet'), findsOneWidget);
  });
}
