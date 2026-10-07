import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../domain/cashbook.dart';

/// What is in the till and the bank, and the three things he does about it:
/// spend, take money in, move it. Each balance opens into the rows behind it.
class MoneyScreen extends ConsumerWidget {
  const MoneyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Keep the session provider alive so the id is present when a write
    // happens; an unlistened StreamProvider is still loading on first read.
    ref.watch(currentUserProvider);
    final position = ref.watch(cashPositionProvider).value ??
        const CashPosition(cashPaise: 0, bankPaise: 0);

    return Scaffold(
      appBar: AppBar(title: const Text('Cash and bank')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: _Action(
                  icon: Icons.remove_circle_outline,
                  label: 'Expense',
                  onTap: () => context.push('/reports/money/new/expense'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Action(
                  icon: Icons.add_circle_outline,
                  label: 'Money in',
                  onTap: () => context.push('/reports/money/new/income'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Action(
                  icon: Icons.swap_horiz,
                  label: 'Move',
                  onTap: () => context.push('/reports/money/new/transfer'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Balance(
            method: MoneyMethod.cash,
            paise: position.cashPaise,
            icon: Icons.payments_outlined,
          ),
          _Balance(
            method: MoneyMethod.bank,
            paise: position.bankPaise,
            icon: Icons.account_balance_outlined,
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'These are worked out from every payment, expense and move you '
              'have recorded. If the till says something different, count it '
              'and the difference is written down as a correction.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon),
          const SizedBox(height: 4),
          Text(label),
        ],
      ),
    );
  }
}

class _Balance extends ConsumerWidget {
  const _Balance({
    required this.method,
    required this.paise,
    required this.icon,
  });

  final MoneyMethod method;
  final int paise;
  final IconData icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Keep the session provider alive so the id is present when a write
    // happens; an unlistened StreamProvider is still loading on first read.
    ref.watch(currentUserProvider);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/reports/money/ledger/${method.wire}'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      method == MoneyMethod.cash ? 'Cash in hand' : 'Bank / UPI',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    Money.format(paise),
                    style: theme.textTheme.moneyLarge.copyWith(
                      color: paise < 0 ? theme.colorScheme.error : null,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right,
                      color: theme.colorScheme.onSurfaceVariant),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _count(context, ref),
                  child: Text(
                    method == MoneyMethod.cash ? 'Count the till' : 'Match the bank',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _count(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(
      text: paise > 0 ? Money.formatPlain(paise).replaceAll(',', '') : '',
    );
    final counted = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          method == MoneyMethod.cash
              ? 'How much cash is there?'
              : 'What does the bank say?',
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(prefixText: '₹ '),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, Money.tryParse(controller.text)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (counted == null || counted < 0) return;
    final userId = ref.read(currentUserProvider).value?.id;
    if (userId == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You are signed out. Sign in to save.')),
      );
      return;
    }

    final diff = await ref.read(moneyDaoProvider).correctBalance(
          userId: userId,
          method: method,
          countedPaise: counted,
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          diff == null
              ? 'That matches what the app had.'
              : 'Corrected by ${diff < 0 ? '-' : '+'}${Money.format(diff.abs())}',
        ),
      ),
    );
  }
}
