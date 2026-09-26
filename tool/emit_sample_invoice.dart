/// Writes sample bill PDFs so the design can be looked at without launching
/// the app or waiting for an emulator.
///
///     dart run tool/emit_sample_invoice.dart [out-dir]
///
/// Runs on the plain Dart VM — the renderer deliberately has no Flutter
/// dependency, which is also why it can run inside a unit test.
library;

import 'dart:io';

import 'package:nivra_new/data/pdf/invoice_fonts.dart';
import 'package:nivra_new/data/pdf/invoice_pdf.dart';
import 'package:nivra_new/domain/billing.dart';
import 'package:nivra_new/domain/invoice.dart';

Future<void> main(List<String> args) async {
  final outDir = args.isEmpty ? 'build/invoice-samples' : args.first;
  Directory(outDir).createSync(recursive: true);

  final fonts = InvoiceFonts.fromBytes(
    regular: File('assets/fonts/NotoSans-Regular.ttf').readAsBytesSync(),
    bold: File('assets/fonts/NotoSans-Bold.ttf').readAsBytesSync(),
  );

  InvoiceLine mk(int i, String name, int qty, int price, {String unit = 'pcs'}) =>
      InvoiceLine(
        position: i,
        name: name,
        qtyThousandths: qty,
        unit: unit,
        unitPricePaise: price,
        lineTotalPaise: lineTotal(qtyThousandths: qty, unitPricePaise: price),
      );

  Future<void> emit(String name, InvoiceDocument doc) async {
    final file = File('$outDir/$name.pdf');
    await file.writeAsBytes(await renderInvoicePdf(doc, fonts));
    stdout.writeln('${file.path}  ${file.lengthSync()} bytes');
  }

  // The everyday case: a few lines, a discount, a part payment.
  final lines = [
    mk(1, '16mm hex bolt (galvanised)', 4000, 2500),
    mk(2, 'MS binding wire', 1500, 10300, unit: 'kg'),
    mk(3, 'PVC elbow 1 inch', 12000, 1850),
  ];
  final subtotal = lines.fold<int>(0, (s, l) => s + l.lineTotalPaise);
  final discount = const Discount(DiscountType.percent, 250).amountOff(subtotal);

  await emit(
    'typical',
    buildInvoice(
      shopName: 'Sharma Hardware & Sanitary',
      shopAddress: 'Shop 4, Nehru Market, Birhana Road, Kanpur 208001',
      shopPhone: '+91 98765 43210',
      numberLabel: 'INV-0012',
      issuedAt: DateTime(2026, 9, 26, 15, 30),
      customerName: 'Ramesh Kumar',
      customerPhone: '+91 90000 11111',
      lines: lines,
      subtotalPaise: subtotal,
      discountPaise: discount,
      discountType: DiscountType.percent,
      discountValue: 250,
      totalPaise: subtotal - discount,
      paidPaise: 20000,
      note: 'Goods once sold will be taken back within 7 days with this bill.',
    ),
  );

  // The counter sale: no customer, nothing owing, no frills.
  await emit(
    'cash-sale',
    buildInvoice(
      shopName: 'Sharma Hardware & Sanitary',
      shopPhone: '+91 98765 43210',
      numberLabel: 'INV-0013',
      issuedAt: DateTime(2026, 9, 26, 16, 5),
      lines: [mk(1, 'PVC elbow 1 inch', 2000, 1850)],
      subtotalPaise: 3700,
      discountPaise: 0,
      discountType: DiscountType.none,
      discountValue: 0,
      totalPaise: 3700,
      paidPaise: 3700,
    ),
  );

  // Long enough to paginate, and revised, so both edge blocks are visible.
  final many = [
    for (var i = 1; i <= 40; i++) mk(i, 'Item number $i', 2000, 4999),
  ];
  final manySubtotal = many.fold<int>(0, (s, l) => s + l.lineTotalPaise);
  await emit(
    'long-and-revised',
    buildInvoice(
      shopName: 'Sharma Hardware & Sanitary',
      shopAddress: 'Shop 4, Nehru Market, Birhana Road, Kanpur 208001',
      numberLabel: 'INV-0014',
      issuedAt: DateTime(2026, 9, 26, 17, 0),
      customerName: 'Verma Constructions',
      lines: many,
      subtotalPaise: manySubtotal,
      discountPaise: 0,
      discountType: DiscountType.none,
      discountValue: 0,
      totalPaise: manySubtotal,
      paidPaise: 0,
      revision: 2,
    ),
  );
}
