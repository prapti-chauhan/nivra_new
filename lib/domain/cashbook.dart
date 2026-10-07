/// Expenses, other income, and the cash/bank split. Pure Dart.
///
/// Cash and bank are never stored as balances. They are the sum of their
/// ledger accounts, so every figure can be opened up into the rows that make
/// it. See docs/decisions.md D22.
library;

import 'billing.dart';

/// What a money entry is. One table holds all three because they are mirror
/// images of each other and share every field Ramesh fills in.
enum MoneyKind {
  expense('expense'),
  income('income'),
  transfer('transfer');

  const MoneyKind(this.wire);
  final String wire;

  static MoneyKind fromWire(String? value) {
    for (final k in MoneyKind.values) {
      if (k.wire == value) return k;
    }
    return MoneyKind.expense;
  }
}

/// Where the money physically is. UPI lands in the bank, so it is not a third
/// place — payments already treat it this way, and so does this.
enum MoneyMethod {
  cash('cash', 'Cash'),
  bank('bank', 'Bank / UPI');

  const MoneyMethod(this.wire, this.label);
  final String wire;
  final String label;

  LedgerAccount get account =>
      this == MoneyMethod.cash ? LedgerAccount.cash : LedgerAccount.bank;

  MoneyMethod get other =>
      this == MoneyMethod.cash ? MoneyMethod.bank : MoneyMethod.cash;

  /// Anything that is not cash is bank. 'upi' is stored on payments, and an
  /// unknown value must land somewhere the books still balance.
  static MoneyMethod fromWire(String? value) =>
      value == 'cash' ? MoneyMethod.cash : MoneyMethod.bank;
}

/// Offered until he has his own. Plain text, not a table: there is no
/// categories screen to set up before the first expense can be recorded.
const List<String> defaultExpenseCategories = [
  'Rent',
  'Salary',
  'Electricity',
  'Transport',
  'Tea & snacks',
  'Repairs',
  'Other',
];

const List<String> defaultIncomeCategories = [
  'Commission',
  'Scrap sale',
  'Interest',
  'Other',
];

/// What to offer when he starts typing a category: the ones he has used, most
/// recent first, then the defaults he has not used yet.
///
/// Recent first because a shop spends on the same few things over and over, and
/// the one he used yesterday is the one he wants today. Compared ignoring case
/// and surrounding spaces so "rent " and "Rent" are one category, and the first
/// spelling he used wins.
List<String> categorySuggestions({
  required Iterable<String> recentNewestFirst,
  required List<String> defaults,
  int limit = 12,
}) {
  final seen = <String>{};
  final out = <String>[];
  void add(String raw) {
    final name = raw.trim();
    if (name.isEmpty) return;
    if (seen.add(name.toLowerCase())) out.add(name);
  }

  recentNewestFirst.forEach(add);
  defaults.forEach(add);
  return out.length > limit ? out.sublist(0, limit) : out;
}

/// "rent", " RENT " and "Rent" are one category. Stored as typed, trimmed, so
/// he sees his own spelling; grouped case-insensitively.
String categoryKey(String? category) => (category ?? '').trim().toLowerCase();

/// A category with nothing typed still has to read as something in a list.
String categoryLabel(String? category) {
  final c = category?.trim() ?? '';
  return c.isEmpty ? 'Uncategorised' : c;
}

class CategoryTotal {
  const CategoryTotal({required this.label, required this.totalPaise, required this.count});

  final String label;
  final int totalPaise;
  final int count;
}

/// One bar of "where did the money go", biggest first. Grouped
/// case-insensitively; the label is the first spelling seen.
List<CategoryTotal> totalsByCategory(
  Iterable<({String? category, int amountPaise})> entries,
) {
  final totals = <String, int>{};
  final counts = <String, int>{};
  final labels = <String, String>{};
  for (final e in entries) {
    final key = categoryKey(e.category);
    labels.putIfAbsent(key, () => categoryLabel(e.category));
    totals[key] = (totals[key] ?? 0) + e.amountPaise;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  final list = [
    for (final key in totals.keys)
      CategoryTotal(
        label: labels[key]!,
        totalPaise: totals[key]!,
        count: counts[key]!,
      ),
  ]..sort((a, b) => b.totalPaise.compareTo(a.totalPaise));
  return list;
}

/// The whole picture for a period.
///
/// Purchases are deliberately absent. Buying stock does not make the shop poorer
/// — it turns cash into goods — and the cost shows up when the goods are sold,
/// as `costOfGoodsPaise`. Counting a purchase here as well would charge for the
/// same stock twice.
class ProfitAndLoss {
  const ProfitAndLoss({
    required this.salesPaise,
    required this.costOfGoodsPaise,
    required this.otherIncomePaise,
    required this.expensesPaise,
  });

  final int salesPaise;
  final int costOfGoodsPaise;
  final int otherIncomePaise;
  final int expensesPaise;

  int get profitOnGoodsPaise => salesPaise - costOfGoodsPaise;

  int get netProfitPaise =>
      profitOnGoodsPaise + otherIncomePaise - expensesPaise;
}

/// Cash and bank as the shop would count them.
class CashPosition {
  const CashPosition({required this.cashPaise, required this.bankPaise});

  final int cashPaise;
  final int bankPaise;

  int get totalPaise => cashPaise + bankPaise;
}

/// What to write so that [currentPaise] becomes [countedPaise]. Zero means the
/// count already matches, and nothing should be written — an adjustment of
/// nothing is noise in a history that is supposed to be honest.
int adjustmentToReach({required int currentPaise, required int countedPaise}) =>
    countedPaise - currentPaise;
