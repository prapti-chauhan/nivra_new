import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/quantity.dart';

void main() {
  group('Qty.format', () {
    test('trims trailing zeros so lists stay readable', () {
      expect(Qty.format(2000), '2');
      expect(Qty.format(1500), '1.5');
      expect(Qty.format(1250), '1.25');
      expect(Qty.format(1005), '1.005');
      expect(Qty.format(0), '0');
      expect(Qty.format(-1500), '-1.5');
      expect(Qty.format(250), '0.25');
    });

    test('appends the unit', () {
      expect(Qty.formatWithUnit(1500, 'kg'), '1.5 kg');
      expect(Qty.formatWithUnit(3000, 'pcs'), '3 pcs');
    });
  });

  group('Qty.tryParse', () {
    test('accepts whole and fractional quantities', () {
      expect(Qty.tryParse('2'), 2000);
      expect(Qty.tryParse('1.5'), 1500);
      expect(Qty.tryParse('0.25'), 250);
      expect(Qty.tryParse('.5'), 500);
      expect(Qty.tryParse('1.005'), 1005);
      expect(Qty.tryParse('-3'), -3000);
    });

    test('rejects nonsense and unstorable precision', () {
      expect(Qty.tryParse(''), isNull);
      expect(Qty.tryParse('abc'), isNull);
      expect(Qty.tryParse('1.2.3'), isNull);
      expect(Qty.tryParse('0.0001'), isNull);
    });

    test('round-trips through format', () {
      for (final q in [0, 250, 1000, 1500, 1005, -3000, 123456]) {
        expect(Qty.tryParse(Qty.format(q)), q, reason: 'failed for $q');
      }
    });
  });
}
