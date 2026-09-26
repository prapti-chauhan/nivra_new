import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../domain/stock.dart';
import 'items_screen.dart' show StockChip;

/// The stock figure and everything behind it.
///
/// "No number is a mystery" is the point of this screen: the number at the top
/// is not stored anywhere authoritative — it is the sum of the rows underneath
/// it, and every row names the document that caused it.
class ItemDetailScreen extends ConsumerWidget {
  const ItemDetailScreen({super.key, required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Keep the session provider alive so the id is present when a write
    // happens; an unlistened StreamProvider is still loading on first read.
    ref.watch(currentUserProvider);
    final item = ref.watch(itemProvider(itemId)).value;
    final movements = ref.watch(itemMovementsProvider(itemId)).value ?? const [];

    if (item == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final status = stockStatusFor(
      qtyThousandths: item.stockQty,
      thresholdThousandths: item.lowStockThreshold,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(item.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => context.push('/items/$itemId/edit'),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context, ref, item),
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
                    'In stock',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        Qty.format(item.stockQty),
                        style: theme.textTheme.moneyLarge,
                      ),
                      const SizedBox(width: 6),
                      Text(item.unit, style: theme.textTheme.titleMedium),
                      const Spacer(),
                      // Only when there is something to say. The quantity is
                      // already the biggest thing on the screen, so repeating
                      // it here would be noise.
                      if (status == StockStatus.out || status == StockStatus.low)
                        StockChip(
                          qty: item.stockQty,
                          unit: item.unit,
                          status: status,
                        ),
                    ],
                  ),
                  const Divider(height: 28),
                  _Field(
                    label: 'Selling price',
                    value: Money.format(item.salePrice),
                  ),
                  _Field(
                    label: 'Cost price',
                    value: Money.format(item.purchasePrice),
                  ),
                  if (item.code != null && item.code!.isNotEmpty)
                    _Field(label: 'Code', value: item.code!),
                  if (item.category != null && item.category!.isNotEmpty)
                    _Field(label: 'Category', value: item.category!),
                  _Field(
                    label: 'Warn at',
                    value: item.lowStockThreshold == null
                        ? 'Not set'
                        : Qty.formatWithUnit(
                            item.lowStockThreshold!, item.unit),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () => _correctStock(context, ref, item),
            child: const Text('Correct stock count'),
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Every change', style: theme.textTheme.titleSmall),
              Text(
                '${movements.length} entr${movements.length == 1 ? 'y' : 'ies'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'The number above is the total of these.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          if (movements.isEmpty)
            Text(
              'No stock has moved yet.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            ...movements.map(
              (movement) => _MovementRow(movement: movement, unit: item.unit),
            ),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Item item) async {
    final dao = ref.read(inventoryDaoProvider);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    // No confirmation dialog. The delete is reversible and the undo is right
    // there, which is cheaper for someone billing fast than a modal every time.
    await dao.setItemDeleted(item.id, deleted: true);
    router.pop();

    messenger.showSnackBar(
      SnackBar(
        content: Text('${item.name} removed'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => dao.setItemDeleted(item.id, deleted: false),
        ),
      ),
    );
  }

  Future<void> _correctStock(
    BuildContext context,
    WidgetRef ref,
    Item item,
  ) async {
    final controller =
        TextEditingController(text: Qty.format(item.stockQty));
    final noteController = TextEditingController();

    final actual = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return Padding(
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
              Text('Correct stock count', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Count what is on the shelf and put that number here. The '
                'difference is recorded, not hidden.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  labelText: 'Actual count',
                  suffixText: item.unit,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteController,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Reason',
                  hintText: 'Optional — damaged, miscounted, returned',
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () {
                  final parsed = Qty.tryParse(controller.text);
                  if (parsed != null) Navigator.pop(sheetContext, parsed);
                },
                child: const Text('Save correction'),
              ),
            ],
          ),
        );
      },
    );

    final note = noteController.text.trim();
    controller.dispose();
    noteController.dispose();

    if (actual == null || actual == item.stockQty) return;

    final userId = ref.read(currentUserProvider).value?.id;
    if (userId == null) return;

    await ref.read(inventoryDaoProvider).applyMovement(
          userId: userId,
          itemId: item.id,
          qtyDelta: actual - item.stockQty,
          reason: MovementReason.adjustment,
          unitCost: item.purchasePrice,
          source: MovementSource.adjustment,
          note: note.isEmpty ? null : note,
        );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(value, style: theme.textTheme.figure),
        ],
      ),
    );
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow({required this.movement, required this.unit});

  final StockMovement movement;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final incoming = movement.qtyDelta >= 0;
    final reason = MovementReason.fromWire(movement.reason);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            incoming ? Icons.south_west : Icons.north_east,
            size: 18,
            color: incoming
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_label(reason), style: theme.textTheme.bodyLarge),
                const SizedBox(height: 2),
                Text(
                  [
                    DateFormat('d MMM yyyy, h:mm a').format(
                      DateTime.fromMillisecondsSinceEpoch(movement.occurredAt)
                          .toLocal(),
                    ),
                    if (movement.note != null && movement.note!.isNotEmpty)
                      movement.note!,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${incoming ? '+' : ''}${Qty.format(movement.qtyDelta)} $unit',
            style: theme.textTheme.figure.copyWith(
              fontWeight: FontWeight.w600,
              color: incoming
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  String _label(MovementReason reason) => switch (reason) {
        MovementReason.opening => 'Opening stock',
        MovementReason.purchase => 'Bought',
        MovementReason.sale => 'Sold',
        MovementReason.adjustment => 'Corrected by hand',
        MovementReason.reversal => 'Reversed',
      };
}
