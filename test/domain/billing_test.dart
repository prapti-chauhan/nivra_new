import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/domain/billing.dart';

void main() {
  group('lineTotal', () {
    test('multiplies whole quantities exactly', () {
      expect(lineTotal(qtyThousandths: 3000, unitPricePaise: 1450), 4350);
      expect(lineTotal(qtyThousandths: 1000, unitPricePaise: 42000), 42000);
      expect(lineTotal(qtyThousandths: 0, unitPricePaise: 42000), 0);
    });

    test('rounds half away from zero rather than truncating', () {
      // 1.5 kg at Rs 10.33 is 15.495, which the customer pays as 15.50.
      expect(lineTotal(qtyThousandths: 1500, unitPricePaise: 1033), 1550);
      // 0.5 at 1 paisa is half a paisa and rounds up, not away.
      expect(lineTotal(qtyThousandths: 500, unitPricePaise: 1), 1);
      expect(lineTotal(qtyThousandths: 1, unitPricePaise: 1), 0);
    });

    test('handles reversals symmetrically', () {
      expect(lineTotal(qtyThousandths: -1500, unitPricePaise: 1033), -1550);
      expect(
        lineTotal(qtyThousandths: -1500, unitPricePaise: 1033),
        -lineTotal(qtyThousandths: 1500, unitPricePaise: 1033),
      );
    });

    test('a fractional quantity of a large price stays exact', () {
      // 0.25 m of Rs 1,234.56 wire = Rs 308.64
      expect(lineTotal(qtyThousandths: 250, unitPricePaise: 123456), 30864);
    });
  });

  group('Discount', () {
    test('percent uses basis points and rounds half up', () {
      expect(const Discount(DiscountType.percent, 1000).amountOff(43000), 4300);
      expect(const Discount(DiscountType.percent, 250).amountOff(43000), 1075);
      expect(const Discount(DiscountType.percent, 333).amountOff(10000), 333);
    });

    test('flat amount passes straight through', () {
      expect(const Discount(DiscountType.amount, 5000).amountOff(43000), 5000);
    });

    test('never exceeds the subtotal, so a bill cannot go negative', () {
      expect(const Discount(DiscountType.amount, 500000).amountOff(43000), 43000);
      expect(const Discount(DiscountType.percent, 20000).amountOff(43000), 43000);
    });

    test('ignores nonsense rather than inverting the bill', () {
      expect(const Discount(DiscountType.amount, -500).amountOff(43000), 0);
      expect(const Discount.none().amountOff(43000), 0);
      expect(const Discount(DiscountType.amount, 5000).amountOff(0), 0);
    });
  });

  group('totalsFor', () {
    test('sums lines and applies the discount', () {
      final totals = totalsFor(
        lineTotals: [4350, 42000, 1550],
        discount: const Discount(DiscountType.amount, 1900),
      );
      expect(totals.subtotal, 47900);
      expect(totals.discount, 1900);
      expect(totals.total, 46000);
    });

    test('an empty bill is zero, not an error', () {
      final totals = totalsFor(lineTotals: const []);
      expect(totals.subtotal, 0);
      expect(totals.total, 0);
    });
  });

  group('paymentStatusFor', () {
    test('is derived, never stored', () {
      expect(paymentStatusFor(totalPaise: 43000, paidPaise: 43000),
          PaymentStatus.paid);
      expect(paymentStatusFor(totalPaise: 43000, paidPaise: 20000),
          PaymentStatus.partial);
      expect(paymentStatusFor(totalPaise: 43000, paidPaise: 0),
          PaymentStatus.unpaid);
    });

    test('overpayment still reads as paid', () {
      expect(paymentStatusFor(totalPaise: 43000, paidPaise: 50000),
          PaymentStatus.paid);
    });

    test('a zero bill is paid by definition', () {
      expect(paymentStatusFor(totalPaise: 0, paidPaise: 0), PaymentStatus.paid);
    });
  });

  group('invoiceLabel', () {
    test('works with and without a prefix', () {
      expect(invoiceLabel(prefix: '', number: 42), '42');
      expect(invoiceLabel(prefix: 'INV-', number: 42), 'INV-42');
    });
  });

  group('wire round-trips', () {
    test('every enum survives a trip through the database', () {
      for (final v in DiscountType.values) {
        expect(DiscountType.fromWire(v.wire), v);
      }
      for (final v in LedgerAccount.values) {
        expect(LedgerAccount.fromWire(v.wire), v);
      }
      for (final v in LedgerReason.values) {
        expect(LedgerReason.fromWire(v.wire), v);
      }
    });

    test('an unknown value from the server falls back rather than throwing', () {
      expect(DiscountType.fromWire('future_type'), DiscountType.none);
      expect(LedgerReason.fromWire('future_reason'), LedgerReason.adjustment);
    });
  });
}
