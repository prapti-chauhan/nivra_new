import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import 'reports_screen.dart';

/// Every bill behind the Sales figure. Tapping one opens the bill itself.
class SalesReportScreen extends ConsumerWidget {
  const SalesReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final period = ref.watch(reportPeriodProvider);
    final bills = ref.watch(billProfitsProvider).value ?? const [];
    final summary = ref.watch(profitSummaryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Sales')),
      body: Column(
        children: [
          const PeriodBar(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Text(
                    '${period.label}, ${summary.billCount} '
                    '${summary.billCount == 1 ? 'bill' : 'bills'}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Text(
                  Money.format(summary.salesPaise),
                  style: theme.textTheme.moneyLarge,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: bills.isEmpty
                ? Center(
                    child: Text(
                      'No bills ${period.label.toLowerCase()}.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: bills.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final bill = bills[i];
                      return ListTile(
                        title: Text(bill.label),
                        subtitle: Text(billSubtitle(bill)),
                        trailing: Text(
                          Money.format(bill.totalPaise),
                          style: theme.textTheme.money,
                        ),
                        onTap: () => context.push('/bills/${bill.billId}'),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
