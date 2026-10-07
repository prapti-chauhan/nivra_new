import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../domain/billing.dart';

class SuppliersScreen extends ConsumerWidget {
  const SuppliersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final suppliers = ref.watch(suppliersProvider).value ?? const [];
    final payable = ref.watch(totalPayableProvider).value ?? 0;
    final search = ref.watch(supplierSearchProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Suppliers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/suppliers/new'),
        icon: const Icon(Icons.add),
        label: const Text('Supplier'),
      ),
      body: Column(
        children: [
          if (payable > 0)
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('You owe', style: theme.textTheme.bodyMedium),
                  Text(Money.format(payable), style: theme.textTheme.moneyLarge),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search suppliers',
                isDense: true,
              ),
              onChanged: (value) =>
                  ref.read(supplierSearchProvider.notifier).update(value),
            ),
          ),
          Expanded(
            child: suppliers.isEmpty
                ? _Empty(searching: search.trim().isNotEmpty)
                : ListView.separated(
                    itemCount: suppliers.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final supplier = suppliers[i];
                      final owed = payableFromBalance(supplier.balance);
                      return ListTile(
                        title: Text(supplier.name),
                        subtitle: supplier.phone == null
                            ? null
                            : Text(supplier.phone!),
                        trailing: owed == 0
                            ? null
                            : Text(
                                Money.formatCompact(owed),
                                style: theme.textTheme.money.copyWith(
                                  color: owed > 0
                                      ? theme.colorScheme.error
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                        onTap: () => context.push('/suppliers/${supplier.id}'),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          searching
              ? 'No supplier by that name.'
              : 'Nobody here yet.\nAdd the people you buy stock from.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}
