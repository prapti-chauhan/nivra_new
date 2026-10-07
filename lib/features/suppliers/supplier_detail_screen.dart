import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../domain/billing.dart';

class SupplierDetailScreen extends ConsumerWidget {
  const SupplierDetailScreen({super.key, required this.supplierId});

  final String supplierId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    ref.watch(currentUserProvider);
    final supplier = ref.watch(supplierProvider(supplierId)).value;
    final ledger = ref.watch(supplierLedgerProvider(supplierId)).value ?? const [];
    final purchases =
        ref.watch(purchasesForSupplierProvider(supplierId)).value ?? const [];

    if (supplier == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final owed = payableFromBalance(supplier.balance);

    return Scaffold(
      appBar: AppBar(
        title: Text(supplier.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => context.push('/suppliers/$supplierId/edit'),
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
                    owed > 0
                        ? 'You owe'
                        : owed < 0
                            ? 'They owe you'
                            : 'Settled up',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    Money.format(owed.abs()),
                    style: theme.textTheme.moneyLarge.copyWith(
                      color: owed > 0 ? theme.colorScheme.error : null,
                    ),
                  ),
                  if (supplier.phone != null) ...[
                    const SizedBox(height: 8),
                    Text(supplier.phone!, style: theme.textTheme.bodySmall),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _pay(context, ref, supplier, owed),
                          icon: const Icon(Icons.payments_outlined, size: 18),
                          label: const Text('Pay'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () =>
                              context.push('/purchases/new?supplier=$supplierId'),
                          icon: const Icon(Icons.add_shopping_cart, size: 18),
                          label: const Text('Purchase'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Purchases', style: theme.textTheme.titleSmall),
          if (purchases.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Nothing bought from them yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (final purchase in purchases)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  purchase.supplierBillNo == null
                      ? Money.format(purchase.total)
                      : '${purchase.supplierBillNo}  ·  ${Money.format(purchase.total)}',
                ),
                subtitle: Text(
                  DateFormat('d MMM yyyy').format(
                    DateTime.fromMillisecondsSinceEpoch(purchase.occurredAt),
                  ),
                ),
                trailing: purchase.amountPaid >= purchase.total
                    ? null
                    : Text(
                        'due ${Money.formatCompact(purchase.total - purchase.amountPaid)}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                onTap: () => context.push('/purchases/${purchase.id}'),
              ),
          const SizedBox(height: 16),
          Text('Every transaction', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          if (ledger.isEmpty)
            Text(
              'Nothing yet.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            for (final entry in ledger) _LedgerRow(entry: entry),
        ],
      ),
    );
  }

  Future<void> _pay(
    BuildContext context,
    WidgetRef ref,
    Supplier supplier,
    int owed,
  ) async {
    final controller = TextEditingController(
      text: owed > 0 ? Money.formatPlain(owed) : '',
    );
    final amount = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Pay ${supplier.name}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(prefixText: '₹ '),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, Money.tryParse(controller.text)),
            child: const Text('Record'),
          ),
        ],
      ),
    );

    if (amount == null || amount <= 0) return;
    final userId = ref.read(currentUserProvider).value?.id;
    if (userId == null) return;

    await ref.read(purchaseDaoProvider).recordSupplierPayment(
          userId: userId,
          supplierId: supplier.id,
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
    // Positive means owed to Ramesh, so on a supplier's ledger a positive row
    // is money he handed over and a negative row is stock he took on credit.
    final increasesDebt = entry.amount < 0;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(ledgerReasonLabel(LedgerReason.fromWire(entry.reason))),
      subtitle: Text(
        DateFormat('d MMM yyyy').format(
          DateTime.fromMillisecondsSinceEpoch(entry.occurredAt),
        ),
      ),
      trailing: Text(
        '${increasesDebt ? '+' : '-'}${Money.formatCompact(entry.amount.abs())}',
        style: theme.textTheme.money.copyWith(
          color: increasesDebt
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
