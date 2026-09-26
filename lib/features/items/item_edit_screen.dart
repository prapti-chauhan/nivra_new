import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';

const List<String> kUnits = ['pcs', 'kg', 'g', 'm', 'ft', 'ltr', 'box', 'set'];

/// Create or edit an item. Opening stock is offered only on create, because
/// afterwards stock changes through movements that leave a trace.
class ItemEditScreen extends ConsumerStatefulWidget {
  const ItemEditScreen({super.key, this.itemId});

  final String? itemId;

  bool get isNew => itemId == null;

  @override
  ConsumerState<ItemEditScreen> createState() => _ItemEditScreenState();
}

class _ItemEditScreenState extends ConsumerState<ItemEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _category = TextEditingController();
  final _salePrice = TextEditingController();
  final _purchasePrice = TextEditingController();
  final _threshold = TextEditingController();
  final _openingStock = TextEditingController();

  String _unit = 'pcs';
  bool _loaded = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [
      _name,
      _code,
      _category,
      _salePrice,
      _purchasePrice,
      _threshold,
      _openingStock,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);

    final dao = ref.read(inventoryDaoProvider);
    final userId = ref.read(currentUserProvider).value?.id;
    if (userId == null) {
      setState(() => _busy = false);
      return;
    }

    final threshold = _threshold.text.trim().isEmpty
        ? null
        : Qty.tryParse(_threshold.text);

    if (widget.isNew) {
      await dao.createItem(
        userId: userId,
        name: _name.text.trim(),
        code: _blankToNull(_code.text),
        unit: _unit,
        salePrice: Money.tryParse(_salePrice.text) ?? 0,
        purchasePrice: Money.tryParse(_purchasePrice.text) ?? 0,
        lowStockThreshold: threshold,
        category: _blankToNull(_category.text),
        openingStock: Qty.tryParse(_openingStock.text) ?? 0,
      );
    } else {
      await dao.updateItem(
        id: widget.itemId!,
        name: _name.text.trim(),
        code: _code.text.trim(),
        unit: _unit,
        salePrice: Money.tryParse(_salePrice.text) ?? 0,
        purchasePrice: Money.tryParse(_purchasePrice.text) ?? 0,
        lowStockThreshold: threshold,
        clearLowStockThreshold: threshold == null,
        category: _category.text.trim(),
      );
    }

    if (mounted) context.pop();
  }

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Keep the session provider alive so the id is present when a write
    // happens; an unlistened StreamProvider is still loading on first read.
    ref.watch(currentUserProvider);

    if (!widget.isNew && !_loaded) {
      final item = ref.watch(itemProvider(widget.itemId!)).value;
      if (item != null) {
        _name.text = item.name;
        _code.text = item.code ?? '';
        _category.text = item.category ?? '';
        _salePrice.text = Money.formatPlain(item.salePrice);
        _purchasePrice.text = Money.formatPlain(item.purchasePrice);
        _threshold.text = item.lowStockThreshold == null
            ? ''
            : Qty.format(item.lowStockThreshold!);
        _unit = kUnits.contains(item.unit) ? item.unit : kUnits.first;
        _loaded = true;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'New item' : 'Edit item'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
          children: [
            TextFormField(
              controller: _name,
              autofocus: widget.isNew,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Item name'),
              validator: (value) => (value ?? '').trim().isEmpty
                  ? 'Give the item a name'
                  : null,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _code,
                    decoration: const InputDecoration(
                      labelText: 'Code',
                      hintText: 'Optional',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _unit,
                    decoration: const InputDecoration(labelText: 'Unit'),
                    items: [
                      for (final unit in kUnits)
                        DropdownMenuItem(value: unit, child: Text(unit)),
                    ],
                    onChanged: (value) =>
                        setState(() => _unit = value ?? 'pcs'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Text('Price', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _salePrice,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [_decimalFormatter],
                    decoration: const InputDecoration(
                      labelText: 'Selling price',
                      prefixText: '₹ ',
                    ),
                    validator: _priceValidator,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _purchasePrice,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [_decimalFormatter],
                    decoration: const InputDecoration(
                      labelText: 'Cost price',
                      prefixText: '₹ ',
                    ),
                    validator: _priceValidator,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Text('Stock', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            if (widget.isNew) ...[
              TextFormField(
                controller: _openingStock,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [_decimalFormatter],
                decoration: InputDecoration(
                  labelText: 'How many do you have now',
                  suffixText: _unit,
                  hintText: '0',
                ),
                validator: (value) {
                  if ((value ?? '').trim().isEmpty) return null;
                  return Qty.tryParse(value!) == null
                      ? 'Enter a number'
                      : null;
                },
              ),
              const SizedBox(height: 14),
            ],
            TextFormField(
              controller: _threshold,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [_decimalFormatter],
              decoration: InputDecoration(
                labelText: 'Warn me when stock falls to',
                suffixText: _unit,
                hintText: 'Leave blank for no warning',
              ),
              validator: (value) {
                if ((value ?? '').trim().isEmpty) return null;
                return Qty.tryParse(value!) == null ? 'Enter a number' : null;
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Only items with a number here will ever warn you. That keeps '
              'the warnings worth reading.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _category,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Category',
                hintText: 'Optional',
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(widget.isNew ? 'Add item' : 'Save changes'),
          ),
        ),
      ),
    );
  }

  static String? _priceValidator(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return null;
    return Money.tryParse(text) == null ? 'Enter an amount' : null;
  }

  static final _decimalFormatter =
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'));
}
