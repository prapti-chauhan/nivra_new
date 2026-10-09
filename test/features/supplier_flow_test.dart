import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/app/providers.dart';
import 'package:nivra_new/app/router.dart';
import 'package:nivra_new/core/theme.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/data/sync/connectivity_monitor.dart';
import 'package:nivra_new/data/sync/sync_service.dart';
import 'package:nivra_new/features/auth/auth_repository.dart';

const user = NivraUser(id: 'user-1', email: 'ramesh@shop.in');

/// Regression. The supplier editor read the user id without keeping the session
/// provider alive, so on first read it was still loading and Save quietly did
/// nothing at all. It was never exercised through the UI, so nothing noticed.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
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

  testWidgets('saving a new supplier through the screen actually saves it',
      (tester) async {
    final router = container.read(routerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(theme: NivraTheme.light(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    router.go('/suppliers/new');
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Verma Traders');
    await tester.enterText(find.byType(TextField).last, '1000');
    await tester.tap(find.text('Add supplier'));
    await tester.pumpAndSettle();

    final saved = await db.select(db.suppliers).getSingle();
    expect(saved.name, 'Verma Traders');
    // Rs 1,000 already owed, stored negative under the one global sign rule.
    expect(saved.balance, -100000);
  });
  Future<void> openAt(WidgetTester tester, String location) async {
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

  Future<(String supplierId, String itemId, String purchaseId)> aPurchase({
    int amountPaid = 0,
  }) async {
    final dao = PurchaseDao(db);
    final supplier = await dao.createSupplier(userId: user.id, name: 'Verma');
    final item = await InventoryDao(db).createItem(
      userId: user.id,
      name: 'bolt',
      salePrice: 2500,
      purchasePrice: 1000,
    );
    final purchase = await dao.savePurchase(
      userId: user.id,
      supplierId: supplier,
      amountPaid: amountPaid,
      lines: [
        PurchaseLineDraft(
          itemId: item,
          name: 'bolt',
          unit: 'pcs',
          qty: 10000,
          unitCost: 1000,
        ),
      ],
    );
    return (supplier, item, purchase);
  }

  testWidgets('a purchase can be edited from its page, and the old figures stay',
      (tester) async {
    final (_, item, purchase) = await aPurchase();
    await openAt(tester, '/purchases/$purchase');
    expect(find.text('Edited'), findsNothing);

    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit purchase'), findsOneWidget);
    expect(find.text('Verma'), findsOneWidget, reason: 'filled in, not blank');
    expect(find.text('Paid now'), findsNothing,
        reason: 'payments are not part of correcting a purchase');

    // The quantity field holds "10"; make it 4.
    await tester.enterText(find.widgetWithText(TextField, '10'), '4');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    // Back on the page, now marked, with the old version one tap away.
    expect(find.text('Edited'), findsOneWidget);
    expect(find.text('Earlier versions'), findsOneWidget);
    expect(find.text('Version 1 · ₹100'), findsOneWidget);

    expect((await InventoryDao(db).findItem(item))!.stockQty, 4000);
    final saved = await PurchaseDao(db).findPurchase(purchase);
    expect(saved!.total, 4000);
    expect(saved.revision, 1);
  });

  testWidgets('once money has been paid the supplier cannot be changed',
      (tester) async {
    final (_, _, purchase) = await aPurchase(amountPaid: 2500);
    await openAt(tester, '/purchases/$purchase/edit');

    expect(find.textContaining('this supplier'), findsOneWidget);
    await tester.tap(find.text('Verma'));
    await tester.pumpAndSettle();
    expect(find.text('Search suppliers'), findsNothing,
        reason: 'the supplier picker does not open');
  });
}
