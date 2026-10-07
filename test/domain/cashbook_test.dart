import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/domain/cashbook.dart';

void main() {
  group('categories offered', () {
    test('his own come first, most recent first, then the defaults', () {
      final out = categorySuggestions(
        recentNewestFirst: ['Tea & snacks', 'Rent'],
        defaults: defaultExpenseCategories,
      );
      expect(out.take(2), ['Tea & snacks', 'Rent']);
      expect(out, contains('Salary'));
    });

    test('a default he has already used is not offered twice', () {
      final out = categorySuggestions(
        recentNewestFirst: ['Rent'],
        defaults: defaultExpenseCategories,
      );
      expect(out.where((c) => c == 'Rent'), hasLength(1));
    });

    test('case and stray spaces do not make a second category', () {
      final out = categorySuggestions(
        recentNewestFirst: ['rent ', 'RENT', 'Rent'],
        defaults: const ['Rent'],
      );
      expect(out, ['rent']);
    });

    test('his spelling wins over the default', () {
      final out = categorySuggestions(
        recentNewestFirst: ['tea & snacks'],
        defaults: const ['Tea & snacks'],
      );
      expect(out, ['tea & snacks']);
    });

    test('blank entries are ignored', () {
      final out = categorySuggestions(
        recentNewestFirst: ['', '   '],
        defaults: const ['Rent'],
      );
      expect(out, ['Rent']);
    });

    test('the list is capped', () {
      final out = categorySuggestions(
        recentNewestFirst: [for (var i = 0; i < 30; i++) 'cat $i'],
        defaults: defaultExpenseCategories,
        limit: 5,
      );
      expect(out, hasLength(5));
    });
  });

  group('totals by category', () {
    test('adds up, biggest first', () {
      final out = totalsByCategory([
        (category: 'Rent', amountPaise: 800000),
        (category: 'Tea', amountPaise: 2000),
        (category: 'Tea', amountPaise: 3000),
      ]);
      expect(out.map((c) => c.label), ['Rent', 'Tea']);
      expect(out.last.totalPaise, 5000);
      expect(out.last.count, 2);
    });

    test('different spellings of one category are one row', () {
      final out = totalsByCategory([
        (category: 'Rent', amountPaise: 100),
        (category: ' rent', amountPaise: 200),
      ]);
      expect(out, hasLength(1));
      expect(out.single.totalPaise, 300);
      expect(out.single.label, 'Rent');
    });

    test('nothing typed reads as uncategorised, not as a blank row', () {
      final out = totalsByCategory([
        (category: null, amountPaise: 100),
        (category: '  ', amountPaise: 200),
      ]);
      expect(out.single.label, 'Uncategorised');
      expect(out.single.totalPaise, 300);
    });
  });

  group('profit and loss', () {
    test('net profit is goods profit plus other income less expenses', () {
      const pnl = ProfitAndLoss(
        salesPaise: 1000000,
        costOfGoodsPaise: 700000,
        otherIncomePaise: 20000,
        expensesPaise: 150000,
      );
      expect(pnl.profitOnGoodsPaise, 300000);
      expect(pnl.netProfitPaise, 170000);
    });

    test('expenses larger than profit make a loss, not a clamp to zero', () {
      const pnl = ProfitAndLoss(
        salesPaise: 100000,
        costOfGoodsPaise: 80000,
        otherIncomePaise: 0,
        expensesPaise: 50000,
      );
      expect(pnl.netProfitPaise, -30000);
    });
  });

  group('cash and bank', () {
    test('a position adds both places', () {
      const p = CashPosition(cashPaise: 12000, bankPaise: 88000);
      expect(p.totalPaise, 100000);
    });

    test('a count that matches needs no adjustment', () {
      expect(adjustmentToReach(currentPaise: 5000, countedPaise: 5000), 0);
    });

    test('a short till is a negative adjustment', () {
      expect(adjustmentToReach(currentPaise: 5000, countedPaise: 4200), -800);
    });

    test('an over till is a positive adjustment', () {
      expect(adjustmentToReach(currentPaise: 5000, countedPaise: 6000), 1000);
    });
  });

  group('methods', () {
    test('UPI and anything unknown count as bank', () {
      expect(MoneyMethod.fromWire('upi'), MoneyMethod.bank);
      expect(MoneyMethod.fromWire('bank'), MoneyMethod.bank);
      expect(MoneyMethod.fromWire(null), MoneyMethod.bank);
      expect(MoneyMethod.fromWire('cash'), MoneyMethod.cash);
    });

    test('the other side of cash is bank and back', () {
      expect(MoneyMethod.cash.other, MoneyMethod.bank);
      expect(MoneyMethod.bank.other, MoneyMethod.cash);
    });
  });
}
