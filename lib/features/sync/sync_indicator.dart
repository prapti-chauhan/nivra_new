import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/sync_status.dart';

/// Always visible, never alarming.
///
/// The brief is explicit that Ramesh can always see whether his data is safe.
/// Waiting to sync is the normal state in a shop with bad coverage, so it is
/// shown in plain language and neutral colour; only a genuine rejection is
/// given a warning colour.
class SyncIndicator extends ConsumerWidget {
  const SyncIndicator({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Before the service has emitted, fall back to what it actually knows —
    // never to "Saved". Claiming the data is safe when we have not checked is
    // the one thing this indicator must not do.
    final status = ref.watch(syncStatusProvider).value ??
        ref.watch(syncServiceProvider).currentStatus;
    final pending = ref.watch(pendingCountProvider).value ?? status.pendingCount;
    final theme = Theme.of(context);

    final view = _describe(context, status.phase, pending);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (view.spinning)
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: view.color,
                ),
              )
            else
              Icon(view.icon, size: 16, color: view.color),
            const SizedBox(width: 7),
            Text(
              view.label,
              style: theme.textTheme.labelLarge?.copyWith(color: view.color),
            ),
          ],
        ),
      ),
    );
  }

  _IndicatorView _describe(BuildContext context, SyncPhase phase, int pending) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;

    return switch (phase) {
      SyncPhase.synced => _IndicatorView(
          label: 'Saved',
          icon: Icons.cloud_done_outlined,
          color: muted,
        ),
      SyncPhase.syncing => _IndicatorView(
          label: 'Saving',
          icon: Icons.sync,
          color: muted,
          spinning: true,
        ),
      SyncPhase.pending => _IndicatorView(
          label: pending == 1 ? '1 waiting' : '$pending waiting',
          icon: Icons.schedule_outlined,
          color: muted,
        ),
      SyncPhase.offline => _IndicatorView(
          label: pending > 0 ? '$pending waiting' : 'Offline',
          icon: Icons.cloud_off_outlined,
          color: muted,
        ),
      SyncPhase.failed => _IndicatorView(
          label: 'Sync problem',
          icon: Icons.error_outline,
          color: scheme.error,
        ),
      SyncPhase.inactive => _IndicatorView(
          label: 'On this phone',
          icon: Icons.phone_android_outlined,
          color: muted,
        ),
    };
  }
}

class _IndicatorView {
  const _IndicatorView({
    required this.label,
    required this.icon,
    required this.color,
    this.spinning = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool spinning;
}
