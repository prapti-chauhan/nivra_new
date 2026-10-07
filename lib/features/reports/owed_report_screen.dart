import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../core/theme.dart';
import '../../domain/billing.dart';

/// Both directions of money, because they are one question: where do I stand.
/// Kept as two separate lists and two separate totals — never netted — so
/// "he owes me 4,000" and "I owe him 9,000" stay two facts.
class OwedReportScreen extends ConsumerWidget {
  const OwedReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final customers = ref.watch(owedToYouProvider).value ?? const [];
    final suppliers = ref.watch(youOweProvider).value ?? const [];

    final owedTotal = customers.fold<int>(0, (s, c) => s + c.balance);
    final payableTotal =
        suppliers.fold<int>(0, (s, x) => s + payableFromBalance(x.balance));

    return Scaffold(
      appBar: AppBar(title: const Text('Who owes what')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Header('Owed to you', owedTotal),
          if (customers.isEmpty)
            const _Empty('Nobody owes you anything.')
          else
            for (final c in customers)
              ListTile(
                title: Text(c.name),
                subtitle: c.phone == null ? null : Text(c.phone!),
                trailing: Text(
                  Money.format(c.balance),
                  style: theme.textTheme.money,
                ),
                onTap: () => context.push('/customers/${c.id}'),
              ),
          const SizedBox(height: 16),
          _Header('You owe', payableTotal),
          if (suppliers.isEmpty)
            const _Empty('You do not owe any supplier.')
          else
            for (final s in suppliers)
              ListTile(
                title: Text(s.name),
                subtitle: s.phone == null ? null : Text(s.phone!),
                trailing: Text(
                  Money.format(payableFromBalance(s.balance)),
                  style: theme.textTheme.money,
                ),
                onTap: () => context.push('/suppliers/${s.id}'),
              ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.label, this.paise);

  final String label;
  final int paise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: theme.textTheme.titleSmall),
          ),
          Text(Money.format(paise), style: theme.textTheme.moneyLarge),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}
