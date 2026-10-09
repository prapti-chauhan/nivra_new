import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/clock.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/data/remote/mappers.dart';
import 'package:nivra_new/data/remote/sync_api.dart';
import 'package:nivra_new/data/sync/connectivity_monitor.dart';
import 'package:nivra_new/data/sync/logo_sync.dart';
import 'package:nivra_new/data/sync/sync_service.dart';
import 'package:nivra_new/domain/logo.dart';
import 'package:nivra_new/domain/sync_status.dart';

const userId = 'user-1';

/// A real 1x1 PNG, so the renderer test can draw it too.
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);
final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);

/// Storage as the server keeps it: one object per user, overwritten in place.
class FakeLogoStorage implements LogoStorage {
  final Map<String, Uint8List> objects = {};
  Exception? failUploadWith;
  Uint8List? downloadOverride;
  bool downloadMissing = false;
  int uploads = 0;
  int removals = 0;

  @override
  Future<void> upload(String userId, Uint8List bytes, LogoFormat format) async {
    if (failUploadWith != null) throw failUploadWith!;
    uploads++;
    objects[userId] = bytes;
  }

  @override
  Future<Uint8List?> download(String userId) async {
    if (downloadMissing) return null;
    return downloadOverride ?? objects[userId];
  }

  @override
  Future<void> remove(String userId) async {
    removals++;
    objects.remove(userId);
  }
}

/// Just enough of a server for the profile row to travel.
class FakeSyncApi implements SyncApi {
  final Map<String, Map<String, Map<String, dynamic>>> tables = {};
  int _stamp = 0;

  @override
  Future<List<RemoteAck>> push(
    String table,
    List<Map<String, dynamic>> rows,
  ) async {
    final acks = <RemoteAck>[];
    for (final row in rows) {
      _stamp++;
      tables.putIfAbsent(table, () => {})[row['id'] as String] = {
        ...row,
        SyncApi.serverStampColumn: _stamp,
      };
      acks.add(RemoteAck(id: row['id'] as String, serverUpdatedAt: _stamp));
    }
    return acks;
  }

  @override
  Future<List<Map<String, dynamic>>> pull(
    String table, {
    required int since,
    int limit = 500,
  }) async {
    final rows = (tables[table] ?? {})
        .values
        .where((r) => (r[SyncApi.serverStampColumn] as int) > since)
        .toList();
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }
}

/// One phone: its own database, its own folder, the shared server.
class Phone {
  Phone(this.api, this.storage, this.dir, {FixedClock? clock})
      : clock = clock ?? FixedClock(1700000000000) {
    db = AppDatabase.forTesting(NativeDatabase.memory(), clock: this.clock);
    files = LogoFiles(() async => dir);
    sync = SyncService(
      db: db,
      connectivity: FakeConnectivityMonitor(),
      api: api,
      logoSync: LogoSync(db: db, storage: storage, files: files, clock: this.clock),
      clock: this.clock,
    );
  }

  final FakeSyncApi api;
  final FakeLogoStorage storage;
  final Directory dir;
  final FixedClock clock;
  late final AppDatabase db;
  late final LogoFiles files;
  late final SyncService sync;

  BillingDao get billing => BillingDao(db);

  Future<BusinessProfile> profile() => billing.ensureProfile(userId);

  Future<void> choose(Uint8List bytes) async {
    final format = sniffLogoFormat(bytes)!;
    final path = await files.write(bytes, format);
    await billing.setLogo(userId: userId, path: path);
  }

  Future<void> syncNow() async {
    await sync.start(userId);
    await sync.syncNow();
  }

  Future<void> close() async {
    await sync.stop();
    await db.close();
  }
}

