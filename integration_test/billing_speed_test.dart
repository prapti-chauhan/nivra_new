import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nivra_new/app/providers.dart';
import 'package:nivra_new/core/theme.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/data/sync/connectivity_monitor.dart';
import 'package:nivra_new/data/sync/sync_service.dart';
import 'package:nivra_new/features/auth/auth_repository.dart';
import 'package:nivra_new/features/billing/bill_editor_screen.dart';

/// What the app itself costs on the fifteen-second path, on real hardware with
/// a realistic catalogue.
///
/// This measures the app's contribution only — the database query, the list
/// rebuild and the save. It does not include human time to read, aim and
/// think, so the number here is a floor, not what Ramesh will experience.
///
/// The search term is set directly rather than typed: the live test binding
/// does not register a test text input, so `enterText` silently does nothing
/// here and would have produced a measurement of an empty query. What is timed
/// is therefore everything from "the search term changed" to "the matching row
/// is on screen", which is the part that can actually be slow.
///
///   flutter test integration_test/billing_speed_test.dart -d `your-device`
const testUser = NivraUser(id: 'speed-user', email: 'speed@test');

/// Deliberately not five items. A hardware shop stocks hundreds with long
/// shared prefixes, which is exactly where a naive search falls over.
const int catalogueSize = 400;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ProviderContainer container;
  String? savedBillId;

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

    const families = [
      'Hex bolt', 'Hex nut', 'Washer', 'Anchor bolt', 'Wood screw',
      'Self tapping screw', 'PVC pipe', 'GI pipe', 'Elbow joint', 'Tee joint',
      'Cement bag', 'White cement', 'Wall putty', 'Primer', 'Enamel paint',
      'Copper wire', 'Aluminium wire', 'Switch', 'Socket', 'MCB',
    ];
    const sizes = [
      '6mm', '8mm', '10mm', '12mm', '16mm', '20mm', '25mm', '32mm', '40mm',
      '50mm', '63mm', '75mm', '90mm', '110mm', '125mm', '140mm', '160mm',
      '180mm', '200mm', '225mm',
    ];

    final inventory = container.read(inventoryDaoProvider);
    for (var i = 0; i < catalogueSize; i++) {
      final family = families[i % families.length];
      final size = sizes[(i ~/ families.length) % sizes.length];
      await inventory.createItem(
        userId: testUser.id,
        name: '$family $size',
        code: 'SKU$i',
        salePrice: 1000 + (i * 37) % 90000,
        purchasePrice: 800 + (i * 29) % 70000,
        openingStock: 50000 + i * 100,
      );
    }
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

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

  testWidgets('three items onto a bill, with $catalogueSize items in stock',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final stopwatch = Stopwatch()..start();
    final marks = <String, int>{};

    /// Types, then waits for the list to actually reflect the query before
    /// tapping. pumpAndSettle alone returns before the Drift query has
    /// emitted, which in profile mode meant tapping whatever was still on
    /// screen from the previous search.
    Future<bool> waitFor(String expected) async {
      for (var i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find.text(expected).evaluate().isNotEmpty) return true;
      }
      return false;
    }

    Future<void> addByTyping(String query, String expected) async {
      container.read(billItemSearchProvider.notifier).update(query);
      final appeared = await waitFor(expected);
      expect(appeared, isTrue, reason: '"$expected" never appeared for "$query"');
      await tester.tap(find.text(expected).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }

    await addByTyping('hex bolt 16', 'Hex bolt 16mm');
    marks['item 1'] = stopwatch.elapsedMilliseconds;

    await addByTyping('cement bag 40', 'Cement bag 40mm');
    marks['item 2'] = stopwatch.elapsedMilliseconds;

    await addByTyping('copper wire 10', 'Copper wire 10mm');
    marks['item 3'] = stopwatch.elapsedMilliseconds;

    await tester.tap(find.byKey(const Key('bill-save')));
    await tester.pump();
    for (var i = 0; i < 200 && savedBillId == null; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    marks['save'] = stopwatch.elapsedMilliseconds;
    stopwatch.stop();

    expect(savedBillId, isNotNull, reason: 'the bill should have been saved');

    final lines =
        await container.read(billingDaoProvider).linesFor(savedBillId!);
    expect(lines, hasLength(3));

    // ignore: avoid_print
    print('=== BILLING SPEED ($catalogueSize items in catalogue) ===');
    var previous = 0;
    marks.forEach((label, at) {
      // ignore: avoid_print
      print('  $label: +${at - previous}ms   (elapsed ${at}ms)');
      previous = at;
    });
    // ignore: avoid_print
    print('  TOTAL app time for three items and a save: ${marks['save']}ms');
  });

  testWidgets('search stays responsive across the whole catalogue',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final samples = <int>[];

    // Each probe names the row that sorts first among its matches, so the
    // wait is for the list actually reflecting the query rather than for a
    // row that may be below the fold. Broad probes come first: 'bolt' and
    // 'wire' match forty rows each, which is the expensive case.
    for (final probe in [
      ('bolt', 'Anchor bolt 10mm'),
      ('wire', 'Aluminium wire 10mm'),
      ('hex', 'Hex bolt 10mm'),
      ('hex bolt 1', 'Hex bolt 10mm'),
      ('pvc', 'PVC pipe 10mm'),
      ('cement', 'Cement bag 10mm'),
      ('mcb', 'MCB 10mm'),
      ('socket 63', 'Socket 63mm'),
    ]) {
      final sw = Stopwatch()..start();
      container.read(billItemSearchProvider.notifier).update(probe.$1);
      var found = false;
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find.text(probe.$2).evaluate().isNotEmpty) {
          found = true;
          break;
        }
      }
      sw.stop();
      // Without this the test would happily time a query that never ran.
      expect(found, isTrue, reason: '"${probe.$2}" never showed for "${probe.$1}"');
      samples.add(sw.elapsedMilliseconds);
    }

    final sorted = [...samples]..sort();
    final median = sorted[sorted.length ~/ 2];
    // ignore: avoid_print
    print('=== SEARCH LATENCY === median ${median}ms, best ${sorted.first}ms, '
        'worst ${sorted.last}ms across $catalogueSize items');

    // The median is what typing feels like. The worst sample is the first
    // query of the session, which carries the cold query plan and the first
    // build of the list, and is not representative of a keystroke.
    expect(median, lessThan(250),
        reason: 'a keystroke slower than this stops feeling like typing');
  });
}
