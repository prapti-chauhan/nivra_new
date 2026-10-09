import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../core/clock.dart';
import '../../domain/logo.dart';
import '../db/database.dart';
import '../remote/sync_api.dart';

/// Where the logo image lives on the server. One image per user, overwritten in
/// place, so there are never orphans to clean up; the profile's `logo_version`
/// is what tells another phone that the image has changed.
abstract class LogoStorage {
  Future<void> upload(String userId, Uint8List bytes, LogoFormat format);

  /// Null when there is nothing there.
  Future<Uint8List?> download(String userId);

  Future<void> remove(String userId);
}

/// Supabase Storage, bucket `logos`, object `<user id>/logo`. The bucket and
/// its policies come from `supabase/schema_v7.sql`; the policies are what keep
/// one shop's logo from being read or replaced by another.
class SupabaseLogoStorage implements LogoStorage {
  SupabaseLogoStorage(
    this._client, {
    this.requestTimeout = const Duration(seconds: 30),
  });

  static const String bucket = 'logos';

  final sb.SupabaseClient _client;
  final Duration requestTimeout;

  String _path(String userId) => '$userId/logo';

  sb.StorageFileApi get _files => _client.storage.from(bucket);

  @override
  Future<void> upload(String userId, Uint8List bytes, LogoFormat format) {
    return _guard('upload', () async {
      await _files.uploadBinary(
        _path(userId),
        bytes,
        fileOptions: sb.FileOptions(
          upsert: true,
          contentType: format.mimeType,
          // The object is overwritten in place, so a cached copy would be
          // wrong the moment a new logo is chosen.
          cacheControl: '0',
        ),
      );
    });
  }

  @override
  Future<Uint8List?> download(String userId) {
    return _guard('download', () async {
      try {
        return await _files.download(_path(userId));
      } on sb.StorageException catch (e) {
        if (e.statusCode == '404') return null;
        rethrow;
      }
    });
  }

  @override
  Future<void> remove(String userId) {
    return _guard('remove', () async {
      await _files.remove([_path(userId)]);
    });
  }

  Future<T> _guard<T>(String what, Future<T> Function() body) async {
    try {
      return await body().timeout(requestTimeout);
    } on SocketException catch (e) {
      throw TransientSyncException('No network for logo $what: ${e.message}');
    } on TimeoutException {
      throw TransientSyncException(
        'Timed out after ${requestTimeout.inSeconds}s on logo $what',
      );
    } on sb.StorageException catch (e) {
      final code = int.tryParse(e.statusCode ?? '') ?? 0;
      // A 4xx other than "slow down" will fail the same way next time (no
      // bucket, no policy, wrong size or type), so it is not retried behind an
      // "offline" label.
      if (code >= 400 && code < 500 && code != 408 && code != 429) {
        throw PermanentSyncException('Logo $what rejected: ${e.message} ($code)');
      }
      throw TransientSyncException('Logo $what failed: ${e.message} ($code)');
    } on sb.AuthException catch (e) {
      throw TransientSyncException('Session problem on logo $what: ${e.message}');
    } catch (e) {
      throw TransientSyncException('Logo $what failed: $e');
    }
  }
}

/// This phone's copy of the logo image.
class LogoFiles {
  LogoFiles(this._directory);

  final Future<Directory> Function() _directory;

