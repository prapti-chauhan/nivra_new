import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';

class PurchasesScreen extends ConsumerWidget {
  const PurchasesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final purchases = ref.watch(purchasesProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Purchases')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/purchases/new'),
        icon: const Icon(Icons.add),
        label: const Text('Purchase'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search by supplier or their bill number',
                isDense: true,
              ),
              onChanged: (value) =>
                  ref.read(purchasesSearchProvider.notifier).update(value),
            ),
          ),
          Expanded(
            child: purchases.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Nothing recorded yet.\nAdd a purchase when stock arrives.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: purchases.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final purchase = purchases[i];
                      final due = purchase.total - purchase.amountPaid;
                      return ListTile(
                        title: Text(purchase.supplierName ?? 'Supplier'),
                        subtitle: Text(
                          [
                            DateFormat('d MMM yyyy').format(
                              DateTime.fromMillisecondsSinceEpoch(
                                purchase.occurredAt,
                              ),
                            ),
                            if (purchase.supplierBillNo != null)
                              purchase.supplierBillNo!,
                          ].join('  ·  '),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              Money.formatCompact(purchase.total),
                              style: theme.textTheme.money,
                            ),
                            if (due > 0)
                              Text(
                                'due ${Money.formatCompact(due)}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                          ],
                        ),
                        onTap: () => context.push('/purchases/${purchase.id}'),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
