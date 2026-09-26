import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart';

/// null customer means a cash sale; a null result means the sheet was
/// dismissed without choosing anything.
class CustomerSelection {
  const CustomerSelection(this.customer);
  const CustomerSelection.cashSale() : customer = null;
  final Customer? customer;
}

Future<CustomerSelection?> showCustomerPicker(BuildContext context) {
  return showModalBottomSheet<CustomerSelection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _CustomerPickerSheet(),
  );
}

class _CustomerPickerSheet extends ConsumerStatefulWidget {
  const _CustomerPickerSheet();

  @override
  ConsumerState<_CustomerPickerSheet> createState() => _SheetState();
}

class _SheetState extends ConsumerState<_CustomerPickerSheet> {
  final _search = TextEditingController();
  String _query = '';
  bool _saving = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _createAndPick(String name) async {
    final userId = ref.read(currentUserProvider).value?.id;
    if (userId == null || name.trim().isEmpty) return;
    setState(() => _saving = true);

    final dao = ref.read(partyDaoProvider);
    final id = await dao.createCustomer(userId: userId, name: name.trim());
    final customer = await dao.findCustomer(id);
    if (mounted && customer != null) {
      Navigator.pop(context, CustomerSelection(customer));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Keep the session provider alive so the id is present when a write
    // happens; an unlistened StreamProvider is still loading on first read.
    ref.watch(currentUserProvider);
    final all = ref.watch(customersProvider).value ?? const <Customer>[];
    final term = _query.trim().toLowerCase();
    final matches = term.isEmpty
        ? all
        : all
            .where((c) =>
                c.name.toLowerCase().contains(term) ||
                (c.phone ?? '').contains(term))
            .toList();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) {
          return Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: TextField(
                  controller: _search,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: const InputDecoration(
                    hintText: 'Search or type a new name',
                    prefixIcon: Icon(Icons.search, size: 22),
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.payments_outlined),
                      title: const Text('Cash sale'),
                      subtitle: const Text('No name on the bill'),
                      onTap: () => Navigator.pop(
                        context,
                        const CustomerSelection.cashSale(),
                      ),
                    ),
                    const Divider(height: 1),
                    if (term.isNotEmpty &&
                        !all.any((c) => c.name.toLowerCase() == term))
                      ListTile(
                        leading: Icon(
                          Icons.person_add_alt,
                          color: theme.colorScheme.primary,
                        ),
                        title: Text('Add "${_search.text.trim()}"'),
                        subtitle: const Text('New customer'),
                        onTap: _saving
                            ? null
                            : () => _createAndPick(_search.text),
                      ),
                    ...matches.map(
                      (customer) => ListTile(
                        title: Text(customer.name),
                        subtitle: customer.phone == null
                            ? null
                            : Text(customer.phone!),
                        trailing: customer.balance == 0
                            ? null
                            : Text(
                                customer.balance > 0
                                    ? '${Money.formatCompact(customer.balance)} due'
                                    : '${Money.formatCompact(-customer.balance)} advance',
                                style: theme.textTheme.figure.copyWith(
                                  fontSize: 12.5,
                                  color: customer.balance > 0
                                      ? const Color(0xFFB4690E)
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                        onTap: () => Navigator.pop(
                          context,
                          CustomerSelection(customer),
                        ),
                      ),
                    ),
                    if (matches.isEmpty && term.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'No customers yet. Type a name to add one.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
