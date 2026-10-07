import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../core/theme.dart';
import '../../domain/reports.dart';

const _amber = Color(0xFFB4690E);

/// What is on the shelf, worth what he paid for it, biggest holdings first.
class StockReportScreen extends ConsumerWidget {
  const StockReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final items = ref.watch(stockItemsProvider).value ?? const [];

    final rows = [
      for (final i in items)
        (
          item: i,
          value: stockValuePaise(
            qtyThousandths: i.stockQty,
            unitCostPaise: i.purchasePrice,
          ),
        ),
    ]..sort((a, b) => b.value.compareTo(a.value));

    final total = rows.fold<int>(0, (s, r) => s + r.value);
    final negative = items.where((i) => i.stockQty < 0).length;
    final noCost =
        items.where((i) => i.stockQty > 0 && i.purchasePrice <= 0).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Stock on hand')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${items.length} ${items.length == 1 ? 'item' : 'items'}'
                        ', at what you last paid',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Text(Money.format(total), style: theme.textTheme.moneyLarge),
                  ],
                ),
                if (noCost > 0)
                  _Note(
                    '$noCost ${noCost == 1 ? 'item has' : 'items have'} stock '
                    'but no cost recorded, so ${noCost == 1 ? 'it adds' : 'they add'} '
                    'nothing to this figure.',
                  ),
                if (negative > 0)
                  _Note(
                    '$negative ${negative == 1 ? 'item shows' : 'items show'} '
                    'less than nothing in stock — check the shelf. Counted as zero.',
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      'No items yet.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      return ListTile(
                        title: Text(r.item.name),
                        subtitle: Text(
                          '${Qty.formatWithUnit(r.item.stockQty, r.item.unit)}'
                          ' at ${Money.format(r.item.purchasePrice)}',
                        ),
                        trailing: Text(
                          Money.format(r.value),
                          style: theme.textTheme.money,
                        ),
                        onTap: () => context.push('/items/${r.item.id}'),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16, color: _amber),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: _amber),
            ),
          ),
        ],
      ),
    );
  }
}
