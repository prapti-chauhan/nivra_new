import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../domain/billing.dart';
import '../sync/sync_indicator.dart';

class BillsScreen extends ConsumerWidget {
  const BillsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final bills = ref.watch(billsProvider);
    final owed = ref.watch(totalReceivableProvider).value ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bills'),
        actions: [SyncIndicator(onTap: () => context.push('/sync'))],
      ),
      body: Column(
        children: [
          if (owed > 0)
            InkWell(
              onTap: () => context.go('/customers'),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
                child: Row(
                  children: [
                    Text(
                      'Owed to you',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Text(Money.format(owed), style: theme.textTheme.money),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, size: 20),
                  ],
                ),
              ),
            ),
          Expanded(
            child: bills.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (rows) {
                if (rows.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('No bills yet', style: theme.textTheme.titleMedium),
                          const SizedBox(height: 8),
                          Text(
                            'Make a bill and the stock and the balance take '
                            'care of themselves.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => _BillRow(bill: rows[index]),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('new-bill'),
        onPressed: () => context.push('/bills/new'),
        icon: const Icon(Icons.add),
        label: const Text('New bill'),
      ),
    );
  }
}

class _BillRow extends StatelessWidget {
  const _BillRow({required this.bill});

  final Bill bill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status =
        paymentStatusFor(totalPaise: bill.total, paidPaise: bill.amountPaid);
    final when = DateTime.fromMillisecondsSinceEpoch(bill.occurredAt).toLocal();

    return ListTile(
      onTap: () => context.push('/bills/${bill.id}'),
      title: Row(
        children: [
          Expanded(
            child: Text(
              bill.customerName ?? 'Cash sale',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
          ),
          if (bill.revision > 0)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                'Edited',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        '${invoiceLabel(prefix: bill.numberPrefix, number: bill.number)}'
        ' · ${DateFormat('d MMM, h:mm a').format(when)}',
        maxLines: 1,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(Money.formatCompact(bill.total), style: theme.textTheme.money),
          const SizedBox(height: 4),
          PaymentBadge(status: status, due: bill.total - bill.amountPaid),
        ],
      ),
    );
  }
}

class PaymentBadge extends StatelessWidget {
  const PaymentBadge({super.key, required this.status, required this.due});

  final PaymentStatus status;
  final int due;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (Color color, String label) = switch (status) {
      PaymentStatus.paid => (theme.colorScheme.onSurfaceVariant, 'Paid'),
      PaymentStatus.partial => (
          const Color(0xFFB4690E),
          '${Money.formatCompact(due)} due',
        ),
      PaymentStatus.unpaid => (
          const Color(0xFFB4690E),
          '${Money.formatCompact(due)} due',
        ),
    };
    return Text(
      label,
      style: theme.textTheme.figure.copyWith(fontSize: 12.5, color: color),
    );
  }
}
