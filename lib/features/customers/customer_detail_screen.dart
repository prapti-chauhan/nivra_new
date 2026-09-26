import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../domain/billing.dart';

/// A balance and everything behind it.
///
/// Same principle as the stock screen: the number at the top is not stored
/// anywhere authoritative, it is the sum of the rows underneath, and every row
/// names the bill or payment that caused it.
class CustomerDetailScreen extends ConsumerWidget {
  const CustomerDetailScreen({super.key, required this.customerId});

  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Keep the session provider alive so the id is present when a write
    // happens; an unlistened StreamProvider is still loading on first read.
    ref.watch(currentUserProvider);
    final customer = ref.watch(customerProvider(customerId)).value;
    final ledger = ref.watch(customerLedgerProvider(customerId)).value ?? const [];

    if (customer == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final owes = customer.balance > 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(customer.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context, ref, customer),
          ),
        ],
      ),
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
                    customer.balance == 0
                        ? 'Settled up'
                        : owes
                            ? 'Owes you'
                            : 'Paid in advance',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    Money.format(customer.balance.abs()),
                    style: theme.textTheme.moneyLarge.copyWith(
                      color: owes ? const Color(0xFFB4690E) : null,
                    ),
                  ),
                  if (customer.phone != null) ...[
                    const Divider(height: 28),
                    Row(
                      children: [
                        const Icon(Icons.phone_outlined, size: 18),
                        const SizedBox(width: 10),
                        Text(customer.phone!, style: theme.textTheme.figure),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (owes)
            FilledButton.tonal(
              onPressed: () => _recordPayment(context, ref, customer),
              child: Text(
                'Record payment of ${Money.formatCompact(customer.balance)}',
              ),
            ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Every transaction', style: theme.textTheme.titleSmall),
              Text(
                '${ledger.length} entr${ledger.length == 1 ? 'y' : 'ies'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'The number above is the total of these.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          if (ledger.isEmpty)
            Text(
              'Nothing yet.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            ...ledger.map((entry) => _LedgerRow(entry: entry)),
        ],
      ),
    );
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    Customer customer,
  ) async {
    final dao = ref.read(partyDaoProvider);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    await dao.setCustomerDeleted(customer.id, deleted: true);
    router.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text('${customer.name} removed'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => dao.setCustomerDeleted(customer.id, deleted: false),
        ),
      ),
    );
  }

  Future<void> _recordPayment(
    BuildContext context,
    WidgetRef ref,
    Customer customer,
  ) async {
    final controller =
        TextEditingController(text: Money.formatPlain(customer.balance));
    final amount = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Payment from ${customer.name}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: const InputDecoration(
            labelText: 'Amount received',
            prefixText: '₹ ',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, Money.tryParse(controller.text)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    final userId = ref.read(currentUserProvider).value?.id;
    if (amount == null || amount <= 0 || userId == null) return;

    await ref.read(billingDaoProvider).recordPayment(
          userId: userId,
          customerId: customer.id,
          amount: amount,
        );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.entry});

  final LedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = LedgerReason.fromWire(entry.reason);
    final increases = entry.amount >= 0;
    final when =
        DateTime.fromMillisecondsSinceEpoch(entry.occurredAt).toLocal();

    return InkWell(
      onTap: entry.sourceType == 'bill' && entry.sourceId != null
          ? () => context.push('/bills/${entry.sourceId}')
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              increases ? Icons.north_east : Icons.south_west,
              size: 18,
              color: increases
                  ? const Color(0xFFB4690E)
                  : theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_label(reason), style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 2),
                  Text(
                    DateFormat('d MMM yyyy, h:mm a').format(when),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '${increases ? '+' : ''}${Money.formatPlain(entry.amount)}',
              style: theme.textTheme.figure.copyWith(
                fontWeight: FontWeight.w600,
                color: increases ? const Color(0xFFB4690E) : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _label(LedgerReason reason) => switch (reason) {
        LedgerReason.sale => 'Bill',
        LedgerReason.saleReversal => 'Bill corrected',
        LedgerReason.paymentIn => 'Payment received',
        LedgerReason.paymentInReversal => 'Payment reversed',
        LedgerReason.opening => 'Opening balance',
        LedgerReason.adjustment => 'Adjusted by hand',
      };
}
