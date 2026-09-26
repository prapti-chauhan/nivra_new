import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

import 'invoice_fonts.dart';

/// Loads the bundled faces through the asset bundle.
///
/// Kept apart from [InvoiceFonts] so the renderer itself stays plain Dart and
/// can run outside a Flutter runtime — see `tool/emit_sample_invoice.dart`.
Future<InvoiceFonts> loadInvoiceFontsFromAssets() async {
  final regular = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
  final bold = await rootBundle.load('assets/fonts/NotoSans-Bold.ttf');
  return InvoiceFonts(
    regular: pw.Font.ttf(regular),
    bold: pw.Font.ttf(bold),
  );
}
