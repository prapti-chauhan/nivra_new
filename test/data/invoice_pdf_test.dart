import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/clock.dart';
import 'package:nivra_new/data/db/database.dart';
import 'package:nivra_new/data/pdf/invoice_fonts.dart';
import 'package:nivra_new/data/pdf/invoice_from_rows.dart';
import 'package:nivra_new/data/pdf/invoice_pdf.dart';
import 'package:nivra_new/domain/billing.dart';
import 'package:nivra_new/domain/invoice.dart';

const userId = 'user-1';

/// Read straight off disk rather than through rootBundle: this proves the
/// renderer needs nothing but bytes, which is the same reason it works with
/// no network on a phone.
InvoiceFonts loadFonts() => InvoiceFonts.fromBytes(
      regular: File('assets/fonts/NotoSans-Regular.ttf').readAsBytesSync(),
      bold: File('assets/fonts/NotoSans-Bold.ttf').readAsBytesSync(),
    );

InvoiceLine line(int i, {String name = 'Item', int qty = 1000}) => InvoiceLine(
      position: i,
      name: name,
      qtyThousandths: qty,
      unit: 'pcs',
      unitPricePaise: 2500,
      lineTotalPaise: 2500 * (qty ~/ 1000),
    );

InvoiceDocument sample({int lineCount = 3, int paid = 0, int revision = 0}) {
  final lines = [for (var i = 1; i <= lineCount; i++) line(i, name: 'Item $i')];
  final subtotal = lines.fold<int>(0, (s, l) => s + l.lineTotalPaise);
  return buildInvoice(
    shopName: 'Sharma Hardware',
    shopAddress: 'Shop 4, Nehru Market, Kanpur',
    shopPhone: '+91 98765 43210',
    numberLabel: 'INV-0012',
    issuedAt: DateTime(2026, 9, 26, 15, 30),
    customerName: 'Ramesh Kumar',
    customerPhone: '+91 90000 11111',
    lines: lines,
    subtotalPaise: subtotal,
    discountPaise: 0,
    discountType: DiscountType.none,
    discountValue: 0,
    totalPaise: subtotal,
    paidPaise: paid,
    revision: revision,
  );
}


/// Counts pages by reading the page objects out of the raw PDF.
///
/// `/Type/Pages` (the tree root) contains `/Type/Page` as a substring, so the
/// root is subtracted off.
int pageCount(Uint8List bytes) {
  final text = String.fromCharCodes(bytes);
  final pages = '/Type/Page'.allMatches(text).length;
  final roots = '/Type/Pages'.allMatches(text).length;
  return pages - roots;
}

