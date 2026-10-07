import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../domain/billing.dart';
import '../../domain/cashbook.dart';

/// Every row that ever moved the till or the bank, newest first. This is what
/// makes the balance on the previous screen something he can open up rather
/// than a number he has to take on trust.
class AccountLedgerScreen extends ConsumerWidget {
  const AccountLedgerScreen({super.key, required this.method});

  final MoneyMethod method;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final rows = ref.watch(cashLedgerProvider(method)).value ?? const [];
    final total = rows.fold<int>(0, (sum, e) => sum + e.amount);

    return Scaffold(
      appBar: AppBar(
        title: Text(method == MoneyMethod.cash ? 'Cash in hand' : 'Bank / UPI'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${rows.length} ${rows.length == 1 ? 'entry' : 'entries'}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Text(Money.format(total), style: theme.textTheme.moneyLarge),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      'Nothing has moved yet.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final e = rows[i];
                      final into = e.amount >= 0;
                      return ListTile(
                        title: Text(
                          ledgerReasonLabel(LedgerReason.fromWire(e.reason)),
                        ),
                        subtitle: Text(
                          [
                            DateFormat('d MMM yyyy, h:mm a').format(
                              DateTime.fromMillisecondsSinceEpoch(e.occurredAt),
                            ),
                            if (e.note != null) e.note!,
                          ].join('  ·  '),
                        ),
                        trailing: Text(
                          '${into ? '+' : '-'}${Money.format(e.amount.abs())}',
                          style: theme.textTheme.money.copyWith(
                            color: into ? null : theme.colorScheme.error,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
