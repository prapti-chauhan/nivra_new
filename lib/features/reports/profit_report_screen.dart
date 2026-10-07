import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../core/theme.dart';
import '../../domain/reports.dart';
import 'reports_screen.dart';

const _amber = Color(0xFFB4690E);

/// Sales minus what the goods cost, then the bills that add up to it, then the
/// lines inside each bill. Three taps from the headline figure to the single
/// line it came from: every number can be opened and checked with a calculator.
class ProfitReportScreen extends ConsumerWidget {
  const ProfitReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final period = ref.watch(reportPeriodProvider);
    final bills = ref.watch(billProfitsProvider).value ?? const [];
    final summary = ref.watch(profitSummaryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Profit')),
      body: Column(
        children: [
          const PeriodBar(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              children: [
                _SumRow('Sales', summary.salesPaise),
                _SumRow('Cost of what you sold', -summary.costPaise),
                const Divider(height: 20),
                _SumRow('Profit', summary.profitPaise, strong: true),
                if (summary.marginPercent != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${summary.marginPercent}% of sales',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (summary.hasUnknownCost) ...[
                  const SizedBox(height: 10),
                  _UnknownCostNote(summary: summary),
                ],
                const SizedBox(height: 6),
                Text(
                  'Cost is what you last paid for each item when it was sold. '
                  'Expenses are not taken off here — this is profit on goods '
                  'only. See Profit and loss for what is left after them.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: bills.isEmpty
                ? Center(
                    child: Text(
                      'No bills ${period.label.toLowerCase()}.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: bills.length,
                    itemBuilder: (context, i) => _BillProfitTile(bill: bills[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SumRow extends StatelessWidget {
  const _SumRow(this.label, this.paise, {this.strong = false});

  final String label;
  final int paise;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            // A cost reads as a subtraction so the column adds up to the line
            // under it without any mental sign-flipping.
            paise < 0 ? '- ${Money.format(-paise)}' : Money.format(paise),
            style: strong ? theme.textTheme.moneyLarge : theme.textTheme.money,
          ),
        ],
      ),
    );
  }
}

class _UnknownCostNote extends StatelessWidget {
  const _UnknownCostNote({required this.summary});

  final ProfitSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = summary.unknownCostLines;
    final bills = summary.unknownCostBills;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: _amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$lines ${lines == 1 ? 'line' : 'lines'} in '
              '$bills ${bills == 1 ? 'bill' : 'bills'} '
              '${lines == 1 ? 'has' : 'have'} no cost on record. They count '
              'as pure profit, so the figure above is more than you really '
              'made. Marked below.',
              style: theme.textTheme.bodySmall?.copyWith(color: _amber),
            ),
          ),
        ],
      ),
    );
  }
}

class _BillProfitTile extends StatelessWidget {
  const _BillProfitTile({required this.bill});

  final BillProfit bill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unknown = bill.unknownCostLines > 0;
    return Theme(
      // The default expansion tile draws its own divider lines.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        title: Row(
          children: [
            Expanded(child: Text(bill.label)),
            if (unknown)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(Icons.info_outline, size: 16, color: _amber),
              ),
            Text(
              Money.format(bill.profitPaise),
              style: theme.textTheme.money.copyWith(
                color: bill.profitPaise < 0 ? theme.colorScheme.error : null,
              ),
            ),
          ],
        ),
        subtitle: Text(billSubtitle(bill)),
        children: [
          for (final line in bill.lines) _LineRow(line: line),
          if (bill.lines.isEmpty)
            Text(
              'The lines for this bill have not reached this phone yet.',
              style: theme.textTheme.bodySmall?.copyWith(color: _amber),
            ),
          const SizedBox(height: 4),
          _DetailRow(
            'Bill total',
            Money.format(bill.totalPaise),
            note: bill.totalPaise !=
                    bill.lines.fold<int>(0, (s, l) => s + l.lineTotalPaise)
                ? 'after discount'
                : null,
          ),
          _DetailRow('Cost', '- ${Money.format(bill.costPaise)}'),
          _DetailRow('Profit', Money.format(bill.profitPaise), strong: true),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => context.push('/bills/${bill.billId}'),
              child: const Text('Open bill'),
            ),
          ),
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line});

  final ProfitLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(line.name)),
              Text(Money.format(line.lineTotalPaise), style: theme.textTheme.figure),
            ],
          ),
          const SizedBox(height: 1),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${Qty.formatWithUnit(line.qtyThousandths, line.unit)}'
                  ' at ${Money.format(line.unitPricePaise)}'
                  ' · cost ${line.costUnknown ? 'not recorded' : Money.format(line.unitCostPaise)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: line.costUnknown
                        ? _amber
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (line.costUnknown)
                const Icon(Icons.info_outline, size: 14, color: _amber),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value, {this.note, this.strong = false});

  final String label;
  final String value;
  final String? note;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              note == null ? label : '$label ($note)',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: strong ? FontWeight.w700 : null,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.figure.copyWith(
              fontWeight: strong ? FontWeight.w700 : null,
            ),
          ),
        ],
      ),
    );
  }
}
