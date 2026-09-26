import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../domain/billing.dart';
import '../customers/customer_picker.dart';
import 'bill_draft.dart';

/// Search first, one tap to add.
///
/// The arithmetic this layout exists to satisfy: three items, one hand,
/// fifteen seconds, which leaves under two seconds per interaction. So adding
/// an item is type-two-characters plus one tap, with no screen transition, and
/// the keyboard never leaves. The running bill lives in the bar at the bottom
/// so the total is always visible without opening anything.
class BillEditorScreen extends ConsumerStatefulWidget {
  const BillEditorScreen({super.key, this.billId});

  /// Set when revising an existing bill.
  final String? billId;

  @override
  ConsumerState<BillEditorScreen> createState() => _BillEditorScreenState();
}

class _BillEditorScreenState extends ConsumerState<BillEditorScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  bool _expanded = false;
  bool _saving = false;
  bool _loadedForEdit = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.billId == null) {
        ref.read(billDraftProvider.notifier).clear();
      }
      ref.read(billItemSearchProvider.notifier).update('');
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _add(Item item) {
    ref.read(billDraftProvider.notifier).addItem(item);
    _search.clear();
    ref.read(billItemSearchProvider.notifier).update('');
    // Keep the keyboard up: the next item is usually two characters away.
    _searchFocus.requestFocus();
  }

  Future<void> _pickCustomer() async {
    final selection = await showCustomerPicker(context);
    if (selection == null || !mounted) return;
    ref.read(billDraftProvider.notifier).setCustomer(selection.customer);
    _searchFocus.requestFocus();
  }

  Future<void> _save() async {
    final draft = ref.read(billDraftProvider);
    if (draft.isEmpty || _saving) return;

    final userId = ref.read(currentUserProvider).value?.id;
    if (userId == null) {
      // Never fail silently on a save. A button that does nothing is worse
      // than an error, because he will assume the bill is made and move on.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not signed in. Nothing was saved.')),
      );
      return;
    }

    setState(() => _saving = true);
    final dao = ref.read(billingDaoProvider);
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final lines = draft.lines.map((l) => l.toDraft()).toList();
      if (draft.isEditing) {
        await dao.reviseBill(
          userId: userId,
          billId: draft.editingBillId!,
          lines: lines,
          customerId: draft.customerId,
          customerName: draft.customerName,
          discount: draft.discount,
          note: draft.note,
        );
        ref.read(billDraftProvider.notifier).clear();
        router.pop();
        messenger.showSnackBar(
          const SnackBar(content: Text('Bill updated. The old version is kept.')),
        );
      } else {
        final billId = await dao.saveBill(
          userId: userId,
          lines: lines,
          customerId: draft.customerId,
          customerName: draft.customerName,
          discount: draft.discount,
          paid: !draft.credit,
          note: draft.note,
        );
        ref.read(billDraftProvider.notifier).clear();
        router.pushReplacement('/bills/$billId');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = ref.watch(billDraftProvider);
    final results = ref.watch(billItemResultsProvider).value ?? const <Item>[];
    // Watched, not just read on save: a StreamProvider that nothing listens to
    // is still loading when the save button is pressed, and the id would come
    // back null.
    ref.watch(currentUserProvider);

    // Loading an existing bill into the draft, once.
    if (widget.billId != null && !_loadedForEdit) {
      final bill = ref.watch(billProvider(widget.billId!)).value;
      final lines = ref.watch(billLinesProvider(widget.billId!)).value;
      if (bill != null && lines != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _loadedForEdit) return;
          ref
              .read(billDraftProvider.notifier)
              .loadForEdit(bill: bill, lines: lines);
          setState(() => _loadedForEdit = true);
        });
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(draft.isEditing ? 'Edit bill' : 'New bill'),
        actions: [
          if (!draft.isEmpty)
            TextButton(
              onPressed: () => _showDiscountSheet(context, draft),
              child: Text(
                draft.discount.type == DiscountType.none
                    ? 'Discount'
                    : '- ${Money.formatCompact(draft.totals.discount)}',
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          _CustomerBar(
            name: draft.customerName,
            onTap: _pickCustomer,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: TextField(
              key: const Key('bill-item-search'),
              controller: _search,
              focusNode: _searchFocus,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: (value) =>
                  ref.read(billItemSearchProvider.notifier).update(value),
              decoration: InputDecoration(
                hintText: 'Type to find an item',
                prefixIcon: const Icon(Icons.search, size: 22),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () {
                          _search.clear();
                          ref
                              .read(billItemSearchProvider.notifier)
                              .update('');
                          setState(() {});
                        },
                      ),
              ),
            ),
          ),
          Expanded(
            child: results.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: Text(
                        'No item matches that.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = results[index];
                      final onBill = draft.lines
                          .where((l) => l.itemId == item.id)
                          .firstOrNull;
                      return _ResultRow(
                        item: item,
                        qtyOnBill: onBill?.qty,
                        onTap: () => _add(item),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _BottomBar(
        draft: draft,
        expanded: _expanded,
        saving: _saving,
        onToggleExpand: () => setState(() => _expanded = !_expanded),
        onSave: _save,
        onPickCustomer: _pickCustomer,
      ),
    );
  }

  Future<void> _showDiscountSheet(BuildContext context, BillDraft draft) async {
    final controller = TextEditingController(
      text: draft.discount.type == DiscountType.amount
          ? Money.formatPlain(draft.discount.value)
          : draft.discount.type == DiscountType.percent
              ? (draft.discount.value / 100).toString()
              : '',
    );
    var isPercent = draft.discount.type == DiscountType.percent;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
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
              Text('Discount', style: Theme.of(sheetContext).textTheme.titleMedium),
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('₹ off')),
                  ButtonSegment(value: true, label: Text('% off')),
                ],
                selected: {isPercent},
                onSelectionChanged: (s) =>
                    setSheetState(() => isPercent = s.first),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  labelText: isPercent ? 'Percent' : 'Amount',
                  prefixText: isPercent ? null : '₹ ',
                  suffixText: isPercent ? '%' : null,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        ref
                            .read(billDraftProvider.notifier)
                            .setDiscount(const Discount.none());
                        Navigator.pop(sheetContext);
                      },
                      child: const Text('Remove'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        final text = controller.text.trim();
                        final discount = isPercent
                            ? Discount(
                                DiscountType.percent,
                                ((double.tryParse(text) ?? 0) * 100).round(),
                              )
                            : Discount(
                                DiscountType.amount,
                                Money.tryParse(text) ?? 0,
                              );
                        ref
                            .read(billDraftProvider.notifier)
                            .setDiscount(discount);
                        Navigator.pop(sheetContext);
                      },
                      child: const Text('Apply'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    controller.dispose();
    if (mounted) _searchFocus.requestFocus();
  }
}

