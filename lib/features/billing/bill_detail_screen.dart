import 'dart:convert';

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
import '../../domain/billing.dart';
import 'bills_screen.dart' show PaymentBadge;

class BillDetailScreen extends ConsumerWidget {
  const BillDetailScreen({super.key, required this.billId});

  final String billId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Keep the session provider alive so the id is present when a write
    // happens; an unlistened StreamProvider is still loading on first read.
    ref.watch(currentUserProvider);
    final bill = ref.watch(billProvider(billId)).value;
    final lines = ref.watch(billLinesProvider(billId)).value ?? const [];
    final revisions = ref.watch(billRevisionsProvider(billId)).value ?? const [];
    final payments = ref.watch(billPaymentsProvider(billId)).value ?? const [];

    if (bill == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final status =
        paymentStatusFor(totalPaise: bill.total, paidPaise: bill.amountPaid);
    final due = bill.total - bill.amountPaid;
    final when = DateTime.fromMillisecondsSinceEpoch(bill.occurredAt).toLocal();

    return Scaffold(
      appBar: AppBar(
        title: Text(invoiceLabel(prefix: bill.numberPrefix, number: bill.number)),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => context.push('/bills/$billId/edit'),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context, ref, bill),
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
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              bill.customerName ?? 'Cash sale',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              DateFormat('d MMM yyyy, h:mm a').format(when),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PaymentBadge(status: status, due: due),
                    ],
                  ),
                  const Divider(height: 28),
                  ...lines.map(
                    (line) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(line.name, style: theme.textTheme.bodyLarge),
                                Text(
                                  '${Qty.format(line.qty)} ${line.unit}'
                                  ' × ${Money.formatCompact(line.unitPrice)}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            Money.formatPlain(line.lineTotal),
                            style: theme.textTheme.figure,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 24),
                  _Total(label: 'Subtotal', value: bill.subtotal),
                  if (bill.discountAmount > 0)
                    _Total(label: 'Discount', value: -bill.discountAmount),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Total', style: theme.textTheme.titleSmall),
                      Text(Money.format(bill.total),
                          style: theme.textTheme.moneyLarge),
                    ],
                  ),
                  if (bill.amountPaid > 0) ...[
                    const SizedBox(height: 8),
                    _Total(label: 'Paid', value: bill.amountPaid),
                  ],
                  if (due > 0) ...[
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Still due',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFFB4690E),
                          ),
                        ),
                        Text(
                          Money.format(due),
                          style: theme.textTheme.money
                              .copyWith(color: const Color(0xFFB4690E)),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (due > 0) ...[
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _recordPayment(context, ref, bill, due),
              child: Text('Record payment of ${Money.formatCompact(due)}'),
            ),
          ],
          if (payments.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('Payments', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            ...payments.map(
              (p) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.south_west, size: 18),
                title: Text(Money.format(p.amount)),
                subtitle: Text(
                  '${p.method} · ${DateFormat('d MMM, h:mm a').format(DateTime.fromMillisecondsSinceEpoch(p.occurredAt).toLocal())}',
                ),
              ),
            ),
          ],
          if (revisions.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('Earlier versions', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'This bill has been edited ${revisions.length} '
              'time${revisions.length == 1 ? '' : 's'}. Nothing was erased.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            ...revisions.map((r) => _RevisionTile(revision: r)),
          ],
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Bill bill) async {
    final userId = ref.read(currentUserProvider).value?.id;
    if (userId == null) return;
    final dao = ref.read(billingDaoProvider);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    await dao.deleteBill(userId: userId, billId: bill.id);
    router.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Bill ${invoiceLabel(prefix: bill.numberPrefix, number: bill.number)}'
          ' removed. Stock is back.',
        ),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => dao.restoreBill(userId: userId, billId: bill.id),
        ),
      ),
    );
  }

  Future<void> _recordPayment(
    BuildContext context,
    WidgetRef ref,
    Bill bill,
    int due,
  ) async {
    final controller =
        TextEditingController(text: Money.formatPlain(due));
    final amount = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Record payment'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: const InputDecoration(
            labelText: 'Amount received',
            prefixText: '₹ ',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, Money.tryParse(controller.text)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    final userId = ref.read(currentUserProvider).value?.id;
    if (amount == null || amount <= 0 || userId == null) return;

    await ref.read(billingDaoProvider).recordPayment(
          userId: userId,
          billId: bill.id,
          customerId: bill.customerId,
          amount: amount,
        );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(Money.formatPlain(value), style: theme.textTheme.figure),
        ],
      ),
    );
  }
}

class _RevisionTile extends StatelessWidget {
  const _RevisionTile({required this.revision});

  final BillRevision revision;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = jsonDecode(revision.snapshot) as Map<String, dynamic>;
    final lines = (data['lines'] as List).cast<Map<String, dynamic>>();
    final when =
        DateTime.fromMillisecondsSinceEpoch(revision.replacedAt).toLocal();

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: 8, bottom: 12),
      title: Text(
        'Version ${revision.revision + 1} · '
        '${Money.formatCompact((data['total'] as num).toInt())}',
        style: theme.textTheme.bodyLarge,
      ),
      subtitle: Text(
        'Replaced ${DateFormat('d MMM yyyy, h:mm a').format(when)}',
        style: theme.textTheme.bodySmall,
      ),
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${line['name']} × '
                    '${Qty.format((line['qty'] as num).toInt())}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Text(
                  Money.formatPlain((line['line_total'] as num).toInt()),
                  style: theme.textTheme.figure,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
