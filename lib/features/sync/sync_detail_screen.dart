import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../data/remote/supabase_config.dart';
import '../../domain/sync_status.dart';

/// What the indicator means, in full.
///
/// "Never hide this from him" is taken literally: the pending count, the last
/// successful sync, and the raw push/pull log are all here, in his words
/// rather than ours.
class SyncDetailScreen extends ConsumerWidget {
  const SyncDetailScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = ref.watch(syncStatusProvider).value ??
        ref.watch(syncServiceProvider).currentStatus;
    final pending = ref.watch(pendingCountProvider).value ?? 0;
    final log = ref.watch(syncLogProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Your data')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _headline(status.phase, pending),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _explanation(status.phase, pending),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (status.message != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      status.message!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _Row(
                    label: 'Waiting to be sent',
                    value: pending == 0 ? 'Nothing' : '$pending change'
                        '${pending == 1 ? '' : 's'}',
                  ),
                  _Row(
                    label: 'Last sent',
                    value: _timestamp(status.lastSyncedAtMillis),
                  ),
                  _Row(
                    label: 'Backup',
                    value: SupabaseConfig.isConfigured
                        ? 'On'
                        : 'Off — this phone only',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (SupabaseConfig.isConfigured)
            FilledButton.tonal(
              onPressed: () => ref.read(syncServiceProvider).syncNow(),
              child: const Text('Try now'),
            ),
          const SizedBox(height: 24),
          Text('Recent activity', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (log.isEmpty)
            Text(
              'Nothing yet.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            ...log.map(
              (entry) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  entry.ok ? Icons.check_circle_outline : Icons.error_outline,
                  size: 18,
                  color: entry.ok
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.error,
                ),
                title: Text(
                  '${entry.direction == 'push' ? 'Sent' : 'Received'} '
                  '${entry.rowCount} from ${_friendlyTable(entry.entity)}',
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(
                  [
                    _timestamp(entry.at),
                    if (entry.detail != null) entry.detail!,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _headline(SyncPhase phase, int pending) => switch (phase) {
        SyncPhase.synced => 'Everything is backed up',
        SyncPhase.syncing => 'Sending now',
        SyncPhase.pending => 'Saved on this phone',
        SyncPhase.offline => 'Saved on this phone',
        SyncPhase.failed => 'Something was refused',
        SyncPhase.inactive => 'Saved on this phone',
      };

  String _explanation(SyncPhase phase, int pending) => switch (phase) {
        SyncPhase.synced =>
          'Your work is on this phone and on the server. Nothing is waiting.',
        SyncPhase.syncing => 'Sending your latest changes to the server.',
        SyncPhase.pending =>
          'Your work is safe here and will go to the server on its own.',
        SyncPhase.offline =>
          'No internet right now. Keep working — nothing is lost, and it will '
              'send itself when the connection comes back.',
        SyncPhase.failed =>
          'The server would not accept some of your data. Your work is still '
              'safe on this phone.',
        SyncPhase.inactive =>
          'Backup is not set up, so your work stays on this phone only.',
      };

  String _friendlyTable(String table) => switch (table) {
        'items' => 'items',
        'stock_movements' => 'stock',
        'business_profiles' => 'shop details',
        _ => table,
      };

  String _timestamp(int? millis) {
    if (millis == null) return 'Never';
    final when = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    final now = DateTime.now();
    if (now.difference(when).inHours < 12 &&
        now.day == when.day) {
      return DateFormat('h:mm a').format(when);
    }
    return DateFormat('d MMM, h:mm a').format(when);
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
