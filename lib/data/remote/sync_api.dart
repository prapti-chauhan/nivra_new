import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// What the server said about a row we pushed.
class RemoteAck {
  const RemoteAck({required this.id, required this.serverUpdatedAt});
  final String id;
  final int serverUpdatedAt;
}

/// Raised when the request failed for a reason that retrying later will fix.
class TransientSyncException implements Exception {
  TransientSyncException(this.message);
  final String message;
  @override
  String toString() => 'TransientSyncException: $message';
}

/// Raised when the server rejected the data itself. Retrying will not help and
/// the row must be parked rather than blocking everything behind it.
class PermanentSyncException implements Exception {
  PermanentSyncException(this.message);
  final String message;
  @override
  String toString() => 'PermanentSyncException: $message';
}

/// The remote end of sync. It moves maps; it does not know what a stock
/// movement is. An interface so the sync cycle can be tested end to end
/// without a network or a Supabase project.
abstract class SyncApi {
  static const String serverStampColumn = 'server_updated_at';

  /// Upserts rows and returns the server's stamp for each, which becomes the
  /// pull cursor for other installs.
  Future<List<RemoteAck>> push(String table, List<Map<String, dynamic>> rows);

  /// Everything the server has stamped after [since], oldest first so the
  /// cursor can advance safely even if the page is cut short.
  Future<List<Map<String, dynamic>>> pull(
    String table, {
    required int since,
    int limit = 500,
  });
}

class SupabaseSyncApi implements SyncApi {
  SupabaseSyncApi(this._client);

  final SupabaseClient _client;

  @override
  Future<List<RemoteAck>> push(
    String table,
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) return const [];
    return _guard(table, () async {
      final response = await _client
          .from(table)
          .upsert(rows, onConflict: 'id')
          .select('id, ${SyncApi.serverStampColumn}');

      return (response as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(
            (row) => RemoteAck(
              id: row['id'] as String,
              serverUpdatedAt: (row[SyncApi.serverStampColumn] as num?)?.toInt() ?? 0,
            ),
          )
          .toList();
    });
  }

  @override
  Future<List<Map<String, dynamic>>> pull(
    String table, {
    required int since,
    int limit = 500,
  }) async {
    return _guard(table, () async {
      final response = await _client
          .from(table)
          .select()
          .gt(SyncApi.serverStampColumn, since)
          .order(SyncApi.serverStampColumn)
          .limit(limit);

      return (response as List<dynamic>).cast<Map<String, dynamic>>();
    });
  }

  Future<T> _guard<T>(String table, Future<T> Function() body) async {
    try {
      return await body();
    } on SocketException catch (e) {
      throw TransientSyncException('No network while syncing $table: ${e.message}');
    } on TimeoutException {
      throw TransientSyncException('Timed out syncing $table');
    } on PostgrestException catch (e) {
      // 23xxx are integrity violations, 42xxx are schema problems, and
      // PGRST20x means the table, column or relationship does not exist.
      // All of them mean the payload or the schema is wrong, and sending the
      // same thing tomorrow will fail the same way — so park it loudly
      // instead of retrying forever behind an "offline" label.
      final code = e.code ?? '';
      if (code.startsWith('23') ||
          code.startsWith('42') ||
          code.startsWith('PGRST20')) {
        throw PermanentSyncException('$table rejected: ${e.message} ($code)');
      }
      throw TransientSyncException('$table failed: ${e.message} ($code)');
    } on AuthException catch (e) {
      throw TransientSyncException('Session problem syncing $table: ${e.message}');
    } catch (e) {
      throw TransientSyncException('$table failed: $e');
    }
  }
}
