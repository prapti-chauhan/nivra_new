import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;

/// The two faces the invoice is set in.
///
/// These are bundled as assets, never fetched. The `printing` package offers a
/// `PdfGoogleFonts` helper that downloads at runtime, which would fail in a
/// shop with no signal — and this document has to be producible in a power
/// cut (docs/decisions.md: the app works offline without drama).
///
/// The bundled faces are subsets of Noto Sans containing Latin, punctuation
/// and U+20B9. The standard PDF fonts have no rupee glyph at all, so without
/// an embedded face the bill cannot print the one symbol it most needs.
class InvoiceFonts {
  const InvoiceFonts({required this.regular, required this.bold});

  final pw.Font regular;
  final pw.Font bold;

  static InvoiceFonts fromBytes({
    required Uint8List regular,
    required Uint8List bold,
  }) =>
      InvoiceFonts(
        regular: pw.Font.ttf(ByteData.sublistView(regular)),
        bold: pw.Font.ttf(ByteData.sublistView(bold)),
      );
}
