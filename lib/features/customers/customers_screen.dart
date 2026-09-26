import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../sync/sync_indicator.dart';

class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Keep the session provider alive so the id is present when a write
    // happens; an unlistened StreamProvider is still loading on first read.
    ref.watch(currentUserProvider);
    final customers = ref.watch(customersProvider);
    final owed = ref.watch(totalReceivableProvider).value ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Customers'),
        actions: [SyncIndicator(onTap: () => context.push('/sync'))],
      ),
      body: Column(
        children: [
          if (owed > 0)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
              child: Row(
                children: [
                  Text(
                    'Owed to you in total',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(Money.format(owed), style: theme.textTheme.money),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: TextField(
              controller: _search,
              onChanged: (v) =>
                  ref.read(customerSearchProvider.notifier).update(v),
              decoration: const InputDecoration(
                hintText: 'Search customers',
                prefixIcon: Icon(Icons.search, size: 22),
              ),
            ),
          ),
          Expanded(
            child: customers.when(
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
                          Text('No customers yet',
                              style: theme.textTheme.titleMedium),
                          const SizedBox(height: 8),
                          Text(
                            'You only need one when a bill goes on credit. '
                            'Cash sales do not need a name.',
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
                  itemBuilder: (context, i) => _CustomerRow(customer: rows[i]),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addCustomer(context),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add customer'),
      ),
    );
  }

  Future<void> _addCustomer(BuildContext context) async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          20,
          16,
          MediaQuery.of(sheetContext).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New customer',
                style: Theme.of(sheetContext).textTheme.titleMedium),
            const SizedBox(height: 16),
            TextField(
              controller: nameController,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone',
                hintText: 'Optional',
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(sheetContext, true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    final name = nameController.text.trim();
    final phone = phoneController.text.trim();
    nameController.dispose();
    phoneController.dispose();

    if (saved != true || name.isEmpty) return;
    final userId = ref.read(currentUserProvider).value?.id;
    if (userId == null) return;

    await ref.read(partyDaoProvider).createCustomer(
          userId: userId,
          name: name,
          phone: phone.isEmpty ? null : phone,
        );
  }
}

class _CustomerRow extends StatelessWidget {
  const _CustomerRow({required this.customer});

  final Customer customer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final owes = customer.balance > 0;

    return ListTile(
      onTap: () => context.push('/customers/${customer.id}'),
      title: Text(customer.name, style: theme.textTheme.titleSmall),
      subtitle: customer.phone == null ? null : Text(customer.phone!),
      trailing: customer.balance == 0
          ? Text(
              'Settled',
              style: theme.textTheme.figure.copyWith(
                fontSize: 12.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  Money.formatCompact(customer.balance.abs()),
                  style: theme.textTheme.money.copyWith(
                    color: owes ? const Color(0xFFB4690E) : null,
                  ),
                ),
                Text(
                  owes ? 'owes you' : 'in advance',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
    );
  }
}
