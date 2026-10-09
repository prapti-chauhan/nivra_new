import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../domain/billing.dart';
import '../../domain/invoice.dart';
import 'invoice_fonts.dart';

/// A5 rather than A4.
///
/// Almost every one of these bills is read on a phone in WhatsApp, and an A4
/// page holding three lines is mostly empty space. A5 fills a phone screen and
/// still prints correctly. Change this one constant to print A4.
const PdfPageFormat kInvoicePageFormat = PdfPageFormat.a5;

const _ink = PdfColor.fromInt(0xFF17171A);
const _muted = PdfColor.fromInt(0xFF71717A);
const _rule = PdfColor.fromInt(0xFFE0E0E4);
const _panel = PdfColor.fromInt(0xFFF5F5F6);
const _danger = PdfColor.fromInt(0xFF9F1239);

/// Renders [doc] to PDF bytes. No network, no platform channels.
///
/// [logo] is the shop's logo image, if it has one. A logo is a convenience and
/// a bill is not: if the image cannot be drawn for any reason the bill is
/// rendered again without it rather than failing, so a bad file can never stop
/// Ramesh from handing a customer their bill.
Future<Uint8List> renderInvoicePdf(
  InvoiceDocument doc,
  InvoiceFonts fonts, {
  PdfPageFormat format = kInvoicePageFormat,
  Uint8List? logo,
}) async {
  if (logo == null) return _render(doc, fonts, format, null);
  try {
    return await _render(doc, fonts, format, logo);
  } catch (_) {
    return _render(doc, fonts, format, null);
  }
}

Future<Uint8List> _render(
  InvoiceDocument doc,
  InvoiceFonts fonts,
  PdfPageFormat format,
  Uint8List? logo,
) async {
  final logoImage = logo == null ? null : pw.MemoryImage(logo);
  final pdf = pw.Document(
    title: doc.numberLabel,
    author: doc.shopName,
    theme: pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold)
        .copyWith(
      defaultTextStyle: pw.TextStyle(
        font: fonts.regular,
        fontSize: 9,
        color: _ink,
        lineSpacing: 1.2,
      ),
    ),
  );

  pdf.addPage(
    pw.MultiPage(
      pageFormat: format.copyWith(
        marginLeft: 28,
        marginRight: 28,
        marginTop: 28,
        marginBottom: 28,
      ),
      header: (context) =>
          context.pageNumber == 1
              ? _header(doc, fonts, logoImage)
              : _continuedHeader(doc, fonts),
      footer: (context) => _footer(context, doc),
      build: (context) => [
        pw.SizedBox(height: 14),
        _billTo(doc, fonts),
        pw.SizedBox(height: 14),
        _lineTable(doc, fonts),
        pw.SizedBox(height: 12),
        _totals(doc, fonts),
        pw.SizedBox(height: 12),
        _inWords(doc, fonts),
        if (doc.isRevised) ...[
          pw.SizedBox(height: 12),
          _revisionNotice(doc, fonts),
        ],
        if (doc.note != null) ...[
          pw.SizedBox(height: 12),
          _note(doc, fonts),
        ],
        pw.SizedBox(height: 34),
        _signature(doc, fonts),
      ],
    ),
  );

  return pdf.save();
}

pw.Widget _header(
  InvoiceDocument doc,
  InvoiceFonts fonts,
  pw.ImageProvider? logo,
) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (logo != null) ...[
            // Contained in a fixed box so a wide banner and a tall emblem both
            // sit beside the name without pushing the invoice number around.
            pw.Container(
              width: 46,
              height: 46,
              child: pw.Image(logo, fit: pw.BoxFit.contain),
            ),
            pw.SizedBox(width: 10),
          ],
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  doc.shopName,
                  style: pw.TextStyle(
                    font: fonts.bold,
                    fontSize: 16,
                    color: _ink,
                  ),
                ),
                if (doc.shopAddress != null) ...[
                  pw.SizedBox(height: 3),
                  pw.Text(
                    doc.shopAddress!,
                    style: const pw.TextStyle(fontSize: 8, color: _muted),
                  ),
                ],
                if (doc.shopPhone != null) ...[
                  pw.SizedBox(height: 1),
                  pw.Text(
                    doc.shopPhone!,
                    style: const pw.TextStyle(fontSize: 8, color: _muted),
                  ),
                ],
              ],
            ),
          ),
          pw.SizedBox(width: 16),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                'INVOICE',
                style: pw.TextStyle(
                  font: fonts.bold,
                  fontSize: 9,
                  color: _muted,
                  letterSpacing: 1.8,
                ),
              ),
              pw.SizedBox(height: 3),
              pw.Text(
                doc.numberLabel,
                style: pw.TextStyle(font: fonts.bold, fontSize: 13, color: _ink),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                DateFormat('d MMM yyyy').format(doc.issuedAt),
                style: const pw.TextStyle(fontSize: 8, color: _muted),
              ),
              pw.Text(
                DateFormat('h:mm a').format(doc.issuedAt),
                style: const pw.TextStyle(fontSize: 8, color: _muted),
              ),
            ],
          ),
        ],
      ),
      pw.SizedBox(height: 10),
      pw.Container(height: 1.4, color: _ink),
    ],
  );
}

