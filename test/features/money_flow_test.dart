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
import 'package:nivra_new/domain/cashbook.dart';
import 'package:nivra_new/features/auth/auth_repository.dart';

const user = NivraUser(id: 'user-1', email: 'ramesh@shop.in');

/// Click-through against the real router, because the thing worth knowing is
/// that Ramesh can record an expense in a few taps and see it change the
/// numbers — not that each widget draws.
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
        child: MaterialApp.router(theme: NivraTheme.light(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    router.go(location);
    await tester.pumpAndSettle();
  }

  Future<void> sellBolts() async {
    final id = await InventoryDao(db).createItem(
      userId: user.id,
      name: 'bolt',
      salePrice: 2500,
      purchasePrice: 1800,
      openingStock: 100000,
    );
    await BillingDao(db).saveBill(
      userId: user.id,
      lines: [
        BillLineDraft(
          itemId: id,
          name: 'bolt',
          unit: 'pcs',
          qty: 4000,
          unitPrice: 2500,
          unitCost: 1800,
        ),
      ],
    );
  }

  testWidgets('an expense is recorded in a few taps and moves the till',
      (tester) async {
    await openApp(tester, '/reports/money');
    expect(find.text('Cash in hand'), findsOneWidget);

    await tester.tap(find.text('Expense'));
    await tester.pumpAndSettle();
    expect(find.text('New expense'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '250');
    await tester.tap(find.text('Tea & snacks'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Back on the money screen, with the till down by what was spent.
    expect(find.text('Cash and bank'), findsOneWidget);
    expect(find.text('-₹250.00'), findsOneWidget);

    final saved = await db.select(db.moneyEntries).getSingle();
    expect(saved.category, 'Tea & snacks');
    expect(saved.amount, 25000);
  });

  testWidgets('a typed category is kept, and is offered next time',
      (tester) async {
    await openApp(tester, '/reports/money/new/expense');

    await tester.enterText(find.byType(TextField).first, '80');
    await tester.enterText(find.byType(TextField).at(1), 'Puncture repair');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = await db.select(db.moneyEntries).getSingle();
    expect(saved.category, 'Puncture repair');

    container.read(routerProvider).go('/reports/money/new/expense');
    await tester.pumpAndSettle();
    expect(find.text('Puncture repair'), findsOneWidget,
        reason: 'his own category now leads the suggestions');
  });

  testWidgets('a zero amount is refused with a reason, not silently',
      (tester) async {
    await openApp(tester, '/reports/money/new/expense');
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(find.text('Enter an amount more than zero.'), findsOneWidget);
    expect(await db.select(db.moneyEntries).get(), isEmpty);
  });

  testWidgets('profit and loss subtracts what was spent', (tester) async {
    await sellBolts();
    await MoneyDao(db).addEntry(
      userId: user.id,
      kind: MoneyKind.expense,
      amount: 1500,
      category: 'Tea',
    );
    await openApp(tester, '/reports/pnl');

    // Rs 100 sold against Rs 72 is Rs 28 on goods, less Rs 15 spent.
    expect(find.text('₹28.00'), findsOneWidget);
    expect(find.text('- ₹15.00'), findsOneWidget);
    expect(find.text('₹13.00'), findsOneWidget);
    expect(find.text('Tea'), findsWidgets);
  });

  testWidgets('a loss reads as a loss', (tester) async {
    await sellBolts();
    await MoneyDao(db).addEntry(
      userId: user.id,
      kind: MoneyKind.expense,
      amount: 8000,
      category: 'Rent',
    );
    await openApp(tester, '/reports/pnl');
    // Rs 28 made, Rs 80 spent.
    expect(find.text('- ₹52.00'), findsOneWidget);
  });

  testWidgets('counting the till writes a correction he can see',
      (tester) async {
    await openApp(tester, '/reports/money');

    await tester.tap(find.text('Count the till'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '1000');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('₹1,000.00'), findsOneWidget);
    expect(find.textContaining('Corrected by +₹1,000.00'), findsOneWidget);

    // And the balance opens into the row that explains it.
    await tester.tap(find.text('Cash in hand'));
    await tester.pumpAndSettle();
    expect(find.text('Adjusted by hand'), findsOneWidget);
    expect(find.text('+₹1,000.00'), findsOneWidget);
  });

  testWidgets('deleting an entry can be undone with one tap', (tester) async {
    final id = await MoneyDao(db).addEntry(
      userId: user.id,
      kind: MoneyKind.expense,
      amount: 25000,
      category: 'Tea',
    );
    await openApp(tester, '/reports/money/entry/$id');
    expect(find.text('Edit expense'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(await MoneyDao(db).balanceOf(MoneyMethod.cash), 0);
    expect(find.text('Removed'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(await MoneyDao(db).balanceOf(MoneyMethod.cash), -25000);
  });

  testWidgets('a move between cash and bank changes neither total',
      (tester) async {
    await MoneyDao(db).correctBalance(
      userId: user.id,
      method: MoneyMethod.cash,
      countedPaise: 1000000,
    );
    await openApp(tester, '/reports/money/new/transfer');
    expect(find.text('Move money'), findsOneWidget);
    expect(find.text('to Bank / UPI'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '4000');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final p = await MoneyDao(db).watchCashPosition().first;
    expect(p.cashPaise, 600000);
    expect(p.bankPaise, 400000);
    expect(p.totalPaise, 1000000);
  });

  testWidgets('the overview has the new tiles and they open', (tester) async {
    await openApp(tester, '/reports');
    expect(find.text('Cash and bank'), findsOneWidget);
    expect(find.text('Profit'), findsOneWidget);

    await tester.tap(find.text('Cash and bank'));
    await tester.pumpAndSettle();
    expect(find.text('Cash in hand'), findsOneWidget);
    expect(find.text('Bank / UPI'), findsOneWidget);
  });
  testWidgets('the form opens on how he paid last time', (tester) async {
    await MoneyDao(db).addEntry(
      userId: user.id,
      kind: MoneyKind.expense,
      amount: 90000,
      category: 'Rent',
      method: MoneyMethod.bank,
    );
    await openApp(tester, '/reports/money/new/expense');

    await tester.enterText(find.byType(TextField).first, '120');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final entries = await db.select(db.moneyEntries).get();
    expect(entries.map((e) => e.method), everyElement('bank'),
        reason: 'no tap on the cash/bank switch was needed');
    expect(entries, hasLength(2));
  });

  testWidgets('a choice he makes is not overridden by the last method',
      (tester) async {
    await MoneyDao(db).addEntry(
      userId: user.id,
      kind: MoneyKind.expense,
      amount: 90000,
      category: 'Rent',
      method: MoneyMethod.bank,
    );
    await openApp(tester, '/reports/money/new/expense');

    await tester.tap(find.text('Cash'));
    await tester.enterText(find.byType(TextField).first, '120');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final newest = (await db.select(db.moneyEntries).get())
        .firstWhere((e) => e.amount == 12000);
    expect(newest.method, 'cash');
  });

  testWidgets('the Bills screen records an expense without leaving it',
      (tester) async {
    await openApp(tester, '/bills');

    await tester.tap(find.byTooltip('Add expense'));
    await tester.pumpAndSettle();
    expect(find.text('New expense'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '250');
    await tester.tap(find.text('Tea & snacks'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Back where he started, with the expense saved.
    expect(find.text('New expense'), findsNothing);
    expect(find.byTooltip('Add expense'), findsOneWidget);
    final saved = await db.select(db.moneyEntries).getSingle();
    expect(saved.amount, 25000);
    expect(saved.category, 'Tea & snacks');
  });
}
