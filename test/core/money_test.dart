import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/money.dart';

void main() {
  group('Money.format', () {
    test('uses Indian digit grouping', () {
      expect(Money.formatPlain(125050), '1,250.50');
      expect(Money.formatPlain(100), '1.00');
      expect(Money.formatPlain(0), '0.00');
      expect(Money.formatPlain(5), '0.05');
      expect(Money.formatPlain(123456789), '12,34,567.89');
      expect(Money.formatPlain(1000000000), '1,00,00,000.00');
    });

    test('keeps the sign outside the symbol', () {
      expect(Money.format(-125050), '-₹1,250.50');
      expect(Money.formatPlain(-100), '-1.00');
    });

    test('compact form drops empty paise', () {
      expect(Money.formatCompact(125000), '₹1,250');
      expect(Money.formatCompact(125050), '₹1,250.50');
      expect(Money.formatCompact(-50000), '-₹500');
    });
  });

  group('Money.tryParse', () {
    test('accepts what a shopkeeper types', () {
      expect(Money.tryParse('1250'), 125000);
      expect(Money.tryParse('1250.5'), 125050);
      expect(Money.tryParse('1250.50'), 125050);
      expect(Money.tryParse('1,250.50'), 125050);
      expect(Money.tryParse('₹ 1250'), 125000);
      expect(Money.tryParse('Rs 1250.05'), 125005);
      expect(Money.tryParse('.5'), 50);
      expect(Money.tryParse('0'), 0);
      expect(Money.tryParse('-250'), -25000);
    });

    test('rejects nonsense instead of guessing', () {
      expect(Money.tryParse(''), isNull);
      expect(Money.tryParse('abc'), isNull);
      expect(Money.tryParse('1.2.3'), isNull);
      expect(Money.tryParse('-'), isNull);
      expect(Money.tryParse('.'), isNull);
      expect(Money.tryParse('12-5'), isNull);
    });

    test('refuses precision it cannot store rather than rounding silently', () {
      expect(Money.tryParse('10.555'), isNull);
    });

    test('round-trips through format', () {
      for (final paise in [0, 5, 99, 100, 125050, 123456789, -4200]) {
        expect(Money.tryParse(Money.formatPlain(paise)), paise,
            reason: 'failed for $paise');
      }
    });
  });
}