pw.Widget _continuedHeader(InvoiceDocument doc, InvoiceFonts fonts) {
  return pw.Container(
    padding: const pw.EdgeInsets.only(bottom: 8),
    decoration: const pw.BoxDecoration(
      border: pw.Border(bottom: pw.BorderSide(color: _rule)),
    ),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(doc.shopName,
            style: pw.TextStyle(font: fonts.bold, fontSize: 9, color: _muted)),
        pw.Text('${doc.numberLabel} (continued)',
            style: const pw.TextStyle(fontSize: 9, color: _muted)),
      ],
    ),
  );
}

pw.Widget _billTo(InvoiceDocument doc, InvoiceFonts fonts) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        'BILL TO',
        style: pw.TextStyle(
          font: fonts.bold,
          fontSize: 7,
          color: _muted,
          letterSpacing: 1.2,
        ),
      ),
      pw.SizedBox(height: 4),
      pw.Text(
        doc.customerName,
        style: pw.TextStyle(font: fonts.bold, fontSize: 11, color: _ink),
      ),
      if (doc.customerPhone != null)
        pw.Text(doc.customerPhone!,
            style: const pw.TextStyle(fontSize: 8, color: _muted)),
      if (doc.customerAddress != null)
        pw.Text(doc.customerAddress!,
            style: const pw.TextStyle(fontSize: 8, color: _muted)),
    ],
  );
}

pw.Widget _lineTable(InvoiceDocument doc, InvoiceFonts fonts) {
  return pw.Table(
    columnWidths: const {
      // Wide enough for a three-digit line number at 9pt plus its padding.
      // At 18 this wrapped "10" onto two lines, which only showed up on a
      // bill long enough to reach double figures.
      0: pw.FixedColumnWidth(30),
      1: pw.FlexColumnWidth(),
      2: pw.FixedColumnWidth(58),
      3: pw.FixedColumnWidth(62),
      4: pw.FixedColumnWidth(70),
    },
    children: [
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: _panel),
        children: [
          _headCell('#', fonts, align: pw.TextAlign.left),
          _headCell('ITEM', fonts, align: pw.TextAlign.left),
          _headCell('QTY', fonts),
          // The cells below print plain numbers so the column stays aligned;
          // without the symbol here the table would carry no currency at all.
          _headCell('RATE (\u20B9)', fonts),
          _headCell('AMOUNT (\u20B9)', fonts),
        ],
      ),
      for (final line in doc.lines)
        pw.TableRow(
          decoration: const pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide(color: _rule, width: 0.6)),
          ),
          children: [
            _bodyCell('${line.position}', align: pw.TextAlign.left, muted: true),
            _bodyCell(line.name, align: pw.TextAlign.left),
            _bodyCell(Qty.formatWithUnit(line.qtyThousandths, line.unit)),
            _bodyCell(Money.formatPlain(line.unitPricePaise)),
            _bodyCell(Money.formatPlain(line.lineTotalPaise)),
          ],
        ),
    ],
  );
}

pw.Widget _headCell(String text, InvoiceFonts fonts,
    {pw.TextAlign align = pw.TextAlign.right}) {
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 6),
    child: pw.Text(
      text,
      textAlign: align,
      style: pw.TextStyle(
        font: fonts.bold,
        fontSize: 7,
        color: _muted,
        letterSpacing: 0.8,
      ),
    ),
  );
}

pw.Widget _bodyCell(String text,
    {pw.TextAlign align = pw.TextAlign.right, bool muted = false}) {
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 7),
    child: pw.Text(
      text,
      textAlign: align,
      style: pw.TextStyle(fontSize: 9, color: muted ? _muted : _ink),
    ),
  );
}