void main() {
  late InvoiceFonts fonts;

  setUpAll(() => fonts = loadFonts());

  group('rendering', () {
    test('produces a real PDF', () async {
      final bytes = await renderInvoicePdf(sample(), fonts);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(5000));
    });

    test('renders the rupee sign without throwing', () async {
      // The standard PDF fonts have no U+20B9. If the embedded subset were
      // ever dropped this is the test that fails.
      final bytes = await renderInvoicePdf(sample(), fonts);
      expect(bytes, isNotEmpty);
    });

    test('a short bill is one page', () async {
      expect(pageCount(await renderInvoicePdf(sample(lineCount: 3), fonts)), 1);
    });

    test('a long bill paginates instead of overflowing', () async {
      final long = await renderInvoicePdf(sample(lineCount: 80), fonts);
      expect(pageCount(long), greaterThan(1));
    });

    test('double-digit line numbers do not wrap', () async {
      // Regression: the '#' column was 18pt wide, which could not fit "10"
      // at 9pt once padding was taken off. Every row from ten onwards grew to
      // two lines, which pushed a 40-line bill from three pages to four.
      // Nothing threw and no test failed — it was only visible in the output.
      final bytes = await renderInvoicePdf(sample(lineCount: 40), fonts);
      expect(pageCount(bytes), 3);
    });

    test('an empty-name shop still renders', () async {
      final doc = buildInvoice(
        shopName: '',
        numberLabel: 'INV-1',
        issuedAt: DateTime(2026, 1, 1),
        lines: [line(1)],
        subtotalPaise: 2500,
        discountPaise: 0,
        discountType: DiscountType.none,
        discountValue: 0,
        totalPaise: 2500,
        paidPaise: 0,
      );
      final bytes = await renderInvoicePdf(doc, fonts);
      expect(bytes.length, greaterThan(1000));
    });

    test('a revised, part-paid bill renders its extra blocks', () async {
      final bytes =
          await renderInvoicePdf(sample(paid: 1000, revision: 2), fonts);
      expect(bytes.length, greaterThan(5000));
    });
  });

  group('from stored rows', () {
    late AppDatabase db;
    late BillingDao billing;
    late InventoryDao inventory;
    late PartyDao parties;

    setUp(() {
      db = AppDatabase.forTesting(
        NativeDatabase.memory(),
        clock: FixedClock(1700000000000),
      );
      billing = BillingDao(db);
      inventory = InventoryDao(db);
      parties = PartyDao(db);
    });

    tearDown(() => db.close());

    test('the customer copy matches the stored bill', () async {
      final itemId = await inventory.createItem(
        userId: userId,
        name: '16mm hex bolt',
        salePrice: 2500,
        purchasePrice: 1800,
        openingStock: 100000,
      );
      final customerId = await parties.createCustomer(
        userId: userId,
        name: 'Ramesh Kumar',
        phone: '+91 90000 11111',
      );

      final billId = await billing.saveBill(
        userId: userId,
        customerId: customerId,
        customerName: 'Ramesh Kumar',
        lines: [
          BillLineDraft(
            itemId: itemId,
            name: '16mm hex bolt',
            unit: 'pcs',
            qty: 4000,
            unitPrice: 2500,
          ),
        ],
        discount: const Discount(DiscountType.percent, 250),
        paid: false,
        amountPaid: 0,
      );

      final bill = (await billing.findBill(billId))!;
      final lines = await billing.linesFor(billId);
      final customer = await parties.findCustomer(customerId);
      final profile = await billing.ensureProfile(userId);

      final doc = invoiceFromRows(
        bill: bill,
        lines: lines,
        customer: customer,
        profile: profile,
      );

      // 4 bolts at Rs 25 is Rs 100; 2.5% off is Rs 2.50.
      expect(doc.subtotalPaise, 10000);
      expect(doc.discountPaise, 250);
      expect(doc.discountLabel, 'Discount (2.5%)');
      expect(doc.totalPaise, 9750);
      expect(doc.duePaise, 9750);
      expect(doc.status, PaymentStatus.unpaid);
      expect(doc.customerName, 'Ramesh Kumar');
      expect(doc.customerPhone, '+91 90000 11111');
      expect(doc.lines.single.name, '16mm hex bolt');
      expect(doc.lines.single.qtyThousandths, 4000);
      expect(doc.amountInWords, 'Rupees Ninety Seven and Fifty Paise Only');

      // And the whole thing renders.
      final bytes = await renderInvoicePdf(doc, fonts);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('a cash sale with no customer still produces a bill', () async {
      final itemId = await inventory.createItem(
        userId: userId,
        name: 'PVC elbow',
        salePrice: 1200,
        purchasePrice: 800,
        openingStock: 50000,
      );
      final billId = await billing.saveBill(
        userId: userId,
        lines: [
          BillLineDraft(
            itemId: itemId,
            name: 'PVC elbow',
            unit: 'pcs',
            qty: 2000,
            unitPrice: 1200,
          ),
        ],
      );

      final doc = invoiceFromRows(
        bill: (await billing.findBill(billId))!,
        lines: await billing.linesFor(billId),
        profile: await billing.ensureProfile(userId),
      );

      expect(doc.customerName, 'Cash sale');
      expect(doc.status, PaymentStatus.paid);
      expect(doc.duePaise, 0);
      final bytes = await renderInvoicePdf(doc, fonts);
      expect(bytes, isNotEmpty);
    });

    test('lines are numbered in stored order, not query order', () async {
      final ids = <String>[];
      for (final name in ['Nut', 'Bolt', 'Washer']) {
        ids.add(await inventory.createItem(
          userId: userId,
          name: name,
          salePrice: 1000,
          purchasePrice: 500,
          openingStock: 10000,
        ));
      }
      final billId = await billing.saveBill(
        userId: userId,
        lines: [
          for (var i = 0; i < ids.length; i++)
            BillLineDraft(
              itemId: ids[i],
              name: ['Nut', 'Bolt', 'Washer'][i],
              unit: 'pcs',
              qty: 1000,
              unitPrice: 1000,
            ),
        ],
      );

      final doc = invoiceFromRows(
        bill: (await billing.findBill(billId))!,
        lines: (await billing.linesFor(billId)).reversed.toList(),
        profile: await billing.ensureProfile(userId),
      );

      expect(doc.lines.map((l) => l.name).toList(), ['Nut', 'Bolt', 'Washer']);
      expect(doc.lines.map((l) => l.position).toList(), [1, 2, 3]);
    });
  });
}
