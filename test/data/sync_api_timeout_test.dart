import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nivra_new/data/remote/sync_api.dart';
import 'package:supabase/supabase.dart';

/// A request that never returns is what a dropped connection on bad coverage
/// actually looks like: it does not fail, it just stops answering.
///
/// Without a timeout that one request holds the sync cycle open for as long as
/// the app runs, and because overlapping cycles collapse into the one already in
/// flight, every later attempt does nothing. Sync is silently dead until the app
/// is restarted — in exactly the kind of shop this app is for.
void main() {
  SupabaseClient clientAnswering(http.Client httpClient) => SupabaseClient(
        'https://example.supabase.co',
        'publishable-key',
        httpClient: httpClient,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );

  final neverAnswers = MockClient((request) => Completer<http.Response>().future);

  test('a pull that never answers becomes a retryable failure', () async {
    final api = SupabaseSyncApi(
      clientAnswering(neverAnswers),
      requestTimeout: const Duration(milliseconds: 100),
    );

    await expectLater(
      api.pull('items', since: 0),
      throwsA(
        isA<TransientSyncException>().having(
          (e) => e.message,
          'message',
          allOf(contains('Timed out'), contains('items')),
        ),
      ),
    );
  });

  test('a push that never answers becomes a retryable failure', () async {
    final api = SupabaseSyncApi(
      clientAnswering(neverAnswers),
      requestTimeout: const Duration(milliseconds: 100),
    );

    await expectLater(
      api.push('items', [
        {'id': 'a'}
      ]),
      throwsA(isA<TransientSyncException>()),
    );
  });

  test('it is transient, not permanent, so it is retried rather than parked',
      () async {
    final api = SupabaseSyncApi(
      clientAnswering(neverAnswers),
      requestTimeout: const Duration(milliseconds: 100),
    );
    Object? caught;
    try {
      await api.pull('items', since: 0);
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<TransientSyncException>());
    expect(caught, isNot(isA<PermanentSyncException>()));
  });

  test('a request that answers in time is untouched', () async {
    final api = SupabaseSyncApi(
      clientAnswering(
        // The response must carry its request, as a real one does: postgrest
        // reads it back and throws a null-check error on a bare response.
        MockClient((request) async => http.Response(
              '[{"id":"a","server_updated_at":5}]',
              200,
              request: request,
              headers: {'content-type': 'application/json'},
            )),
      ),
      requestTimeout: const Duration(seconds: 5),
    );

    final rows = await api.pull('items', since: 0);
    expect(rows.single['id'], 'a');
  });

  test('the default allows a slow connection a fair while', () {
    final api = SupabaseSyncApi(clientAnswering(neverAnswers));
    // Generous enough for 2G, short enough that a dead request is retried
    // within the same minute instead of never.
    expect(api.requestTimeout, const Duration(seconds: 30));
  });
}
