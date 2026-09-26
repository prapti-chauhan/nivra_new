/// Money in nivra is always an integer count of paise.
///
/// Rupees 1,250.50 is stored as 125050. Doubles never touch a money value,
/// not even for display — the formatters below split the integer by hand so
/// there is no point in the pipeline where a rounding error can appear.
library;

class Money {
  const Money._();

  /// '1,250.50' — no symbol, for tables and PDF columns with a currency header.
  static String formatPlain(int paise) {
    final negative = paise < 0;
    final abs = paise.abs();
    final rupees = _groupIndian(abs ~/ 100);
    final fraction = (abs % 100).toString().padLeft(2, '0');
    return '${negative ? '-' : ''}$rupees.$fraction';
  }

  /// 'Rs 1,250.50' with the rupee sign.
  static String format(int paise) {
    final negative = paise < 0;
    return '${negative ? '-' : ''}₹${formatPlain(paise.abs())}';
  }

  /// Drops '.00' so whole amounts read cleanly in dense lists.
  static String formatCompact(int paise) {
    if (paise % 100 == 0) {
      final negative = paise < 0;
      return '${negative ? '-' : ''}₹${_groupIndian(paise.abs() ~/ 100)}';
    }
    return format(paise);
  }

  /// Parses what a shopkeeper actually types: '1250', '1250.5', '1,250.50',
  /// 'Rs 1250'. Returns null when the input is not a number.
  static int? tryParse(String input) {
    final cleaned = input.replaceAll(RegExp(r'[^0-9.\-]'), '');
    if (cleaned.isEmpty || cleaned == '-' || cleaned == '.') return null;
    if ('.'.allMatches(cleaned).length > 1) return null;
    if (cleaned.lastIndexOf('-') > 0) return null;

    final negative = cleaned.startsWith('-');
    final body = negative ? cleaned.substring(1) : cleaned;
    final dot = body.indexOf('.');

    final int rupees;
    final int paise;
    if (dot < 0) {
      rupees = int.tryParse(body) ?? -1;
      paise = 0;
    } else {
      final whole = body.substring(0, dot);
      final frac = body.substring(dot + 1);
      if (frac.length > 2) return null;
      rupees = whole.isEmpty ? 0 : (int.tryParse(whole) ?? -1);
      paise = frac.isEmpty ? 0 : (int.tryParse(frac.padRight(2, '0')) ?? -1);
    }
    if (rupees < 0 || paise < 0) return null;

    final total = rupees * 100 + paise;
    return negative ? -total : total;
  }

  /// Indian digit grouping: 12,34,567 rather than 1,234,567.
  static String _groupIndian(int value) {
    final digits = value.toString();
    if (digits.length <= 3) return digits;
    final last3 = digits.substring(digits.length - 3);
    var rest = digits.substring(0, digits.length - 3);
    final buffer = <String>[];
    while (rest.length > 2) {
      buffer.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) buffer.insert(0, rest);
    return '${buffer.join(',')},$last3';
  }
}