pw.Widget _totals(InvoiceDocument doc, InvoiceFonts fonts) {
  final rows = <pw.Widget>[
    _totalRow('Subtotal', Money.format(doc.subtotalPaise), fonts),
    if (doc.discountLabel != null)
      _totalRow(
        doc.discountLabel!,
        '- ${Money.format(doc.discountPaise)}',
        fonts,
      ),
  ];

  return pw.Row(
    children: [
      pw.Expanded(child: pw.SizedBox()),
      pw.SizedBox(
        width: 200,
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            ...rows,
            pw.SizedBox(height: 6),
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              color: _panel,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Total',
                      style: pw.TextStyle(
                          font: fonts.bold, fontSize: 11, color: _ink)),
                  pw.Text(Money.format(doc.totalPaise),
                      style: pw.TextStyle(
                          font: fonts.bold, fontSize: 11, color: _ink)),
                ],
              ),
            ),
            if (doc.paidPaise > 0) ...[
              pw.SizedBox(height: 6),
              _totalRow('Paid', Money.format(doc.paidPaise), fonts),
            ],
            if (doc.duePaise > 0) ...[
              pw.SizedBox(height: 2),
              _totalRow(
                'Balance due',
                Money.format(doc.duePaise),
                fonts,
                emphasise: true,
              ),
            ],
          ],
        ),
      ),
    ],
  );
}

pw.Widget _totalRow(String label, String value, InvoiceFonts fonts,
    {bool emphasise = false}) {
  final color = emphasise ? _danger : _ink;
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(label,
            style: pw.TextStyle(
                fontSize: 9,
                color: emphasise ? color : _muted,
                font: emphasise ? fonts.bold : fonts.regular)),
        pw.Text(value,
            style: pw.TextStyle(
                fontSize: 9,
                color: color,
                font: emphasise ? fonts.bold : fonts.regular)),
      ],
    ),
  );
}

pw.Widget _inWords(InvoiceDocument doc, InvoiceFonts fonts) {
  return pw.Container(
    padding: const pw.EdgeInsets.only(top: 8),
    decoration: const pw.BoxDecoration(
      border: pw.Border(top: pw.BorderSide(color: _rule)),
    ),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('In words: ',
            style: pw.TextStyle(font: fonts.bold, fontSize: 8, color: _muted)),
        pw.Expanded(
          child: pw.Text(doc.amountInWords,
              style: const pw.TextStyle(fontSize: 8, color: _ink)),
        ),
      ],
    ),
  );
}

pw.Widget _revisionNotice(InvoiceDocument doc, InvoiceFonts fonts) {
  return pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: pw.BoxDecoration(
      color: _panel,
      border: pw.Border.all(color: _rule, width: 0.6),
    ),
    child: pw.Text(
      'Revised copy. This bill replaces revision ${doc.revision - 1} and is '
      'the current version.',
      style: pw.TextStyle(font: fonts.bold, fontSize: 7.5, color: _muted),
    ),
  );
}

pw.Widget _note(InvoiceDocument doc, InvoiceFonts fonts) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text('NOTE',
          style: pw.TextStyle(
              font: fonts.bold, fontSize: 7, color: _muted, letterSpacing: 1.2)),
      pw.SizedBox(height: 3),
      pw.Text(doc.note!, style: const pw.TextStyle(fontSize: 8, color: _ink)),
    ],
  );
}

/// Standard on an Indian invoice, and it gives the lower half of a short
/// bill something to be rather than blank paper.
pw.Widget _signature(InvoiceDocument doc, InvoiceFonts fonts) {
  return pw.Row(
    children: [
      pw.Expanded(child: pw.SizedBox()),
      pw.SizedBox(
        width: 170,
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(
              'For ${doc.shopName}',
              textAlign: pw.TextAlign.right,
              style: pw.TextStyle(font: fonts.bold, fontSize: 8, color: _ink),
            ),
            pw.SizedBox(height: 30),
            pw.Container(height: 0.6, color: _rule),
            pw.SizedBox(height: 3),
            pw.Text(
              'Authorised signature',
              style: const pw.TextStyle(fontSize: 7, color: _muted),
            ),
          ],
        ),
      ),
    ],
  );
}

pw.Widget _footer(pw.Context context, InvoiceDocument doc) {
  final status = switch (doc.status) {
    PaymentStatus.paid => 'Paid in full',
    PaymentStatus.partial => 'Part payment received',
    PaymentStatus.unpaid => 'Payment pending',
  };
  return pw.Container(
    padding: const pw.EdgeInsets.only(top: 8),
    decoration: const pw.BoxDecoration(
      border: pw.Border(top: pw.BorderSide(color: _rule)),
    ),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(status, style: const pw.TextStyle(fontSize: 7.5, color: _muted)),
        pw.Text(
          context.pagesCount > 1
              ? 'Page ${context.pageNumber} of ${context.pagesCount}'
              : 'Thank you for your business',
          style: const pw.TextStyle(fontSize: 7.5, color: _muted),
        ),
      ],
    ),
  );
}
