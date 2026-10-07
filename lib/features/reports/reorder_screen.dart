import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/quantity.dart';
import '../../domain/reports.dart';

/// What to order, most urgent first.
///
/// "12 left" is a number he has to interpret. "12 left, about 4 days" tells him
/// whether to order today or next week — which is the difference between a
/// warning and an alert he learns to swipe away.
class ReorderScreen extends ConsumerWidget {
  const ReorderScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final entries = ref.watch(reorderProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Running low')),
      body: entries.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Nothing is running low.\n\n'
                  'You are only warned about items where you set a low-stock '
                  'level on the item.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : ListView.separated(
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final e = entries[i];
                return ListTile(
                  title: Text(e.name),
                  subtitle: Text(_subtitle(e)),
                  trailing: Text(
                    e.isOut
                        ? 'Out'
                        : Qty.formatWithUnit(e.qtyThousandths, e.unit),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: e.isOut ? theme.colorScheme.error : null,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onTap: () => context.push('/items/${e.itemId}'),
                );
              },
            ),
    );
  }

  String _subtitle(ReorderEntry e) {
    final perDay = e.soldInWindowThousandths / e.windowDays;
    if (e.soldInWindowThousandths <= 0) {
      return 'Nothing sold in the last ${e.windowDays} days';
    }
    final rate = '${Qty.format(perDay.round())} a day';
    final days = e.daysLeft;
    if (e.isOut) return 'Selling about $rate';
    if (days == null) return 'Selling about $rate';
    if (days == 0) return 'Selling about $rate, less than a day left';
    return 'Selling about $rate, about $days ${days == 1 ? 'day' : 'days'} left';
  }
}
