import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../domain/stock.dart';
import '../sync/sync_indicator.dart';

class ItemsScreen extends ConsumerStatefulWidget {
  const ItemsScreen({super.key});

  @override
  ConsumerState<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends ConsumerState<ItemsScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(itemsProvider);
    final query = ref.watch(itemSearchProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Items'),
        actions: [
          SyncIndicator(onTap: () => context.push('/sync')),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: (value) =>
                  ref.read(itemSearchProvider.notifier).update(value),
              decoration: InputDecoration(
                hintText: 'Search items',
                prefixIcon: const Icon(Icons.search, size: 22),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () {
                          _search.clear();
                          ref.read(itemSearchProvider.notifier).update('');
                        },
                      ),
              ),
            ),
          ),
          Expanded(
            child: items.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _Message(
                title: 'Could not read your items',
                body: '$error',
              ),
              data: (rows) {
                if (rows.isEmpty) {
                  return _Message(
                    title: query.isEmpty
                        ? 'No items yet'
                        : 'Nothing matches "$query"',
                    body: query.isEmpty
                        ? 'Add the things you sell. Stock goes up when you '
                            'buy and down when you bill.'
                        : 'Try a different word, or add it as a new item.',
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => _ItemRow(item: rows[index]),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/items/new'),
        icon: const Icon(Icons.add),
        label: const Text('Add item'),
      ),
    );
  }

}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = stockStatusFor(
      qtyThousandths: item.stockQty,
      thresholdThousandths: item.lowStockThreshold,
    );
    final subtitle = [
      if (item.code != null && item.code!.isNotEmpty) item.code!,
      if (item.category != null && item.category!.isNotEmpty) item.category!,
    ].join(' · ');

    return ListTile(
      onTap: () => context.push('/items/${item.id}'),
      title: Text(
        item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall,
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(Money.formatCompact(item.salePrice), style: theme.textTheme.money),
          const SizedBox(height: 4),
          StockChip(
            qty: item.stockQty,
            unit: item.unit,
            status: status,
          ),
        ],
      ),
    );
  }
}

class StockChip extends StatelessWidget {
  const StockChip({
    super.key,
    required this.qty,
    required this.unit,
    required this.status,
  });

  final int qty;
  final String unit;
  final StockStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (Color color, String text) = switch (status) {
      StockStatus.out => (scheme.error, 'Out of stock'),
      StockStatus.low => (
          const Color(0xFFB4690E),
          'Only ${Qty.formatWithUnit(qty, unit)} left',
        ),
      StockStatus.healthy ||
      StockStatus.untracked =>
        (scheme.onSurfaceVariant, Qty.formatWithUnit(qty, unit)),
    };

    return Text(
      text,
      style: theme.textTheme.figure.copyWith(color: color, fontSize: 12.5),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              body,
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
}
