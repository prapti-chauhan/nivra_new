/// Bill arithmetic. Pure Dart — no Drift, no Flutter, no clock.
///
/// Every amount here is an integer count of paise and every quantity an
/// integer count of thousandths. The only place rounding happens is
/// [lineTotal], and it rounds half away from zero so a line never quietly
/// loses a paisa the customer was charged.
library;

/// Quantity in thousandths times price in paise, back to paise.
///
/// 1.5 kg at Rs 10.33 is 1500 * 1033 = 1_549_500, which is 1549.5 paise and
/// must become 1550, not 1549.
int lineTotal({required int qtyThousandths, required int unitPricePaise}) {
  final product = qtyThousandths * unitPricePaise;
  if (product >= 0) return (product + 500) ~/ 1000;
  return -((-product + 500) ~/ 1000);
}

enum DiscountType {
  none('none'),

  /// [Discount.value] is basis points: 250 means 2.5%.
  percent('percent'),

  /// [Discount.value] is paise.
  amount('amount');

  const DiscountType(this.wire);
  final String wire;

  static DiscountType fromWire(String? value) {
    for (final t in DiscountType.values) {
      if (t.wire == value) return t;
    }
    return DiscountType.none;
  }
}

class Discount {
  const Discount(this.type, this.value);
  const Discount.none() : type = DiscountType.none, value = 0;

  final DiscountType type;

  /// Basis points when [type] is percent, paise when it is amount.
  final int value;

  /// What this discount is worth against [subtotalPaise].
  ///
  /// Never more than the subtotal — a discount cannot make a bill negative,
  /// and a fat-fingered "5000" off a Rs 430 bill should cap, not invert.
  int amountOff(int subtotalPaise) {
    if (subtotalPaise <= 0) return 0;
    final raw = switch (type) {
      DiscountType.none => 0,
      DiscountType.amount => value,
      DiscountType.percent => (subtotalPaise * value + 5000) ~/ 10000,
    };
    if (raw <= 0) return 0;
    return raw > subtotalPaise ? subtotalPaise : raw;
  }
}

class BillTotals {
  const BillTotals({
    required this.subtotal,
    required this.discount,
    required this.total,
  });

  final int subtotal;
  final int discount;
  final int total;
}

BillTotals totalsFor({
  required Iterable<int> lineTotals,
  Discount discount = const Discount.none(),
}) {
  final subtotal = lineTotals.fold<int>(0, (sum, value) => sum + value);
  final off = discount.amountOff(subtotal);
  return BillTotals(subtotal: subtotal, discount: off, total: subtotal - off);
}

enum PaymentStatus { paid, partial, unpaid }

/// Never stored. Always computed, so it cannot disagree with the payments
/// that produced it.
PaymentStatus paymentStatusFor({
  required int totalPaise,
  required int paidPaise,
}) {
  if (totalPaise <= 0) return PaymentStatus.paid;
  if (paidPaise >= totalPaise) return PaymentStatus.paid;
  if (paidPaise <= 0) return PaymentStatus.unpaid;
  return PaymentStatus.partial;
}

/// Which side of the books a ledger entry belongs to.
///
/// Entries are signed and account-tagged rather than strictly double-entry:
/// positive always means "more is owed to Ramesh" or "money came in".
enum LedgerAccount {
  customer('customer'),
  supplier('supplier'),
  cash('cash'),
  bank('bank'),
  sales('sales'),
  purchase('purchase'),
  expense('expense'),
  otherIncome('other_income');

  const LedgerAccount(this.wire);
  final String wire;

  static LedgerAccount fromWire(String value) {
    for (final a in LedgerAccount.values) {
      if (a.wire == value) return a;
    }
    return LedgerAccount.cash;
  }
}

enum LedgerReason {
  sale('sale'),
  saleReversal('sale_reversal'),
  paymentIn('payment_in'),
  paymentInReversal('payment_in_reversal'),
  purchase('purchase'),
  purchaseReversal('purchase_reversal'),
  paymentOut('payment_out'),
  paymentOutReversal('payment_out_reversal'),
  opening('opening'),
  adjustment('adjustment');

  const LedgerReason(this.wire);
  final String wire;

  static LedgerReason fromWire(String value) {
    for (final r in LedgerReason.values) {
      if (r.wire == value) return r;
    }
    return LedgerReason.adjustment;
  }
}

/// Formats an invoice number for display. The stored number is a plain
/// integer plus whatever prefix the shop had at the time, so changing the
/// prefix later never rewrites an old bill.
String invoiceLabel({required String prefix, required int number}) =>
    prefix.isEmpty ? '$number' : '$prefix$number';

/// A supplier balance read the way Ramesh thinks about it.
///
/// Ledger figures are signed so that positive means owed to him, which leaves
/// a supplier he owes sitting at a negative balance. The sign is flipped here,
/// at the edge, rather than in the stored cache — see the note on
/// `Suppliers.balance`.
int payableFromBalance(int balance) => -balance;

/// How a ledger row reads to Ramesh. Shared by the customer and supplier
/// ledgers so the same event is never described two different ways.
String ledgerReasonLabel(LedgerReason reason) => switch (reason) {
      LedgerReason.sale => 'Bill',
      LedgerReason.saleReversal => 'Bill corrected',
      LedgerReason.paymentIn => 'Payment received',
      LedgerReason.paymentInReversal => 'Payment reversed',
      LedgerReason.purchase => 'Purchase',
      LedgerReason.purchaseReversal => 'Purchase removed',
      LedgerReason.paymentOut => 'Payment made',
      LedgerReason.paymentOutReversal => 'Payment reversed',
      LedgerReason.opening => 'Opening balance',
      LedgerReason.adjustment => 'Adjusted by hand',
    };