  /// Writes [bytes] to a new file and returns its path. A new name each time,
  /// so a picture that was just replaced is never served from an image cache
  /// keyed on the old path.
  Future<String> write(Uint8List bytes, LogoFormat format) async {
    final dir = await _directory();
    await dir.create(recursive: true);
    final name = 'logo-${DateTime.now().microsecondsSinceEpoch}.${format.extension}';
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<Uint8List?> read(String? path) async {
    if (path == null) return null;
    final file = File(path);
    try {
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  Future<void> delete(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A leftover file is untidy, not wrong.
    }
  }
}

/// Moves the logo image between this phone and Storage, around the ordinary
/// sync of the profile row.
///
/// Order within a cycle matters. [pushLogo] runs before the rows are pushed, so
/// the profile never advertises a version Storage does not have yet;
/// [pullLogo] runs after the rows are pulled, so it sees any new version
/// another phone has just announced.
///
/// Neither throws for a logo problem the shop can live without. A failed logo
/// must never hold up bills, stock or money, so errors are written to the sync
/// log and the cycle carries on.
class LogoSync {
  LogoSync({
    required this._db,
    required this.storage,
    required this.files,
    this._clock = const Clock(),
  });

  final AppDatabase _db;
  final LogoStorage storage;
  final LogoFiles files;
  final Clock _clock;

  Future<BusinessProfile?> _profile(String userId) =>
      (_db.select(_db.businessProfiles)
            ..where((t) => t.userId.equals(userId))
            ..limit(1))
          .getSingleOrNull();

  Future<void> pushLogo(String userId) =>
      _guarded('push', () => _pushLogo(userId));

  Future<void> pullLogo(String userId) =>
      _guarded('pull', () => _pullLogo(userId));

  Future<void> _pushLogo(String userId) async {
    final profile = await _profile(userId);
    if (profile == null) return;

    if (profile.logoVersion == 0) {
      // Removed on this phone; take it off the server too.
      if (profile.logoUploadedVersion > 0) {
        await storage.remove(userId);
        await _setUploaded(profile.id, 0);
      }
      return;
    }

    if (profile.logoUploadedVersion >= profile.logoVersion) return;
    // The file here is not the version the profile asks for, which means a
    // newer logo from another phone is waiting to be downloaded. Uploading the
    // old file would overwrite it.
    if (profile.logoCachedVersion != profile.logoVersion) return;

    final bytes = await files.read(profile.logoPath);
    if (bytes == null) return;
    final format = sniffLogoFormat(bytes);
    if (logoProblem(bytes) != null || format == null) return;

    await storage.upload(userId, bytes, format);

    // The profile row must go out again carrying the new version.
    await (_db.update(_db.businessProfiles)
          ..where((t) => t.id.equals(profile.id)))
        .write(
      BusinessProfilesCompanion(
        logoUploadedVersion: Value(profile.logoVersion),
        updatedAt: Value(_clock.nowMillis()),
        isDirty: const Value(true),
      ),
    );
  }

  Future<void> _pullLogo(String userId) async {
    final profile = await _profile(userId);
    if (profile == null) return;

    if (profile.logoVersion == 0) {
      if (profile.logoPath != null || profile.logoCachedVersion != 0) {
        await files.delete(profile.logoPath);
        await _setLocalCopy(profile.id, path: null, version: 0);
      }
      return;
    }

    if (profile.logoCachedVersion == profile.logoVersion) return;

    final bytes = await storage.download(userId);
    if (bytes == null) {
      throw TransientSyncException(
        'The shop logo (version ${profile.logoVersion}) is not in Storage yet',
      );
    }
    final format = sniffLogoFormat(bytes);
    if (logoProblem(bytes) != null || format == null) {
      throw PermanentSyncException(
        'The shop logo in Storage is not a usable picture',
      );
    }

    final path = await files.write(bytes, format);
    await files.delete(profile.logoPath);
    await _setLocalCopy(profile.id, path: path, version: profile.logoVersion);
  }

  Future<void> _setUploaded(String profileId, int version) =>
      (_db.update(_db.businessProfiles)..where((t) => t.id.equals(profileId)))
          .write(BusinessProfilesCompanion(logoUploadedVersion: Value(version)));

  /// Not a user edit: leaves `updated_at` and the dirty flag alone, so a logo
  /// arriving from another phone does not look like a change to push back.
  Future<void> _setLocalCopy(
    String profileId, {
    required String? path,
    required int version,
  }) =>
      (_db.update(_db.businessProfiles)..where((t) => t.id.equals(profileId)))
          .write(
        BusinessProfilesCompanion(
          logoPath: Value(path),
          logoCachedVersion: Value(version),
        ),
      );

  Future<void> _guarded(String direction, Future<void> Function() body) async {
    try {
      await body();
    } on TransientSyncException catch (e) {
      await SyncDao(_db).log(
        direction: direction,
        table: 'logo',
        rowCount: 0,
        ok: false,
        detail: e.message,
      );
    } on PermanentSyncException catch (e) {
      await SyncDao(_db).log(
        direction: direction,
        table: 'logo',
        rowCount: 0,
        ok: false,
        detail: e.message,
      );
    }
  }
}
