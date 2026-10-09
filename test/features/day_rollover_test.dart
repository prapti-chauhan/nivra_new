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
import 'package:nivra_new/domain/reports.dart';
import 'package:nivra_new/features/auth/auth_repository.dart';

const user = NivraUser(id: 'user-1', email: 'ramesh@shop.in');

/// A shop that never closes the app crosses midnight with it open. "Today" on
/// the reports is measured from the clock when the screen is built, so without
/// help it would go on showing yesterday until the next restart.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late FixedClock clock;

  setUp(() {
    // Ten to midnight on Wednesday 7 October 2026.
    clock = FixedClock(DateTime(2026, 10, 7, 23, 50).millisecondsSinceEpoch);
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

  Future<void> sellAt(DateTime when) async {
    final item = await InventoryDao(db).createItem(
      userId: user.id,
      name: 'bolt',
      salePrice: 2500,
      purchasePrice: 1800,
      openingStock: 100000,
    );
    await BillingDao(db).saveBill(
      userId: user.id,
      occurredAt: when.millisecondsSinceEpoch,
      lines: [
        BillLineDraft(
          itemId: item,
          name: 'bolt',
          unit: 'pcs',
          qty: 1000,
          unitPrice: 2500,
          unitCost: 1800,
        ),
      ],
    );
  }

  Future<void> openSales(WidgetTester tester) async {
    final router = container.read(routerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(theme: NivraTheme.light(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    router.go('/reports/sales');
    await tester.pumpAndSettle();
  }

  testWidgets('"Today" moves on at midnight without the app being reopened',
      (tester) async {
    await sellAt(DateTime(2026, 10, 7, 23, 0));
    await openSales(tester);
    expect(find.text('1'), findsWidgets, reason: 'the bill is in today');
    expect(find.text('No bills today.'), findsNothing);

    // The clock passes midnight; nothing else happens.
    clock.advance(const Duration(minutes: 20).inMilliseconds);
    await tester.pump(const Duration(minutes: 11));
    await tester.pumpAndSettle();

    expect(find.text('No bills today.'), findsOneWidget,
        reason: 'it is now the 8th, and nothing was sold on the 8th');
  });

  testWidgets('coming back to the app after a night asleep brings it up to date',
      (tester) async {
    await sellAt(DateTime(2026, 10, 7, 23, 0));
    await openSales(tester);
    expect(find.text('No bills today.'), findsNothing);

    // A sleeping phone runs no timers: the clock just jumps while it is away.
    clock.advance(const Duration(hours: 9).inMilliseconds);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('No bills today.'), findsOneWidget);
  });

  testWidgets('a custom range does not move when the day does', (tester) async {
    await sellAt(DateTime(2026, 10, 7, 23, 0));
    await openSales(tester);
    container.read(reportPeriodProvider.notifier).chooseCustom(
          firstDay: DateTime(2026, 10, 7),
          lastDay: DateTime(2026, 10, 7),
        );
    await tester.pumpAndSettle();
    expect(find.text('No bills 7 Oct 2026.'), findsNothing);

    clock.advance(const Duration(hours: 2).inMilliseconds);
    await tester.pump(const Duration(hours: 2));
    await tester.pumpAndSettle();

    expect(find.textContaining('No bills'), findsNothing,
        reason: 'he asked for the 7th, and the 7th has not changed');
  });

  testWidgets('"This month" follows the calendar over a month end',
      (tester) async {
    // Ten to midnight on 31 October.
    clock.advance(
      (DateTime(2026, 10, 31, 23, 50).millisecondsSinceEpoch) -
          clock.nowMillis(),
    );
    await sellAt(DateTime(2026, 10, 31, 22, 0));
    await openSales(tester);
    container
        .read(reportPeriodProvider.notifier)
        .choose(ReportPeriod.thisMonth);
    await tester.pumpAndSettle();
    expect(find.text('No bills this month.'), findsNothing);

    clock.advance(const Duration(minutes: 20).inMilliseconds);
    await tester.pump(const Duration(minutes: 11));
    await tester.pumpAndSettle();

    expect(find.text('No bills this month.'), findsOneWidget,
        reason: 'it is the 1st of November and nothing has been sold yet');
  });

  test('refreshing in the middle of a day changes nothing', () {
    final changes = <DateTime>[];
    container.listen<DateTime>(
      currentDayProvider,
      (_, next) => changes.add(next),
    );
    expect(container.read(currentDayProvider), DateTime(2026, 10, 7));

    container.read(currentDayProvider.notifier).refresh();
    clock.advance(const Duration(minutes: 5).inMilliseconds);
    container.read(currentDayProvider.notifier).refresh();
    expect(changes, isEmpty, reason: 'still the 7th, so nothing rebuilds');

    clock.advance(const Duration(hours: 1).inMilliseconds);
    container.read(currentDayProvider.notifier).refresh();
    expect(changes, [DateTime(2026, 10, 8)]);
  });
}
