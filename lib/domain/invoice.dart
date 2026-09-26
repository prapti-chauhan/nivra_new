/// What goes on a bill. Pure Dart — no Drift, no Flutter, no PDF library.
///
/// This exists so the contents of an invoice can be tested without rendering
/// one. The renderer in `data/pdf/` decides how it looks; this decides what it
/// says, and every number on it is an integer count of paise.
library;

import 'billing.dart';

class InvoiceLine {
  const InvoiceLine({
    required this.position,
    required this.name,
    required this.qtyThousandths,
    required this.unit,
    required this.unitPricePaise,
    required this.lineTotalPaise,
  });

  /// 1-based, as printed in the first column.
  final int position;
  final String name;
  final int qtyThousandths;
  final String unit;
  final int unitPricePaise;
  final int lineTotalPaise;
}

class InvoiceDocument {
  const InvoiceDocument({
    required this.shopName,
    required this.shopAddress,
    required this.shopPhone,
    required this.numberLabel,
    required this.issuedAt,
    required this.customerName,
    required this.customerPhone,
    required this.customerAddress,
    required this.lines,
    required this.subtotalPaise,
    required this.discountPaise,
    required this.discountLabel,
    required this.totalPaise,
    required this.paidPaise,
    required this.revision,
    required this.note,
  });

  final String shopName;
  final String? shopAddress;
  final String? shopPhone;

  /// Already formatted, e.g. "INV-0012".
  final String numberLabel;
  final DateTime issuedAt;

  /// Never empty — a walk-in sale reads "Cash sale" rather than leaving the
  /// most prominent line on the page blank.
  final String customerName;
  final String? customerPhone;
  final String? customerAddress;

  final List<InvoiceLine> lines;

  final int subtotalPaise;
  final int discountPaise;

  /// "Discount" or "Discount (2.5%)". Null when there is no discount, so the
  /// row is omitted rather than printed as a zero.
  final String? discountLabel;

  final int totalPaise;
  final int paidPaise;

  /// 0 for an original bill. Above zero, the bill carries a revision notice —
  /// the customer's copy should say so, not just the shopkeeper's screen.
  final int revision;

  final String? note;

  int get duePaise => totalPaise - paidPaise;

  PaymentStatus get status =>
      paymentStatusFor(totalPaise: totalPaise, paidPaise: paidPaise);

  bool get isRevised => revision > 0;

  /// "Rupees One Thousand Two Hundred Fifty and Fifty Paise Only".
  ///
  /// Indian invoices carry the total in words, and its absence is one of the
  /// things that makes a bill look homemade.
  String get amountInWords => rupeesInWords(totalPaise);
}

/// Builds the document, deriving everything derivable rather than trusting a
/// caller to pass a consistent set of totals.
InvoiceDocument buildInvoice({
  required String shopName,
  String? shopAddress,
  String? shopPhone,
  required String numberLabel,
  required DateTime issuedAt,
  String? customerName,
  String? customerPhone,
  String? customerAddress,
  required List<InvoiceLine> lines,
  required int subtotalPaise,
  required int discountPaise,
  required DiscountType discountType,
  required int discountValue,
  required int totalPaise,
  required int paidPaise,
  int revision = 0,
  String? note,
}) {
  final trimmedName = customerName?.trim();
  return InvoiceDocument(
    shopName: shopName.trim().isEmpty ? 'My Shop' : shopName.trim(),
    shopAddress: _blankToNull(shopAddress),
    shopPhone: _blankToNull(shopPhone),
    numberLabel: numberLabel,
    issuedAt: issuedAt,
    customerName:
        (trimmedName == null || trimmedName.isEmpty) ? 'Cash sale' : trimmedName,
    customerPhone: _blankToNull(customerPhone),
    customerAddress: _blankToNull(customerAddress),
    lines: lines,
    subtotalPaise: subtotalPaise,
    discountPaise: discountPaise,
    discountLabel: discountPaise <= 0
        ? null
        : _discountLabel(discountType, discountValue),
    totalPaise: totalPaise,
    paidPaise: paidPaise,
    revision: revision,
    note: _blankToNull(note),
  );
}

String? _blankToNull(String? value) {
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

String _discountLabel(DiscountType type, int value) {
  if (type != DiscountType.percent) return 'Discount';
  // Basis points: 250 is 2.5%, 1000 is 10%.
  final whole = value ~/ 100;
  final frac = value % 100;
  if (frac == 0) return 'Discount ($whole%)';
  final fracText = frac.toString().padLeft(2, '0').replaceFirst(RegExp(r'0$'), '');
  return 'Discount ($whole.$fracText%)';
}

// ---------------------------------------------------------------------------
// Amount in words, Indian numbering (crore / lakh / thousand).
// ---------------------------------------------------------------------------

const _ones = [
  '', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine',
  'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen',
  'Seventeen', 'Eighteen', 'Nineteen',
];

const _tens = [
  '', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty',
  'Ninety',
];

String _upToNinetyNine(int n) {
  if (n < 20) return _ones[n];
  final tens = _tens[n ~/ 10];
  final rest = n % 10;
  return rest == 0 ? tens : '$tens ${_ones[rest]}';
}

String _upToNineNineNine(int n) {
  if (n < 100) return _upToNinetyNine(n);
  final hundreds = '${_ones[n ~/ 100]} Hundred';
  final rest = n % 100;
  return rest == 0 ? hundreds : '$hundreds ${_upToNinetyNine(rest)}';
}

/// 0 to 99,99,99,999 in the Indian system.
String wholeNumberInWords(int n) {
  if (n == 0) return 'Zero';
  if (n < 0) return 'Minus ${wholeNumberInWords(-n)}';

  final parts = <String>[];
  var rest = n;

  final crore = rest ~/ 10000000;
  rest %= 10000000;
  final lakh = rest ~/ 100000;
  rest %= 100000;
  final thousand = rest ~/ 1000;
  rest %= 1000;

  if (crore > 0) parts.add('${_upToNineNineNine(crore)} Crore');
  if (lakh > 0) parts.add('${_upToNineNineNine(lakh)} Lakh');
  if (thousand > 0) parts.add('${_upToNineNineNine(thousand)} Thousand');
  if (rest > 0) parts.add(_upToNineNineNine(rest));

  return parts.join(' ');
}

/// The total spelled out, as an Indian invoice prints it.
String rupeesInWords(int paise) {
  if (paise < 0) return 'Minus ${rupeesInWords(-paise)}';
  final rupees = paise ~/ 100;
  final remainder = paise % 100;
  final buffer = StringBuffer('Rupees ${wholeNumberInWords(rupees)}');
  if (remainder > 0) {
    buffer.write(' and ${wholeNumberInWords(remainder)} Paise');
  }
  buffer.write(' Only');
  return buffer.toString();
}
