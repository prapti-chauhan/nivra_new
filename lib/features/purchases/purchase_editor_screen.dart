import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../data/db/database.dart';
import '../../domain/billing.dart';

/// Recording what arrived from a supplier.
///
/// Deliberately not built like the bill editor. Billing is done with a
/// customer waiting and is optimised for speed; a purchase is entered later,
/// off the supplier's printed invoice, and is optimised for getting the
/// figures right — so quantity and cost are always visible and never assumed.
///
/// With a [purchaseId] it edits that purchase instead: the same form, filled
/// in, saved as a revision that keeps the version it replaces.
class PurchaseEditorScreen extends ConsumerStatefulWidget {
  const PurchaseEditorScreen({super.key, this.supplierId, this.purchaseId});

  final String? supplierId;
  final String? purchaseId;

  @override
  ConsumerState<PurchaseEditorScreen> createState() =>
      _PurchaseEditorScreenState();
}

class _PurchaseEditorScreenState extends ConsumerState<PurchaseEditorScreen> {
  final _lines = <_Line>[];
  final _search = TextEditingController();
  final _billNo = TextEditingController();
  final _paid = TextEditingController();

  Supplier? _supplier;
  bool _supplierPreloaded = false;
  bool _saving = false;

  Purchase? _editing;
  bool _loaded = false;

  bool get _isEdit => widget.purchaseId != null;

  /// Money has already gone out against this purchase, so it stays with the
  /// supplier it was paid to.
  bool get _supplierLocked => _isEdit && (_editing?.amountPaid ?? 0) > 0;

