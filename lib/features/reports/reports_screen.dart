import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../domain/reports.dart';
import '../sync/sync_indicator.dart';

/// The three questions from the brief, answered at a glance: how much did I
/// make, who owes me, what is running out. Every figure here is a door — tap it
/// and the transactions behind it open, because he will not trust a number he
/// cannot open up.
class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final period = ref.watch(reportPeriodProvider);
    final summary = ref.watch(profitSummaryProvider);
    final owed = ref.watch(totalReceivableProvider).value ?? 0;
    final payable = ref.watch(totalPayableProvider).value ?? 0;
    final low = ref.watch(reorderProvider).value ?? const [];
    final items = ref.watch(stockItemsProvider).value ?? const [];

    final stockValue = items.fold<int>(
      0,
      (sum, i) => sum +
          stockValuePaise(
            qtyThousandths: i.stockQty,
            unitCostPaise: i.purchasePrice,
          ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [SyncIndicator(onTap: () => context.push('/sync'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final p in ReportPeriod.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(p.label),
                      selected: p == period,
                      onSelected: (_) =>
                          ref.read(reportPeriodProvider.notifier).choose(p),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _Tile(
            label: 'Sales',
            value: Money.format(summary.salesPaise),
            detail: summary.billCount == 1
                ? '1 bill'
                : '${summary.billCount} bills',
            onTap: () => context.push('/reports/sales'),
          ),
          _Tile(
            label: 'Profit on goods sold',
            value: Money.format(summary.profitPaise),
            detail: summary.marginPercent == null
                ? null
                : '${summary.marginPercent}% of sales',
            // Not a footnote. Profit that quietly counts an unknown cost as
            // zero is the one way this screen could mislead him.
            warning: summary.hasUnknownCost
                ? '${summary.unknownCostLines} '
                    '${summary.unknownCostLines == 1 ? 'line has' : 'lines have'}'
                    ' no cost on record, so this is more than you really made'
                : null,
            onTap: () => context.push('/reports/profit'),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 0, 6),
            child: Text(
              'Right now',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _Tile(
            label: 'Owed to you',
            value: Money.format(owed),
            onTap: () => context.push('/reports/owed'),
          ),
          _Tile(
            label: 'You owe',
            value: Money.format(payable),
            onTap: () => context.push('/reports/owed'),
          ),
          _Tile(
            label: 'Stock on hand',
            value: Money.format(stockValue),
            detail: 'at what you paid',
            onTap: () => context.push('/reports/stock'),
          ),
          _Tile(
            label: 'Running low',
            value: low.isEmpty ? 'Nothing' : '${low.length}',
            detail: low.isEmpty
                ? null
                : low.length == 1
                    ? 'item to reorder'
                    : 'items to reorder',
            onTap: () => context.push('/reports/reorder'),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.value,
    required this.onTap,
    this.detail,
    this.warning,
  });

  final String label;
  final String value;
  final String? detail;
  final String? warning;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: theme.textTheme.bodyMedium),
                        if (detail != null)
                          Text(
                            detail!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Text(value, style: theme.textTheme.moneyLarge),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              if (warning != null) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 16,
                      color: Color(0xFFB4690E),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        warning!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFB4690E),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The period chips again, for the screens a tile opens into, so he can change
/// the span without backing out.
class PeriodBar extends ConsumerWidget {
  const PeriodBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(reportPeriodProvider);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          for (final p in ReportPeriod.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(p.label),
                selected: p == period,
                onSelected: (_) =>
                    ref.read(reportPeriodProvider.notifier).choose(p),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shared by the sales and profit lists.
String billSubtitle(BillProfit bill) {
  final who = bill.customerName ?? 'Cash sale';
  final when = DateTime.fromMillisecondsSinceEpoch(bill.occurredAt);
  final hh = when.hour % 12 == 0 ? 12 : when.hour % 12;
  final mm = when.minute.toString().padLeft(2, '0');
  final ampm = when.hour < 12 ? 'am' : 'pm';
  return '$who  ·  ${when.day}/${when.month}  $hh:$mm $ampm';
}
