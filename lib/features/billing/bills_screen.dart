import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../domain/billing.dart';
import '../customers/customers_screen.dart';
import '../sync/sync_indicator.dart';

enum BillFilter { all, paid, unpaid }

/// Narrows [bills] by what the shopkeeper typed and the payment filter.
///
/// Matches the customer name or the bill number as printed ("INV-12"), since
/// people look a bill up by either. Unpaid includes part-paid bills: anything
/// still owing money.
List<Bill> filterBills(List<Bill> bills, String query, BillFilter filter) {
  final term = query.trim().toLowerCase();
  return bills.where((b) {
    final due = b.total - b.amountPaid;
    switch (filter) {
      case BillFilter.all:
        break;
      case BillFilter.paid:
        if (due > 0) return false;
      case BillFilter.unpaid:
        if (due <= 0) return false;
    }
    if (term.isEmpty) return true;
    final label = invoiceLabel(prefix: b.numberPrefix, number: b.number);
    return (b.customerName ?? 'cash sale').toLowerCase().contains(term) ||
        label.toLowerCase().contains(term);
  }).toList();
}

/// The landing screen: quick links, a searchable list of bills, and a second
/// tab for parties. Laid out the way shopkeepers coming from other billing
/// apps expect to find things.
class BillsScreen extends ConsumerStatefulWidget {
  const BillsScreen({super.key});

  @override
  ConsumerState<BillsScreen> createState() => _BillsScreenState();
}

class _BillsScreenState extends ConsumerState<BillsScreen> {
  final _search = TextEditingController();
  bool _parties = false;
  BillFilter _filter = BillFilter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _addTxn() async {
    final router = GoRouter.of(context);
    final route = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Sale'),
              onTap: () => Navigator.pop(sheet, '/bills/new'),
            ),
            // Straight to a new expense: tea, a repair and the rent are paid
            // at the counter, and the form is otherwise four screens away.
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('Expense'),
              onTap: () => Navigator.pop(sheet, '/reports/money/new/expense'),
            ),
          ],
        ),
      ),
    );
    if (route != null) router.push(route);
  }

  Future<void> _pickFilter() async {
    final picked = await showModalBottomSheet<BillFilter>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in BillFilter.values)
              ListTile(
                title: Text(switch (f) {
                  BillFilter.all => 'All',
                  BillFilter.paid => 'Paid',
                  BillFilter.unpaid => 'Unpaid',
                }),
                trailing: f == _filter ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(sheet, f),
              ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => _filter = picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = ref.watch(businessProfileProvider).value;
    final logo = ref.watch(logoBytesProvider).value;
    final shopName = (profile?.shopName ?? '').trim();

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    backgroundImage: logo == null ? null : MemoryImage(logo),
                    onBackgroundImageError: logo == null ? null : (_, _) {},
                    child: logo == null
                        ? Icon(
                            Icons.storefront_outlined,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant,
                          )
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      shopName.isEmpty ? 'My shop' : shopName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  SyncIndicator(onTap: () => context.push('/sync')),
                  IconButton(
                    key: const Key('home-settings'),
                    icon: const Icon(Icons.settings_outlined),
                    tooltip: 'Settings',
                    onPressed: () => context.go('/more'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: _TabPill(
                      label: 'Transaction Details',
                      selected: !_parties,
                      onTap: () => setState(() => _parties = false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _TabPill(
                      label: 'Party Details',
                      selected: _parties,
                      onTap: () => setState(() => _parties = true),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _parties
                  ? _PartyList(query: _search.text, search: _searchBar())
                  : _TxnList(
                      query: _search.text,
                      filter: _filter,
                      search: _searchBar(),
                      onAddTxn: _addTxn,
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        key: const Key('new-bill'),
        onPressed: () => context.push('/bills/new'),
        icon: const Icon(Icons.currency_rupee),
        label: const Text('Add New Sale'),
      ),
    );
  }

  Widget _searchBar() {
    final theme = Theme.of(context);
    final filtering = _filter != BillFilter.all;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        key: const Key('home-search'),
        controller: _search,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: _parties
              ? 'Search for a party'
              : 'Search for a transaction',
          prefixIcon: const Icon(Icons.search, size: 22),
          suffixIcon: _parties
              ? null
              : IconButton(
                  key: const Key('home-filter'),
                  tooltip: 'Filter',
                  icon: Icon(
                    filtering ? Icons.filter_alt : Icons.filter_alt_outlined,
                    color: filtering ? theme.colorScheme.primary : null,
                  ),
                  onPressed: _pickFilter,
                ),
        ),
      ),
    );
  }
}

