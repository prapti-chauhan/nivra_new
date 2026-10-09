import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../core/quantity.dart';
import '../../data/db/database.dart';

class PurchaseDetailScreen extends ConsumerWidget {
  const PurchaseDetailScreen({super.key, required this.purchaseId});

  final String purchaseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    ref.watch(currentUserProvider);
    final purchase = ref.watch(purchaseProvider(purchaseId)).value;
    final lines =
        ref.watch(purchaseLinesProvider(purchaseId)).value ?? const [];
    final revisions =
        ref.watch(purchaseRevisionsProvider(purchaseId)).value ?? const [];

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
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit',
            onPressed: () => context.push('/purchases/$purchaseId/edit'),
          ),
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
                  if (purchase.revision > 0)
                    Text('Edited', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Text(
                    Money.format(purchase.total),
                    style: theme.textTheme.moneyLarge,
                  ),
                  if (due > 0)
                    Text(
                      'Still owed ${Money.format(due)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
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
          if (revisions.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('Earlier versions', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'This purchase has been edited ${revisions.length} '
              'time${revisions.length == 1 ? '' : 's'}. Nothing was erased.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            for (final r in revisions) _RevisionTile(revision: r),
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

class _RevisionTile extends StatelessWidget {
  const _RevisionTile({required this.revision});

  final PurchaseRevision revision;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = jsonDecode(revision.snapshot) as Map<String, dynamic>;
    final lines = (data['lines'] as List).cast<Map<String, dynamic>>();
    final when = DateTime.fromMillisecondsSinceEpoch(
      revision.replacedAt,
    ).toLocal();

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: 8, bottom: 12),
      title: Text(
        'Version ${revision.revision + 1} · '
        '${Money.formatCompact((data['total'] as num).toInt())}',
        style: theme.textTheme.bodyLarge,
      ),
      subtitle: Text(
        'Replaced ${DateFormat('d MMM yyyy, h:mm a').format(when)}',
        style: theme.textTheme.bodySmall,
      ),
      children: [
        if (data['supplier_name'] != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'From ${data['supplier_name']}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${line['name']}  ·  '
                    '${Qty.formatWithUnit((line['qty'] as num).toInt(), line['unit'] as String)}'
                    ' at ${Money.format((line['unit_cost'] as num).toInt())}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Text(
                  Money.format((line['line_total'] as num).toInt()),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
