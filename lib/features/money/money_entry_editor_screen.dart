import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../domain/cashbook.dart';

/// One screen for an expense, a bit of money in, and a move between cash and
/// bank — and for changing any of them afterwards.
///
/// Built for the counter: the amount is focused on arrival, the categories he
/// uses most are one tap, and nothing has to be set up first. A category is
/// typed text, not a record, so the first expense can be saved in seconds.
class MoneyEntryEditorScreen extends ConsumerStatefulWidget {
  const MoneyEntryEditorScreen({super.key, this.kind, this.entryId})
      : assert(kind != null || entryId != null);

  /// Required when adding. Ignored when editing — the entry knows its own.
  final MoneyKind? kind;
  final String? entryId;

  @override
  ConsumerState<MoneyEntryEditorScreen> createState() =>
      _MoneyEntryEditorScreenState();
}

class _MoneyEntryEditorScreenState
    extends ConsumerState<MoneyEntryEditorScreen> {
  final _amount = TextEditingController();
  final _category = TextEditingController();
  final _note = TextEditingController();

  MoneyMethod _method = MoneyMethod.cash;
  late DateTime _date;
  MoneyKind? _loadedKind;
  bool _loaded = false;
  bool _saving = false;

  bool get _isNew => widget.entryId == null;
  MoneyKind get _kind => _loadedKind ?? widget.kind ?? MoneyKind.expense;

  @override
  void initState() {
    super.initState();
    _date = DateTime.fromMillisecondsSinceEpoch(
      ref.read(databaseProvider).clock.nowMillis(),
    );
  }

  @override
  void dispose() {
    _amount.dispose();
    _category.dispose();
    _note.dispose();
    super.dispose();
  }

  String get _title {
    final verb = _isNew ? 'New' : 'Edit';
    return switch (_kind) {
      MoneyKind.expense => '$verb expense',
      MoneyKind.income => _isNew ? 'Money in' : 'Edit money in',
      MoneyKind.transfer => _isNew ? 'Move money' : 'Edit move',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = widget.entryId;
    // Keep the session provider alive so the id is present when a write
    // happens; an unlistened StreamProvider is still loading on first read.
    ref.watch(currentUserProvider);

    if (id != null && !_loaded) {
      final entry = ref.watch(moneyEntryProvider(id)).value;
      if (entry != null) {
        _loadedKind = MoneyKind.fromWire(entry.kind);
        _amount.text = Money.formatPlain(entry.amount).replaceAll(',', '');
        _category.text = entry.category ?? '';
        _note.text = entry.note ?? '';
        _method = MoneyMethod.fromWire(entry.method);
        _date = DateTime.fromMillisecondsSinceEpoch(entry.occurredAt);
        _loaded = true;
      }
    }

    final recent = _kind == MoneyKind.transfer
        ? const <String>[]
        : ref.watch(recentCategoriesProvider(_kind)).value ?? const <String>[];
    final suggestions = categorySuggestions(
      recentNewestFirst: recent,
      defaults: _kind == MoneyKind.income
          ? defaultIncomeCategories
          : defaultExpenseCategories,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          if (!_isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: _delete,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          TextField(
            controller: _amount,
            autofocus: _isNew,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: theme.textTheme.headlineMedium,
            decoration: const InputDecoration(
              labelText: 'Amount',
              prefixText: '₹ ',
            ),
          ),
          const SizedBox(height: 20),
          if (_kind == MoneyKind.transfer) ...[
            Text('From', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            _methodPicker(),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.arrow_downward, size: 18),
                const SizedBox(width: 8),
                Text('to ${_method.other.label}',
                    style: theme.textTheme.bodyLarge),
              ],
            ),
          ] else ...[
            TextField(
              controller: _category,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: _kind == MoneyKind.income
                    ? 'Where from'
                    : 'What for',
                helperText: 'Pick one below, or type your own',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final c in suggestions)
                  ChoiceChip(
                    label: Text(c),
                    selected: categoryKey(_category.text) == categoryKey(c),
                    onSelected: (_) => setState(() => _category.text = c),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              _kind == MoneyKind.income ? 'Received in' : 'Paid from',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            _methodPicker(),
          ],
          const SizedBox(height: 20),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.calendar_today_outlined),
            title: Text(_dateLabel()),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickDate,
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: Text(_isNew ? 'Save' : 'Save changes'),
        ),
      ),
    );
  }

  Widget _methodPicker() => SegmentedButton<MoneyMethod>(
        showSelectedIcon: false,
        segments: [
          for (final m in MoneyMethod.values)
            ButtonSegment(value: m, label: Text(m.label)),
        ],
        selected: {_method},
        onSelectionChanged: (s) => setState(() => _method = s.first),
      );

  String _dateLabel() {
    final now = DateTime.fromMillisecondsSinceEpoch(
      ref.read(databaseProvider).clock.nowMillis(),
    );
    final sameDay = _date.year == now.year &&
        _date.month == now.month &&
        _date.day == now.day;
    return sameDay ? 'Today' : DateFormat('d MMM yyyy').format(_date);
  }

  Future<void> _pickDate() async {
    final now = DateTime.fromMillisecondsSinceEpoch(
      ref.read(databaseProvider).clock.nowMillis(),
    );
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
    );
    if (picked == null) return;
    // Keep the time of day, so two entries on one day still sort in the order
    // they were made.
    setState(() {
      _date = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _date.hour,
        _date.minute,
        _date.second,
      );
    });
  }

  Future<void> _save() async {
    final amount = Money.tryParse(_amount.text);
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an amount more than zero.')),
      );
      return;
    }
    final userId = ref.read(currentUserProvider).value?.id;
    if (userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You are signed out. Sign in to save.')),
      );
      return;
    }

    setState(() => _saving = true);
    final dao = ref.read(moneyDaoProvider);
    final when = _date.millisecondsSinceEpoch;
    final toMethod = _kind == MoneyKind.transfer ? _method.other : null;
    try {
      if (_isNew) {
        await dao.addEntry(
          userId: userId,
          kind: _kind,
          amount: amount,
          category: _category.text,
          method: _method,
          toMethod: toMethod,
          occurredAt: when,
          note: _note.text,
        );
      } else {
        await dao.updateEntry(
          userId: userId,
          id: widget.entryId!,
          amount: amount,
          category: _category.text,
          method: _method,
          toMethod: toMethod,
          occurredAt: when,
          note: _note.text,
        );
      }
      if (mounted) context.pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final userId = ref.read(currentUserProvider).value?.id;
    final id = widget.entryId;
    if (id == null) return;
    if (userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You are signed out. Sign in to save.')),
      );
      return;
    }

    final dao = ref.read(moneyDaoProvider);
    await dao.deleteEntry(userId: userId, id: id);
    if (!mounted) return;

    // No confirmation dialog, matching the rest of the app: undo is one tap
    // and is cheaper than a modal on every delete.
    final messenger = ScaffoldMessenger.of(context);
    context.pop();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Removed'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => dao.restoreEntry(userId: userId, id: id),
        ),
      ),
    );
  }
}
