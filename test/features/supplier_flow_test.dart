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
}
