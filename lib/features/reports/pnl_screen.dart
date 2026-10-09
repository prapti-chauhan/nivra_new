import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../data/db/database.dart';
import '../../domain/cashbook.dart';
import 'reports_screen.dart';

/// What he made, laid out the way a shopkeeper adds it up: what came in from
/// selling, less what the goods cost, plus any other money, less what it cost to
/// keep the shop open.
///
/// Every line opens. Profit on goods opens into the bills; expenses open into
/// the categories and then the individual entries.
class PnlScreen extends ConsumerWidget {
  const PnlScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final period = ref.watch(reportPeriodProvider);
    final pnl = ref.watch(profitAndLossProvider);
    final goods = ref.watch(profitSummaryProvider);
    final entries = ref.watch(moneyEntriesProvider).value ?? const <MoneyEntry>[];

    final expenses = entries.where((e) => e.kind == MoneyKind.expense.wire).toList();
    final income = entries.where((e) => e.kind == MoneyKind.income.wire).toList();
    final byCategory = totalsByCategory([
      for (final e in expenses) (category: e.category, amountPaise: e.amount),
    ]);

    final net = pnl.netProfitPaise;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profit and loss'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add an expense',
            onPressed: () => context.push('/reports/money/new/expense'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const PeriodBar(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              children: [
                _Line('Sales', pnl.salesPaise,
                    onTap: () => context.push('/reports/sales')),
                _Line('Cost of what you sold', -pnl.costOfGoodsPaise),
                const Divider(height: 16),
                _Line('Profit on goods', pnl.profitOnGoodsPaise,
                    emphasise: true,
                    onTap: () => context.push('/reports/profit')),
                _Line('Other money in', pnl.otherIncomePaise),
                _Line('Expenses', -pnl.expensesPaise),
                const Divider(height: 16),
                _Line('Profit', net,
                    big: true, negativeIsError: true),
                if (goods.hasUnknownCost)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline,
                            size: 16, color: Color(0xFFB4690E)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${goods.unknownCostLines} '
                            '${goods.unknownCostLines == 1 ? 'line has' : 'lines have'}'
                            ' no cost on record, so profit is more than you '
                            'really made.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: const Color(0xFFB4690E),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Stock you bought is not an expense. It counts when you '
                    'sell it, as the cost of what you sold. Moving money '
                    'between cash and bank is not counted either.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _Heading('Where the money went (${period.inSentence})'),
          if (byCategory.isEmpty)
            _Empty(
              'No expenses ${period.inSentence}.',
              action: TextButton(
                onPressed: () => context.push('/reports/money/new/expense'),
                child: const Text('Add one'),
              ),
            )
          else
            for (final c in byCategory)
              ListTile(
                dense: true,
                title: Text(c.label),
                subtitle: Text('${c.count} ${c.count == 1 ? 'entry' : 'entries'}'),
                trailing: Text(Money.format(c.totalPaise),
                    style: theme.textTheme.money),
              ),
          if (expenses.isNotEmpty) ...[
            _Heading('Expenses'),
            for (final e in expenses) _EntryTile(entry: e),
          ],
          if (income.isNotEmpty) ...[
            _Heading('Other money in'),
            for (final e in income) _EntryTile(entry: e),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(
    this.label,
    this.paise, {
    this.onTap,
    this.emphasise = false,
    this.big = false,
    this.negativeIsError = false,
  });

  final String label;
  final int paise;
  final VoidCallback? onTap;
  final bool emphasise;
  final bool big;
  final bool negativeIsError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final negative = paise < 0;
    final text = negative ? '- ${Money.format(-paise)}' : Money.format(paise);
    final style = (big ? theme.textTheme.moneyLarge : theme.textTheme.money)
        .copyWith(
      fontWeight: (emphasise || big) ? FontWeight.w700 : null,
      color: (negativeIsError && negative) ? theme.colorScheme.error : null,
    );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: (big ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium)
                    ?.copyWith(fontWeight: (emphasise || big) ? FontWeight.w700 : null),
              ),
            ),
            Text(text, style: style),
            SizedBox(
              width: 24,
              child: onTap == null
                  ? null
                  : Icon(Icons.chevron_right,
                      size: 18, color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text, {this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final MoneyEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final method = MoneyMethod.fromWire(entry.method);
    return ListTile(
      dense: true,
      title: Text(categoryLabel(entry.category)),
      subtitle: Text(
        [
          DateFormat('d MMM').format(
            DateTime.fromMillisecondsSinceEpoch(entry.occurredAt),
          ),
          method.label,
          if (entry.note != null) entry.note!,
        ].join('  ·  '),
      ),
      trailing: Text(Money.format(entry.amount), style: theme.textTheme.money),
      onTap: () => context.push('/reports/money/entry/${entry.id}'),
    );
  }
}