class _TabPill extends StatelessWidget {
  const _TabPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer.withValues(alpha: 0.6)
              : null,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _TxnList extends ConsumerWidget {
  const _TxnList({
    required this.query,
    required this.filter,
    required this.search,
    required this.onAddTxn,
  });

  final String query;
  final BillFilter filter;
  final Widget search;
  final VoidCallback onAddTxn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final bills = ref.watch(billsProvider);

    return bills.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (all) {
        final rows = filterBills(all, query, filter);
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: rows.isEmpty ? 3 : rows.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) return _QuickLinks(onAddTxn: onAddTxn);
            if (index == 1) return search;
            if (rows.isEmpty) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(40, 48, 40, 0),
                child: Column(
                  children: [
                    Text(
                      all.isEmpty ? 'No bills yet' : 'No matching bills',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      all.isEmpty
                          ? 'Make a bill and the stock and the balance take '
                                'care of themselves.'
                          : 'Try a different name, number or filter.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            }
            return _TxnCard(bill: rows[index - 2]);
          },
        );
      },
    );
  }
}

class _PartyList extends ConsumerWidget {
  const _PartyList({required this.query, required this.search});

  final String query;
  final Widget search;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final customers = ref.watch(customersProvider);
    final owed = ref.watch(totalReceivableProvider).value ?? 0;
    final term = query.trim().toLowerCase();

    return customers.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (all) {
        final rows = term.isEmpty
            ? all
            : all.where((c) => c.name.toLowerCase().contains(term)).toList();
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: rows.isEmpty ? 3 : rows.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) {
              if (owed <= 0) return const SizedBox.shrink();
              return InkWell(
                onTap: () => context.go('/customers'),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  color: theme.colorScheme.secondaryContainer.withValues(
                    alpha: 0.5,
                  ),
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
              );
            }
            if (index == 1) {
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: search,
              );
            }
            if (rows.isEmpty) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(40, 48, 40, 0),
                child: Text(
                  all.isEmpty ? 'No customers yet' : 'No matching parties',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
              );
            }
            return CustomerRow(customer: rows[index - 2]);
          },
        );
      },
    );
  }
}

class _QuickLinks extends StatelessWidget {
  const _QuickLinks({required this.onAddTxn});

  final VoidCallback onAddTxn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text('Quick Links', style: theme.textTheme.titleMedium),
            ),
            Row(
              children: [
                _QuickLink(
                  icon: Icons.note_add_outlined,
                  label: 'Add Txn',
                  onTap: onAddTxn,
                ),
                _QuickLink(
                  icon: Icons.assessment_outlined,
                  label: 'Sale Report',
                  onTap: () => context.push('/reports/sales'),
                ),
                _QuickLink(
                  icon: Icons.menu_book_outlined,
                  label: 'Day Book',
                  onTap: () => context.push('/reports/money'),
                ),
                _QuickLink(
                  icon: Icons.swap_vert_circle_outlined,
                  label: 'Profit & Loss',
                  onTap: () => context.push('/reports/pnl'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickLink extends StatelessWidget {
  const _QuickLink({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.6,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: theme.colorScheme.primary),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TxnCard extends StatelessWidget {
  const _TxnCard({required this.bill});

  final Bill bill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final when = DateTime.fromMillisecondsSinceEpoch(bill.occurredAt).toLocal();
    final due = bill.total - bill.amountPaid;

    Widget figure(String label, int paise) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
        const SizedBox(height: 2),
        Text(Money.format(paise), style: theme.textTheme.money),
      ],
    );

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/bills/${bill.id}'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      bill.customerName ?? 'Cash sale',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '#${invoiceLabel(prefix: bill.numberPrefix, number: bill.number)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                        Text(
                          DateFormat('d MMM, yy').format(when),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(
                        alpha: 0.7,
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'SALE',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (bill.revision > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        'Edited',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: figure('Total', bill.total)),
                  Expanded(child: figure('Balance', due < 0 ? 0 : due)),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    onSelected: (v) => switch (v) {
                      'view' => context.push('/bills/${bill.id}'),
                      'edit' => context.push('/bills/${bill.id}/edit'),
                      _ => context.push('/bills/${bill.id}/share'),
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'view', child: Text('View')),
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'share', child: Text('Share')),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
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
