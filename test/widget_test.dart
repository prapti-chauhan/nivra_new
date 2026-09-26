import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/app/providers.dart';
import 'package:nivra_new/core/theme.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/data/sync/connectivity_monitor.dart';
import 'package:nivra_new/data/sync/sync_service.dart';
import 'package:nivra_new/features/auth/auth_repository.dart';
import 'package:nivra_new/features/items/item_detail_screen.dart';
import 'package:nivra_new/features/items/items_screen.dart';

const testUser = NivraUser(id: 'user-1', email: 'ramesh@shop.in');

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  Widget harness(Widget child) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: NivraTheme.light(), home: child),
      );

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((ref) => Stream.value(testUser)),
        // The real service reaches for the connectivity plugin, which does not
        // exist in a widget test.
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

  testWidgets('shows an explanation rather than an empty screen', (tester) async {
    await tester.pumpWidget(harness(const ItemsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('No items yet'), findsOneWidget);
    expect(find.text('Add item'), findsOneWidget);
  });

  testWidgets('an item written to the database appears without a refresh',
      (tester) async {
    await tester.pumpWidget(harness(const ItemsScreen()));
    await tester.pumpAndSettle();

    await container.read(inventoryDaoProvider).createItem(
          userId: testUser.id,
          name: 'Hex bolt 16mm',
          code: 'HB16',
          salePrice: 1450,
          openingStock: 24000,
        );
    await tester.pumpAndSettle();

    expect(find.text('Hex bolt 16mm'), findsOneWidget);
    expect(find.text('HB16'), findsOneWidget);
    expect(find.text('₹14.50'), findsOneWidget);
    expect(find.text('24 pcs'), findsOneWidget);
  });

  testWidgets('warns only on items that asked to be warned about', (tester) async {
    final dao = container.read(inventoryDaoProvider);
    await dao.createItem(
      userId: testUser.id,
      name: 'Watched item',
      openingStock: 2000,
      lowStockThreshold: 5000,
    );
    await dao.createItem(
      userId: testUser.id,
      name: 'Unwatched item',
      openingStock: 2000,
    );

    await tester.pumpWidget(harness(const ItemsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Only 2 pcs left'), findsOneWidget); // the watched one
    expect(find.text('2 pcs'), findsOneWidget); // the quiet one
  });

  testWidgets('item detail does not print the stock figure twice',
      (tester) async {
    final dao = container.read(inventoryDaoProvider);
    final id = await dao.createItem(
      userId: testUser.id,
      name: 'Hex bolt 16mm',
      unit: 'pcs',
      salePrice: 1450,
      openingStock: 24000,
      lowStockThreshold: 5000,
    );

    await tester.pumpWidget(harness(ItemDetailScreen(itemId: id)));
    await tester.pumpAndSettle();

    // The headline number, once.
    expect(find.text('24'), findsOneWidget);
    // Healthy stock has nothing extra to say, so no repeat chip.
    expect(find.text('24 pcs'), findsNothing);
    expect(find.text('Only 24 pcs left'), findsNothing);
    // The history is still there, and still says where the number came from.
    expect(find.text('The number above is the total of these.'), findsOneWidget);
    expect(find.text('Opening stock'), findsOneWidget);
    expect(find.text('+24 pcs'), findsOneWidget);
  });

  testWidgets('item detail does warn when stock is actually low',
      (tester) async {
    final dao = container.read(inventoryDaoProvider);
    final id = await dao.createItem(
      userId: testUser.id,
      name: 'Nearly out',
      unit: 'pcs',
      openingStock: 3000,
      lowStockThreshold: 5000,
    );

    await tester.pumpWidget(harness(ItemDetailScreen(itemId: id)));
    await tester.pumpAndSettle();

    expect(find.text('Only 3 pcs left'), findsOneWidget);
  });

  testWidgets('search narrows the list as it is typed', (tester) async {
    final dao = container.read(inventoryDaoProvider);
    await dao.createItem(userId: testUser.id, name: 'Hex bolt', code: 'HB16');
    await dao.createItem(userId: testUser.id, name: 'Cement bag', code: 'CEM');

    await tester.pumpWidget(harness(const ItemsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Hex bolt'), findsOneWidget);
    expect(find.text('Cement bag'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'cem');
    await tester.pumpAndSettle();

    expect(find.text('Cement bag'), findsOneWidget);
    expect(find.text('Hex bolt'), findsNothing);
  });

  testWidgets('never claims data is backed up before it has checked',
      (tester) async {
    await tester.pumpWidget(harness(const ItemsScreen()));
    await tester.pumpAndSettle();

    // No Supabase configured here, so the honest answer is "on this phone".
    expect(find.text('On this phone'), findsOneWidget);
    expect(find.text('Saved'), findsNothing);
  });
}
