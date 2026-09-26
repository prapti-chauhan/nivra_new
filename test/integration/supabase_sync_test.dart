@Tags(['integration'])
library;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/data/remote/supabase_config.dart';
import 'package:nivra_new/data/remote/sync_api.dart';
import 'package:nivra_new/data/sync/connectivity_monitor.dart';
import 'package:nivra_new/data/sync/sync_service.dart';
import 'package:nivra_new/domain/billing.dart';
import 'package:nivra_new/domain/stock.dart';
import 'package:nivra_new/domain/sync_status.dart';
import 'package:supabase/supabase.dart';

/// Runs the real SyncService against the real Supabase project.
///
/// Opt in, because it writes to a live database and creates an auth user:
///
///   flutter test test/integration \
///     --dart-define-from-file=supabase.local.json \
///     --dart-define=RUN_SUPABASE_IT=true
///
/// Uses the plain `supabase` client rather than `supabase_flutter` so no
/// platform channels are needed.
const bool runIt = bool.fromEnvironment('RUN_SUPABASE_IT');

void main() {
  if (!runIt || !SupabaseConfig.isConfigured) {
    test('supabase integration (skipped)', () {}, skip: 'set RUN_SUPABASE_IT=true');
    return;
  }

  late SupabaseClient client;
  late String userId;

  setUpAll(() async {
    // Two databases is the point of this test: one is a second device.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    client = SupabaseClient(
      SupabaseConfig.url,
      SupabaseConfig.publishableKey,
      // PKCE needs an async storage the bare client has no place to put; the
      // app itself uses supabase_flutter, which supplies one.
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final res = await client.auth.signUp(
      email: 'nivra-it-$stamp@example.com',
      password: 'integration-pass-123',
    );
    userId = res.user!.id;
    expect(res.session, isNotNull,
        reason: 'Email confirmation must be off for this to work');
  });

  tearDownAll(() async {
    await client.auth.signOut();
    await client.dispose();
  });

  test('a device pushes, and a fresh install rebuilds stock from movements',
      () async {
    // --- device one: create an item with stock, and sell some -------------
    final deviceOne = AppDatabase.forTesting(NativeDatabase.memory());
    final invOne = InventoryDao(deviceOne);
    final syncOne = SyncService(
      db: deviceOne,
      connectivity: FakeConnectivityMonitor(),
      api: SupabaseSyncApi(client),
    );

    final itemId = await invOne.createItem(
      userId: userId,
      name: 'IT hex bolt 16mm',
      code: 'IT-HB16',
      salePrice: 1450,
      purchasePrice: 1000,
      openingStock: 40000,
    );
    await invOne.applyMovement(
      userId: userId,
      itemId: itemId,
      qtyDelta: -7500,
      reason: MovementReason.sale,
      source: MovementSource.bill,
      sourceId: 'it-bill-1',
    );

    expect(await invOne.findItem(itemId).then((i) => i!.stockQty), 32500);

    await syncOne.start(userId);
    await syncOne.syncNow();

    expect(syncOne.currentStatus.phase, SyncPhase.synced,
        reason: 'push should have settled everything');
    expect(await SyncDao(deviceOne).pendingCount(), 0);

    // --- device two: a fresh install with an empty database ---------------
    final deviceTwo = AppDatabase.forTesting(NativeDatabase.memory());
    final invTwo = InventoryDao(deviceTwo);
    final syncTwo = SyncService(
      db: deviceTwo,
      connectivity: FakeConnectivityMonitor(),
      api: SupabaseSyncApi(client),
    );

    await syncTwo.start(userId);
    await syncTwo.syncNow();

    final pulled = await invTwo.findItem(itemId);
    expect(pulled, isNotNull, reason: 'the item should have arrived');
    expect(pulled!.name, 'IT hex bolt 16mm');
    expect(pulled.salePrice, 1450);

    // The server never sent a stock figure. This number was rebuilt locally
    // from the two movements that came with it.
    expect(pulled.stockQty, 32500);
    expect(await invTwo.stockFromLedger(itemId), 32500);

    final movements = await invTwo.watchMovements(itemId).first;
    expect(movements, hasLength(2));
    expect(
      movements.any((m) => m.sourceId == 'it-bill-1' && m.qtyDelta == -7500),
      isTrue,
      reason: 'the sale should still name the bill that caused it',
    );

    // --- an edit on device one reaches device two -------------------------
    await invOne.updateItem(id: itemId, salePrice: 1600);
    await syncOne.syncNow();
    await syncTwo.syncNow();

    expect(await invTwo.findItem(itemId).then((i) => i!.salePrice), 1600);

    await syncOne.stop();
    await syncTwo.stop();
    await deviceOne.close();
    await deviceTwo.close();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a credit bill and its payment rebuild correctly on a fresh install',
      () async {
    // --- device one ------------------------------------------------------
    final one = AppDatabase.forTesting(NativeDatabase.memory());
    final invOne = InventoryDao(one);
    final partyOne = PartyDao(one);
    final billOne = BillingDao(one);
    final syncOne = SyncService(
      db: one,
      connectivity: FakeConnectivityMonitor(),
      api: SupabaseSyncApi(client),
    );

    final itemId = await invOne.createItem(
      userId: userId,
      name: 'IT cement bag 50kg',
      code: 'IT-CEM50',
      salePrice: 42000,
      purchasePrice: 38000,
      openingStock: 20000,
    );
    final customerId = await partyOne.createCustomer(
      userId: userId,
      name: 'IT Sharma Traders',
      phone: '9876500001',
    );

    final billId = await billOne.saveBill(
      userId: userId,
      customerId: customerId,
      customerName: 'IT Sharma Traders',
      paid: false,
      lines: [
        BillLineDraft(
          itemId: itemId,
          name: 'IT cement bag 50kg',
          unit: 'pcs',
          qty: 5000,
          unitPrice: 42000,
          unitCost: 38000,
        ),
      ],
    );
    await billOne.recordPayment(
      userId: userId,
      billId: billId,
      customerId: customerId,
      amount: 50000,
    );

    expect((await invOne.findItem(itemId))!.stockQty, 15000);
    expect((await partyOne.findCustomer(customerId))!.balance, 160000);
    expect((await billOne.findBill(billId))!.amountPaid, 50000);

    await syncOne.start(userId);
    await syncOne.syncNow();
    expect(syncOne.currentStatus.phase, SyncPhase.synced,
        reason: 'everything should have pushed: ${syncOne.currentStatus.message}');
    expect(await SyncDao(one).pendingCount(), 0);

    // --- device two: empty database, nothing but the account -------------
    final two = AppDatabase.forTesting(NativeDatabase.memory());
    final invTwo = InventoryDao(two);
    final partyTwo = PartyDao(two);
    final billTwo = BillingDao(two);
    final syncTwo = SyncService(
      db: two,
      connectivity: FakeConnectivityMonitor(),
      api: SupabaseSyncApi(client),
    );

    await syncTwo.start(userId);
    await syncTwo.syncNow();

    final pulledBill = await billTwo.findBill(billId);
    expect(pulledBill, isNotNull, reason: 'the bill should have arrived');
    expect(pulledBill!.total, 210000);
    expect(pulledBill.customerName, 'IT Sharma Traders');

    final pulledLines = await billTwo.linesFor(billId);
    expect(pulledLines, hasLength(1));
    expect(pulledLines.single.qty, 5000);
    expect(pulledLines.single.unitCost, 38000,
        reason: 'cost travels so profit stays traceable');

    // None of these three numbers was ever sent over the wire. Each was
    // recomputed on this device from the rows that define it.
    expect((await invTwo.findItem(itemId))!.stockQty, 15000,
        reason: 'stock rebuilt from movements');
    expect((await partyTwo.findCustomer(customerId))!.balance, 160000,
        reason: 'balance rebuilt from ledger entries');
    expect(pulledBill.amountPaid, 50000,
        reason: 'amount paid rebuilt from payments');

    expect(await partyTwo.balanceFromLedger(customerId), 160000);
    expect(await billTwo.paidFromPayments(billId), 50000);
    expect(
      paymentStatusFor(
        totalPaise: pulledBill.total,
        paidPaise: pulledBill.amountPaid,
      ),
      PaymentStatus.partial,
    );

    // --- a revision on device one reaches device two ---------------------
    await billOne.reviseBill(
      userId: userId,
      billId: billId,
      customerId: customerId,
      customerName: 'IT Sharma Traders',
      lines: [
        BillLineDraft(
          itemId: itemId,
          name: 'IT cement bag 50kg',
          unit: 'pcs',
          qty: 2000,
          unitPrice: 42000,
          unitCost: 38000,
        ),
      ],
    );
    await syncOne.syncNow();
    await syncTwo.syncNow();

    final revised = await billTwo.findBill(billId);
    expect(revised!.total, 84000);
    expect(revised.revision, 1, reason: 'device two sees it was edited');
    expect((await billTwo.watchRevisions(billId).first), hasLength(1),
        reason: 'the superseded version travelled too');
    expect((await invTwo.findItem(itemId))!.stockQty, 18000,
        reason: 'the reversal rebuilt stock on device two');
    expect((await partyTwo.findCustomer(customerId))!.balance, 34000,
        reason: '84000 owed less the 50000 already paid');

    await syncOne.stop();
    await syncTwo.stop();
    await one.close();
    await two.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
