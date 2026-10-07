import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../core/quantity.dart';

class PurchaseDetailScreen extends ConsumerWidget {
  const PurchaseDetailScreen({super.key, required this.purchaseId});

  final String purchaseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    ref.watch(currentUserProvider);
    final purchase = ref.watch(purchaseProvider(purchaseId)).value;
    final lines = ref.watch(purchaseLinesProvider(purchaseId)).value ?? const [];

    if (purchase == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final due = purchase.total - purchase.amountPaid;
    final when = DateTime.fromMillisecondsSinceEpoch(purchase.occurredAt);

    return Scaffold(
      appBar: AppBar(
        title: Text(purchase.supplierName ?? 'Purchase'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context, ref),
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
                    DateFormat('d MMM yyyy').format(when),
                    style: theme.textTheme.bodySmall,
                  ),
                  if (purchase.supplierBillNo != null)
                    Text(
                      'Their bill ${purchase.supplierBillNo}',
                      style: theme.textTheme.bodySmall,
                    ),
                  const SizedBox(height: 8),
                  Text(
                    Money.format(purchase.total),
                    style: theme.textTheme.moneyLarge,
                  ),
                  if (due > 0)
                    Text(
                      'Still owed ${Money.format(due)}',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.error),
                    )
                  else
                    Text('Paid', style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('What came in', style: theme.textTheme.titleSmall),
          for (final line in lines)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(line.name),
              subtitle: Text(
                '${Qty.formatWithUnit(line.qty, line.unit)}'
                ' at ${Money.format(line.unitCost)}',
              ),
              trailing: Text(Money.format(line.lineTotal)),
            ),
          if (purchase.discountAmount > 0) ...[
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Discount'),
                Text('- ${Money.format(purchase.discountAmount)}'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final userId = ref.read(currentUserProvider).value?.id;
    if (userId == null) return;

    // No confirmation dialog, matching the rest of the app: the stock and the
    // payable are both put back, so the cost of a wrong tap is one more tap.
    await ref
        .read(purchaseDaoProvider)
        .deletePurchase(userId: userId, purchaseId: purchaseId);

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Purchase removed. Stock put back.')),
    );
    context.pop();
  }
}
