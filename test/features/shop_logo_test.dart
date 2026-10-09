import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/app/providers.dart';
import 'package:nivra_new/app/router.dart';
import 'package:nivra_new/core/theme.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/data/sync/connectivity_monitor.dart';
import 'package:nivra_new/data/sync/logo_sync.dart';
import 'package:nivra_new/data/sync/sync_service.dart';
import 'package:nivra_new/features/auth/auth_repository.dart';
import 'package:nivra_new/features/settings/logo_picker.dart';

const user = NivraUser(id: 'user-1', email: 'ramesh@shop.in');

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class FakePicker implements LogoPicker {
  Uint8List? next;
  Object? throwOnPick;
  final asked = <LogoSource>[];

  @override
  Future<Uint8List?> pick(LogoSource source) async {
    asked.add(source);
    if (throwOnPick != null) throw throwOnPick!;
    return next;
  }
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late FakePicker picker;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nivra_shop_logo');
    picker = FakePicker();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((ref) => Stream.value(user)),
        logoPickerProvider.overrideWithValue(picker),
        logoFilesProvider.overrideWithValue(LogoFiles(() async => dir)),
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
    await dir.delete(recursive: true);
  });

  Future<void> openShop(WidgetTester tester) async {
    final router = container.read(routerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(theme: NivraTheme.light(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    router.go('/shop');
    await tester.pumpAndSettle();
  }

  Future<BusinessProfile> profile() =>
      BillingDao(db).ensureProfile(user.id);

  /// Taps [label] and waits until [done] says the work behind the tap has
  /// finished.
  ///
  /// The handlers write a file, which is real I/O and only moves when real time
  /// passes, then touch the database, which only moves when the test's own
  /// microtasks are flushed. So each round gives the file a moment of real time
  /// and then pumps. The database is queried from the test body, never inside
  /// `runAsync`: its futures belong to the test's clock and would never finish.
  Future<void> tapAndWait(
    WidgetTester tester,
    String label, {
    required Future<bool> Function() done,
  }) async {
    await tester.tap(find.text(label));
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (await done()) break;
    }
    // The screen then reads the new file back to draw it: one more moment of
    // real time for that, and a pump to show the result. Not pumpAndSettle:
    // once a logo is showing, the image is still being decoded off the test's
    // clock and settling would wait on it.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<bool> versionIs(int v) async => (await profile()).logoVersion == v;

  testWidgets('a picture from the gallery becomes the logo', (tester) async {
    picker.next = png;
    await openShop(tester);
    expect(find.text('Shop logo'), findsOneWidget);
    expect(find.text('Remove'), findsNothing, reason: 'no logo yet');

    await tapAndWait(tester, 'Choose picture', done: () => versionIs(1));

    expect(picker.asked, [LogoSource.gallery]);
    final p = await profile();
    expect(p.logoVersion, 1);
    expect(File(p.logoPath!).readAsBytesSync(), png);
    expect(p.isDirty, isTrue, reason: 'it must reach the server');
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('the camera button asks for the camera', (tester) async {
    picker.next = png;
    await openShop(tester);
    await tapAndWait(tester, 'Take photo', done: () => versionIs(1));
    expect(picker.asked, [LogoSource.camera]);
  });

  testWidgets('backing out of the picker changes nothing', (tester) async {
    picker.next = null;
    await openShop(tester);
    // Nothing is going to change, so there is nothing to wait for but the pick.
    await tapAndWait(tester, 'Choose picture',
        done: () async => picker.asked.isNotEmpty);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    final p = await profile();
    expect(p.logoVersion, 0);
    expect(p.logoPath, isNull);
  });

  testWidgets('something that is not a JPEG or PNG is refused with a reason',
      (tester) async {
    picker.next = Uint8List.fromList(utf8.encode('GIF89a not really'));
    await openShop(tester);
    await tapAndWait(tester, 'Choose picture',
        done: () async => picker.asked.isNotEmpty);
    await tester.pump();

    expect(find.text('Use a JPEG or PNG picture.'), findsOneWidget);
    final p = await profile();
    expect(p.logoVersion, 0);
    expect(dir.listSync(), isEmpty);
  });

  testWidgets('a camera that will not open says so instead of failing silently',
      (tester) async {
    picker.throwOnPick = PlatformException(code: 'camera_access_denied');
    await openShop(tester);
    await tapAndWait(tester, 'Take photo',
        done: () async => picker.asked.isNotEmpty);
    await tester.pump();

    expect(find.textContaining('Could not open the camera'), findsOneWidget);
  });

  testWidgets('choosing again replaces the logo and deletes the old file',
      (tester) async {
    picker.next = png;
    await openShop(tester);
    await tapAndWait(tester, 'Choose picture', done: () => versionIs(1));
    final first = (await profile()).logoPath!;

    await tapAndWait(tester, 'Choose picture', done: () => versionIs(2));
    // The old file goes once the new one is in place.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    final p = await profile();
    expect(p.logoVersion, 2);
    expect(p.logoPath, isNot(first));
    expect(File(first).existsSync(), isFalse);
    expect(dir.listSync(), hasLength(1));
  });

  testWidgets('Remove clears the logo and its file', (tester) async {
    picker.next = png;
    await openShop(tester);
    await tapAndWait(tester, 'Choose picture', done: () => versionIs(1));
    final path = (await profile()).logoPath!;

    await tapAndWait(tester, 'Remove', done: () => versionIs(0));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    final p = await profile();
    expect(p.logoVersion, 0);
    expect(p.logoPath, isNull);
    expect(File(path).existsSync(), isFalse);
    expect(find.text('Remove'), findsNothing);
  });
}
