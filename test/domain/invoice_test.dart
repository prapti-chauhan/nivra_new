import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/domain/billing.dart';
import 'package:nivra_new/domain/invoice.dart';

InvoiceDocument doc({
  String shopName = 'Sharma Hardware',
  String? customerName,
  List<InvoiceLine>? lines,
  int subtotal = 10000,
  int discount = 0,
  DiscountType discountType = DiscountType.none,
  int discountValue = 0,
  int total = 10000,
  int paid = 0,
  int revision = 0,
  String? note,
}) =>
    buildInvoice(
      shopName: shopName,
      numberLabel: 'INV-0012',
      issuedAt: DateTime(2026, 9, 26, 15, 30),
      customerName: customerName,
      lines: lines ??
          const [
            InvoiceLine(
              position: 1,
              name: '16mm hex bolt',
              qtyThousandths: 4000,
              unit: 'pcs',
              unitPricePaise: 2500,
              lineTotalPaise: 10000,
            ),
          ],
      subtotalPaise: subtotal,
      discountPaise: discount,
      discountType: discountType,
      discountValue: discountValue,
      totalPaise: total,
      paidPaise: paid,
      revision: revision,
      note: note,
    );

void main() {
  group('amount in words', () {
    test('spells whole rupees', () {
      expect(rupeesInWords(125000), 'Rupees One Thousand Two Hundred Fifty Only');
    });

    test('includes paise when there are any', () {
      expect(
        rupeesInWords(125050),
        'Rupees One Thousand Two Hundred Fifty and Fifty Paise Only',
      );
    });

    test('uses lakh and crore, not millions', () {
      expect(wholeNumberInWords(100000), 'One Lakh');
      expect(wholeNumberInWords(2500000), 'Twenty Five Lakh');
      expect(wholeNumberInWords(10000000), 'One Crore');
      expect(
        wholeNumberInWords(12345678),
        'One Crore Twenty Three Lakh Forty Five Thousand Six Hundred Seventy Eight',
      );
    });

    test('handles the teens, which are the usual off-by-one', () {
      expect(wholeNumberInWords(11), 'Eleven');
      expect(wholeNumberInWords(19), 'Nineteen');
      expect(wholeNumberInWords(20), 'Twenty');
      expect(wholeNumberInWords(115), 'One Hundred Fifteen');
    });

    test('a zero bill still reads as a sentence', () {
      expect(rupeesInWords(0), 'Rupees Zero Only');
    });

    test('a single paisa is not lost', () {
      expect(rupeesInWords(1), 'Rupees Zero and One Paise Only');
    });
  });

  group('customer', () {
    test('a walk-in reads as a cash sale, never as a blank', () {
      expect(doc(customerName: null).customerName, 'Cash sale');
      expect(doc(customerName: '   ').customerName, 'Cash sale');
    });

    test('a named customer is kept', () {
      expect(doc(customerName: 'Ramesh Kumar').customerName, 'Ramesh Kumar');
    });
  });

  group('discount', () {
    test('no discount means no row at all, not a zero', () {
      expect(doc().discountLabel, isNull);
    });

    test('a percent discount says what percent it was', () {
      final d = doc(
        discount: 250,
        discountType: DiscountType.percent,
        discountValue: 250,
        total: 9750,
      );
      expect(d.discountLabel, 'Discount (2.5%)');
    });

    test('a whole percent has no trailing decimal', () {
      final d = doc(
        discount: 1000,
        discountType: DiscountType.percent,
        discountValue: 1000,
        total: 9000,
      );
      expect(d.discountLabel, 'Discount (10%)');
    });

    test('a flat amount does not invent a percentage', () {
      final d = doc(
        discount: 500,
        discountType: DiscountType.amount,
        discountValue: 500,
        total: 9500,
      );
      expect(d.discountLabel, 'Discount');
    });
  });

  group('payment', () {
    test('an unpaid bill owes the whole total', () {
      final d = doc(total: 10000, paid: 0);
      expect(d.duePaise, 10000);
      expect(d.status, PaymentStatus.unpaid);
    });

    test('a part payment leaves the remainder due', () {
      final d = doc(total: 10000, paid: 4000);
      expect(d.duePaise, 6000);
      expect(d.status, PaymentStatus.partial);
    });

    test('a settled bill owes nothing', () {
      final d = doc(total: 10000, paid: 10000);
      expect(d.duePaise, 0);
      expect(d.status, PaymentStatus.paid);
    });
  });

  group('revision', () {
    test('an original bill carries no revision mark', () {
      expect(doc().isRevised, isFalse);
    });

    test("a revised bill says so on the customer's copy", () {
      expect(doc(revision: 1).isRevised, isTrue);
    });
  });

  test('blank shop details become absent rather than empty lines', () {
    final d = buildInvoice(
      shopName: '  ',
      shopAddress: '   ',
      shopPhone: '',
      numberLabel: 'INV-1',
      issuedAt: DateTime(2026, 1, 1),
      lines: const [],
      subtotalPaise: 0,
      discountPaise: 0,
      discountType: DiscountType.none,
      discountValue: 0,
      totalPaise: 0,
      paidPaise: 0,
    );
    expect(d.shopAddress, isNull);
    expect(d.shopPhone, isNull);
    expect(d.shopName, 'My Shop');
  });
}
