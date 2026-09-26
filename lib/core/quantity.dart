/// Quantities are integer thousandths of a unit.
///
/// 1.5 kg is stored as 1500. Integer quantities would break the first time
/// Ramesh sells half a metre of wire, and doubles would slowly corrupt stock.
library;

class Qty {
  const Qty._();

  static const int scale = 1000;

  static int fromWhole(int units) => units * scale;

  /// '1.5', '2', '0.25' — trailing zeros trimmed so lists stay readable.
  static String format(int thousandths) {
    final negative = thousandths < 0;
    final abs = thousandths.abs();
    final whole = abs ~/ scale;
    final frac = abs % scale;
    final sign = negative ? '-' : '';
    if (frac == 0) return '$sign$whole';
    final fracText = frac.toString().padLeft(3, '0').replaceFirst(RegExp(r'0+$'), '');
    return '$sign$whole.$fracText';
  }

  static String formatWithUnit(int thousandths, String unit) =>
      '${format(thousandths)} $unit';

  /// Parses '1', '1.5', '0.250'. Returns null when the input is not a number
  /// or has more precision than we store.
  static int? tryParse(String input) {
    final cleaned = input.replaceAll(RegExp(r'[^0-9.\-]'), '');
    if (cleaned.isEmpty || cleaned == '-' || cleaned == '.') return null;
    if ('.'.allMatches(cleaned).length > 1) return null;
    if (cleaned.lastIndexOf('-') > 0) return null;

    final negative = cleaned.startsWith('-');
    final body = negative ? cleaned.substring(1) : cleaned;
    final dot = body.indexOf('.');

    final int whole;
    final int frac;
    if (dot < 0) {
      whole = int.tryParse(body) ?? -1;
      frac = 0;
    } else {
      final wholePart = body.substring(0, dot);
      final fracPart = body.substring(dot + 1);
      if (fracPart.length > 3) return null;
      whole = wholePart.isEmpty ? 0 : (int.tryParse(wholePart) ?? -1);
      frac = fracPart.isEmpty ? 0 : (int.tryParse(fracPart.padRight(3, '0')) ?? -1);
    }
    if (whole < 0 || frac < 0) return null;

    final total = whole * scale + frac;
    return negative ? -total : total;
  }
}
