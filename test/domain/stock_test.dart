import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/domain/stock.dart';

void main() {
  group('stockFromMovements', () {
    test('is the sum of the movements', () {
      expect(stockFromMovements([]), 0);
      expect(stockFromMovements([10000, -3000, -2000]), 5000);
      expect(stockFromMovements([5000, -6000]), -1000);
    });
  });

  group('stockStatusFor', () {
    test('reports out of stock at or below zero', () {
      expect(stockStatusFor(qtyThousandths: 0, thresholdThousandths: 5000),
          StockStatus.out);
      expect(stockStatusFor(qtyThousandths: -1000, thresholdThousandths: null),
          StockStatus.out);
    });

    test('stays quiet when no threshold was set', () {
      expect(stockStatusFor(qtyThousandths: 3000, thresholdThousandths: null),
          StockStatus.untracked);
    });

    test('warns at the threshold, not below it', () {
      expect(stockStatusFor(qtyThousandths: 5000, thresholdThousandths: 5000),
          StockStatus.low);
      expect(stockStatusFor(qtyThousandths: 5001, thresholdThousandths: 5000),
          StockStatus.healthy);
    });
  });

  group('MovementReason', () {
    test('round-trips through its wire value', () {
      for (final reason in MovementReason.values) {
        expect(MovementReason.fromWire(reason.wire), reason);
      }
    });

    test('falls back rather than throwing on an unknown value from the server', () {
      expect(MovementReason.fromWire('something_new'), MovementReason.adjustment);
    });
  });
}