void main() {
  late FakeSyncApi api;
  late FakeLogoStorage storage;
  late Directory dirA;
  late Directory dirB;
  late Phone a;
  late Phone b;

  setUp(() async {
    api = FakeSyncApi();
    storage = FakeLogoStorage();
    dirA = await Directory.systemTemp.createTemp('nivra_logo_a');
    dirB = await Directory.systemTemp.createTemp('nivra_logo_b');
    a = Phone(api, storage, dirA);
    b = Phone(api, storage, dirB);
  });

  tearDown(() async {
    await a.close();
    await b.close();
    await dirA.delete(recursive: true);
    await dirB.delete(recursive: true);
  });

  group('choosing a logo', () {
    test('bumps the version, keeps the file, and marks the profile to send',
        () async {
      await a.choose(png);
      final p = await a.profile();
      expect(p.logoVersion, 1);
      expect(p.logoCachedVersion, 1);
      expect(p.logoUploadedVersion, 0);
      expect(p.isDirty, isTrue);
      expect(await a.files.read(p.logoPath), png);
    });

    test('a second logo is version two', () async {
      await a.choose(png);
      await a.choose(jpeg);
      expect((await a.profile()).logoVersion, 2);
    });
  });

  group('what the profile row advertises', () {
    test('never a version that is still waiting to be uploaded', () async {
      await a.choose(png);
      final json = RowMappers.profileToJson(await a.profile());
      expect(json['logo_version'], 0,
          reason: 'another phone would be told about an image not there yet');
    });

    test('the version Storage has, once it is there', () async {
      await a.choose(png);
      await a.syncNow();
      final remote = api.tables['business_profiles']!.values.single;
      expect(remote['logo_version'], 1);
    });

    test('a replacement still waiting advertises the older version', () async {
      await a.choose(png);
      await a.syncNow(); // v1 is up
      storage.failUploadWith = TransientSyncException('no signal');
      await a.choose(jpeg); // v2 chosen, cannot upload
      await a.sync.syncNow();
      final remote = api.tables['business_profiles']!.values.single;
      expect(remote['logo_version'], 1,
          reason: 'v1 is what is actually in Storage');
    });

    test('a profile pulled from the server records that Storage has it', () {
      final companion = RowMappers.profileFromJson({
        'id': 'p1',
        'user_id': userId,
        'logo_version': 4,
      });
      expect(companion.logoVersion.value, 4);
      expect(companion.logoUploadedVersion.value, 4);
      expect(companion.logoPath.present, isFalse,
          reason: 'a path on another phone means nothing here');
      expect(companion.logoCachedVersion.present, isFalse);
    });
  });

  group('between two phones', () {
    test('a logo chosen on one appears on the other', () async {
      await a.choose(png);
      await a.syncNow();
      expect(storage.objects[userId], png);

      await b.syncNow();
      final p = await b.profile();
      expect(p.logoVersion, 1);
      expect(p.logoCachedVersion, 1);
      expect(p.logoPath, isNotNull);
      expect(p.logoPath, isNot((await a.profile()).logoPath),
          reason: 'each phone keeps its own file');
      expect(await b.files.read(p.logoPath), png);
    });

    test('a download is not mistaken for a local edit', () async {
      await a.choose(png);
      await a.syncNow();
      await b.syncNow();

      expect((await b.profile()).isDirty, isFalse);
      expect(await SyncDao(b.db).pendingCount(), 0);
    });

    test('a replacement reaches the other phone and the old file is deleted',
        () async {
      await a.choose(png);
      await a.syncNow();
      await b.syncNow();
      final firstPath = (await b.profile()).logoPath!;

      a.clock.advance(1000);
      await a.choose(jpeg);
      await a.sync.syncNow();
      await b.sync.syncNow();

      final p = await b.profile();
      expect(p.logoVersion, 2);
      expect(await b.files.read(p.logoPath), jpeg);
      expect(File(firstPath).existsSync(), isFalse);
    });

    test('removing it on one phone removes it from Storage and the other phone',
        () async {
      await a.choose(png);
      await a.syncNow();
      await b.syncNow();
      final onB = (await b.profile()).logoPath!;
      expect(File(onB).existsSync(), isTrue);

      a.clock.advance(1000);
      await a.billing.clearLogo(userId);
      await a.sync.syncNow();
      expect(storage.objects, isEmpty, reason: 'gone from the server');
      expect(storage.removals, 1);

      await b.sync.syncNow();
      final p = await b.profile();
      expect(p.logoVersion, 0);
      expect(p.logoPath, isNull);
      expect(File(onB).existsSync(), isFalse);
    });

    test('a phone holding an older logo does not upload it over a newer one',
        () async {
      await a.choose(png);
      await a.syncNow();
      await b.syncNow(); // b holds v1

      // a moves on to v2 and syncs; b has not synced since.
      a.clock.advance(1000);
      await a.choose(jpeg);
      await a.sync.syncNow();
      expect(storage.objects[userId], jpeg);

      // b edits the profile and syncs. Its own row still says v1, which is the
      // normal one-device-at-a-time assumption being strained, but its old
      // image must at least never replace the newer one in Storage.
      b.clock.advance(5000);
      await b.billing.updateProfile(userId: userId, shopName: 'Sharma Hardware');
      await b.sync.syncNow();

      expect(storage.objects[userId], jpeg,
          reason: "b's old v1 file must not overwrite a's v2");
      expect(storage.uploads, 2, reason: 'only a ever uploaded');
    });

    test('a logo waiting to upload survives the profile coming back down',
        () async {
      // The pushed profile advertises version 0 (nothing uploaded yet), and the
      // next step of the same cycle pulls that very row back.
      storage.failUploadWith = TransientSyncException('no signal');
      await a.choose(png);
      await a.syncNow();

      final p = await a.profile();
      expect(p.logoVersion, 1, reason: 'the chosen logo is not thrown away');
      expect(p.logoCachedVersion, 1);
      expect(p.logoPath, isNotNull);
    });

    test('an edit to the profile after a pull does not roll the version back',
        () async {
      await a.choose(png);
      await a.syncNow();
      await b.syncNow();

      b.clock.advance(5000);
      await b.billing.updateProfile(userId: userId, shopName: 'Renamed');
      await b.sync.syncNow();

      final remote = api.tables['business_profiles']!.values.single;
      expect(remote['logo_version'], 1);
      expect(remote['shop_name'], 'Renamed');
    });
  });

  group('when the logo cannot travel', () {
    test('a failed upload is logged and the rest of the profile still syncs',
        () async {
      storage.failUploadWith = PermanentSyncException('bucket missing');
      await a.billing.updateProfile(userId: userId, shopName: 'Sharma Hardware');
      await a.choose(png);
      await a.syncNow();

      expect(a.sync.currentStatus.phase, SyncPhase.synced,
          reason: 'a logo problem must not look like a sync failure');
      final remote = api.tables['business_profiles']!.values.single;
      expect(remote['shop_name'], 'Sharma Hardware');
      expect(remote['logo_version'], 0);

      final log = await a.db.select(a.db.syncLogs).get();
      expect(
        log.where((l) => l.entity == 'logo' && !l.ok).map((l) => l.detail),
        contains(contains('bucket missing')),
      );
    });

    test('it is retried and goes up once the problem is gone', () async {
      storage.failUploadWith = TransientSyncException('no signal');
      await a.choose(png);
      await a.syncNow();
      expect(storage.objects, isEmpty);

      storage.failUploadWith = null;
      await a.sync.syncNow();
      expect(storage.objects[userId], png);
      final remote = api.tables['business_profiles']!.values.single;
      expect(remote['logo_version'], 1);
    });

    test('a logo that is announced but not in Storage is logged, not fatal',
        () async {
      await a.choose(png);
      await a.syncNow();
      storage.downloadMissing = true;

      await b.syncNow();
      expect(b.sync.currentStatus.phase, SyncPhase.synced);
      expect((await b.profile()).logoPath, isNull);
      final log = await b.db.select(b.db.syncLogs).get();
      expect(
        log.where((l) => l.entity == 'logo' && !l.ok).map((l) => l.detail),
        contains(contains('not in Storage')),
      );
    });

    test('bytes from the server that are not a picture are never kept',
        () async {
      await a.choose(png);
      await a.syncNow();
      storage.downloadOverride = Uint8List.fromList(utf8.encode('<html>oops'));

      await b.syncNow();
      expect((await b.profile()).logoPath, isNull);
      expect(dirB.listSync(), isEmpty, reason: 'nothing was written to disk');
    });

    test('a missing local file is not uploaded, and does not crash', () async {
      await a.choose(png);
      File((await a.profile()).logoPath!).deleteSync();
      await a.syncNow();
      expect(storage.objects, isEmpty);
      expect(a.sync.currentStatus.phase, SyncPhase.synced);
    });
  });

  test('signing out deletes the logo file along with the data', () async {
    await a.choose(png);
    final path = (await a.profile()).logoPath!;
    expect(File(path).existsSync(), isTrue);

    await SyncDao(a.db).wipeAll();

    expect(File(path).existsSync(), isFalse);
  });

  test('device-local columns survive a pull of the same profile', () async {
    await a.choose(png);
    await a.syncNow();
    final before = await a.profile();

    // The server's copy arrives again (as it would after a cursor reset).
    await (a.db.update(a.db.syncStates)).write(
      const SyncStatesCompanion(lastCursor: Value(0)),
    );
    await a.sync.syncNow();

    final after = await a.profile();
    expect(after.logoPath, before.logoPath);
    expect(after.logoCachedVersion, before.logoCachedVersion);
  });
}