class _CustomerBar extends StatelessWidget {
  const _CustomerBar({required this.name, required this.onTap});

  final String? name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCash = name == null;

    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            Icon(
              isCash ? Icons.payments_outlined : Icons.person_outline,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isCash ? 'Cash sale' : name!,
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              'Change',
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.item,
    required this.qtyOnBill,
    required this.onTap,
  });

  final Item item;
  final int? qtyOnBill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      key: Key('bill-result-${item.id}'),
      onTap: onTap,
      title: Text(
        item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Text(
        [
          if ((item.code ?? '').isNotEmpty) item.code!,
          Qty.formatWithUnit(item.stockQty, item.unit),
        ].join(' · '),
        maxLines: 1,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (qtyOnBill != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                Qty.format(qtyOnBill!),
                style: theme.textTheme.figure.copyWith(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Text(Money.formatCompact(item.salePrice), style: theme.textTheme.money),
        ],
      ),
    );
  }
}

class _BottomBar extends ConsumerWidget {
  const _BottomBar({
    required this.draft,
    required this.expanded,
    required this.saving,
    required this.onToggleExpand,
    required this.onSave,
    required this.onPickCustomer,
  });

  final BillDraft draft;
  final bool expanded;
  final bool saving;
  final VoidCallback onToggleExpand;
  final VoidCallback onSave;
  final VoidCallback onPickCustomer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final totals = draft.totals;

    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (expanded && !draft.isEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.4,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(top: 4),
                  itemCount: draft.lines.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => _LineRow(
                    line: draft.lines[index],
                    index: index,
                  ),
                ),
              ),
            if (expanded && !draft.isEmpty) const Divider(height: 1),
            InkWell(
              onTap: draft.isEmpty ? null : onToggleExpand,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Row(
                  children: [
                    Icon(
                      expanded ? Icons.expand_more : Icons.expand_less,
                      size: 20,
                      color: draft.isEmpty
                          ? theme.colorScheme.outlineVariant
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      draft.isEmpty
                          ? 'No items yet'
                          : '${draft.itemCount} item${draft.itemCount == 1 ? '' : 's'}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    if (totals.discount > 0) ...[
                      Text(
                        Money.formatCompact(totals.subtotal),
                        style: theme.textTheme.figure.copyWith(
                          decoration: TextDecoration.lineThrough,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      Money.format(totals.total),
                      key: const Key('bill-total'),
                      style: theme.textTheme.moneyLarge,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  _CreditToggle(
                    credit: draft.credit,
                    onChanged: (wantsCredit) {
                      final ok = ref
                          .read(billDraftProvider.notifier)
                          .setCredit(wantsCredit);
                      if (!ok) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text(
                              'Credit needs a customer. Who owes you?',
                            ),
                            action: SnackBarAction(
                              label: 'Choose',
                              onPressed: onPickCustomer,
                            ),
                          ),
                        );
                      }
                    },
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const Key('bill-save'),
                      onPressed: draft.isEmpty || saving ? null : onSave,
                      child: saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              draft.isEditing
                                  ? 'Save changes'
                                  : 'Save · ${Money.formatCompact(totals.total)}',
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreditToggle extends StatelessWidget {
  const _CreditToggle({required this.credit, required this.onChanged});

  final bool credit;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      key: const Key('bill-credit-toggle'),
      onTap: () => onChanged(!credit),
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: credit
              ? theme.colorScheme.secondaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: credit
                ? theme.colorScheme.secondary
                : theme.colorScheme.outlineVariant,
            width: credit ? 1.6 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              credit ? Icons.schedule : Icons.check_circle_outline,
              size: 18,
              color: credit
                  ? theme.colorScheme.onSecondaryContainer
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 7),
            Text(
              credit ? 'Credit' : 'Paid',
              style: theme.textTheme.labelLarge?.copyWith(
                color: credit
                    ? theme.colorScheme.onSecondaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineRow extends ConsumerWidget {
  const _LineRow({required this.line, required this.index});

  final DraftLine line;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(billDraftProvider.notifier);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge,
                ),
                Text(
                  '${Money.formatCompact(line.unitPrice)} / ${line.unit}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _StepButton(
            icon: Icons.remove,
            onTap: () => notifier.changeQty(index, line.qty - 1000),
          ),
          GestureDetector(
            onTap: () => _editQty(context, ref),
            child: Container(
              constraints: const BoxConstraints(minWidth: 46),
              padding: const EdgeInsets.symmetric(vertical: 8),
              alignment: Alignment.center,
              child: Text(
                Qty.format(line.qty),
                style: theme.textTheme.money,
              ),
            ),
          ),
          _StepButton(
            icon: Icons.add,
            onTap: () => notifier.changeQty(index, line.qty + 1000),
          ),
          SizedBox(
            width: 82,
            child: Text(
              Money.formatCompact(line.total),
              textAlign: TextAlign.right,
              style: theme.textTheme.money,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editQty(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: Qty.format(line.qty));
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(line.name),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: InputDecoration(
            labelText: 'Quantity',
            suffixText: line.unit,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              Qty.tryParse(controller.text),
            ),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null) {
      ref.read(billDraftProvider.notifier).changeQty(index, result);
    }
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Icon(icon, size: 17),
      ),
    );
  }
}