  @override
  void dispose() {
    _search.dispose();
    _billNo.dispose();
    _paid.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  int get _subtotal => _lines.fold<int>(0, (sum, l) => sum + l.total);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ref.watch(currentUserProvider);

    final preset = widget.supplierId;
    if (preset != null && !_supplierPreloaded) {
      final found = ref.watch(supplierProvider(preset)).value;
      if (found != null) {
        _supplier = found;
        _supplierPreloaded = true;
      }
    }

    final editId = widget.purchaseId;
    if (editId != null && !_loaded) {
      final purchase = ref.watch(purchaseProvider(editId)).value;
      final oldLines = ref.watch(purchaseLinesProvider(editId)).value;
      final supplier = purchase == null
          ? null
          : ref.watch(supplierProvider(purchase.supplierId)).value;
      if (purchase != null && oldLines != null && supplier != null) {
        _editing = purchase;
        _supplier = supplier;
        _billNo.text = purchase.supplierBillNo ?? '';
        for (final l in oldLines) {
          _lines.add(
            _Line(
              itemId: l.itemId,
              name: l.name,
              unit: l.unit,
              qty: TextEditingController(text: Qty.format(l.qty)),
              cost: TextEditingController(
                text: Money.formatPlain(l.unitCost).replaceAll(',', ''),
              ),
            ),
          );
        }
        _loaded = true;
      }
    }

    final results = ref.watch(purchaseItemResultsProvider).value ?? const [];

    if (_isEdit && !_loaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('Edit purchase')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit purchase' : 'New purchase')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.local_shipping_outlined),
            title: Text(_supplier?.name ?? 'Choose a supplier'),
            subtitle: _supplier == null
                ? const Text('A purchase has to be owed to somebody')
                : _supplierLocked
                ? const Text(
                    'Payments have been made, so this stays with '
                    'this supplier',
                  )
                : null,
            trailing: _supplierLocked ? null : const Icon(Icons.chevron_right),
            onTap: _supplierLocked ? null : _pickSupplier,
          ),
          const Divider(),
          TextField(
            controller: _billNo,
            decoration: const InputDecoration(
              labelText: "Supplier's bill number",
              helperText: 'As printed on their invoice. Optional.',
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Add an item',
              isDense: true,
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: _clearSearch,
                    ),
            ),
            onChanged: (value) {
              ref.read(purchaseItemSearchProvider.notifier).update(value);
              setState(() {});
            },
          ),
          for (final item in results)
            ListTile(
              dense: true,
              title: Text(item.name),
              subtitle: Text(
                'in stock ${Qty.formatWithUnit(item.stockQty, item.unit)}'
                '  ·  last cost ${Money.formatCompact(item.purchasePrice)}',
              ),
              trailing: const Icon(Icons.add_circle_outline),
              onTap: () => _add(item),
            ),
          if (_lines.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(),
            for (final line in _lines) _lineEditor(line),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total', style: theme.textTheme.titleMedium),
                Text(
                  Money.format(_subtotal),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            if (!_isEdit) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _paid,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Paid now',
                  helperText: 'Leave blank if it is on credit',
                  prefixText: '₹ ',
                  isDense: true,
                ),
              ),
            ],
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: FilledButton(
          onPressed: (_supplier == null || _lines.isEmpty || _saving)
              ? null
              : _save,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: Text(
            _lines.isEmpty
                ? 'Add something first'
                : _isEdit
                ? 'Save changes'
                : 'Save purchase',
          ),
        ),
      ),
    );
  }

  Widget _lineEditor(_Line line) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(
                  Money.format(line.total),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: line.qty,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textAlign: TextAlign.end,
              decoration: InputDecoration(labelText: line.unit, isDense: true),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: TextField(
              controller: line.cost,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textAlign: TextAlign.end,
              decoration: const InputDecoration(
                labelText: 'cost',
                prefixText: '₹',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() {
              _lines.remove(line);
              line.dispose();
            }),
          ),
        ],
      ),
    );
  }

  void _clearSearch() {
    _search.clear();
    ref.read(purchaseItemSearchProvider.notifier).update('');
    setState(() {});
  }

  void _add(Item item) {
    final existing = _lines.where((l) => l.itemId == item.id).firstOrNull;
    if (existing != null) {
      existing.qty.text = Qty.format(
        (Qty.tryParse(existing.qty.text) ?? 0) + Qty.scale,
      );
    } else {
      _lines.add(
        _Line(
          itemId: item.id,
          name: item.name,
          unit: item.unit,
          // The last cost is the best guess, and it is shown rather than
          // silently applied so a price change is noticed.
          cost: TextEditingController(
            text: Money.formatPlain(item.purchasePrice),
          ),
          qty: TextEditingController(text: '1'),
        ),
      );
    }
    _clearSearch();
  }

  Future<void> _pickSupplier() async {
    final chosen = await showModalBottomSheet<Supplier>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _SupplierSheet(),
    );
    if (chosen != null) setState(() => _supplier = chosen);
  }

  Future<void> _save() async {
    final userId = ref.read(currentUserProvider).value?.id;
    final supplier = _supplier;
    if (userId == null || supplier == null) return;

    final drafts = <PurchaseLineDraft>[];
    for (final line in _lines) {
      final qty = Qty.tryParse(line.qty.text);
      final cost = Money.tryParse(line.cost.text);
      if (qty == null || qty <= 0 || cost == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Check the quantity and cost for ${line.name}.'),
          ),
        );
        return;
      }
      drafts.add(
        PurchaseLineDraft(
          itemId: line.itemId,
          name: line.name,
          unit: line.unit,
          qty: qty,
          unitCost: cost,
        ),
      );
    }

    setState(() => _saving = true);
    try {
      final dao = ref.read(purchaseDaoProvider);
      final billNo = _billNo.text.trim().isEmpty ? null : _billNo.text.trim();
      final editing = _editing;
      if (editing != null) {
        await dao.revisePurchase(
          userId: userId,
          purchaseId: editing.id,
          supplierId: supplier.id,
          supplierName: supplier.name,
          supplierBillNo: billNo,
          lines: drafts,
          discount: Discount(
            DiscountType.fromWire(editing.discountType),
            editing.discountValue,
          ),
          note: editing.note,
        );
      } else {
        await dao.savePurchase(
          userId: userId,
          supplierId: supplier.id,
          supplierName: supplier.name,
          supplierBillNo: billNo,
          lines: drafts,
          amountPaid: Money.tryParse(_paid.text) ?? 0,
        );
      }
      if (mounted) context.pop();
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _Line {
  _Line({
    required this.itemId,
    required this.name,
    required this.unit,
    required this.qty,
    required this.cost,
  });

  final String? itemId;
  final String name;
  final String unit;
  final TextEditingController qty;
  final TextEditingController cost;

  int get total => lineTotal(
    qtyThousandths: Qty.tryParse(qty.text) ?? 0,
    unitPricePaise: Money.tryParse(cost.text) ?? 0,
  );

  void dispose() {
    qty.dispose();
    cost.dispose();
  }
}

class _SupplierSheet extends ConsumerWidget {
  const _SupplierSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suppliers = ref.watch(suppliersProvider).value ?? const [];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search suppliers',
                isDense: true,
              ),
              onChanged: (value) =>
                  ref.read(supplierSearchProvider.notifier).update(value),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final supplier in suppliers)
                  ListTile(
                    title: Text(supplier.name),
                    subtitle: supplier.phone == null
                        ? null
                        : Text(supplier.phone!),
                    onTap: () => Navigator.pop(context, supplier),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
