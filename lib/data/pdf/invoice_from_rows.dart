import '../../domain/billing.dart';
import '../../domain/invoice.dart';
import '../db/database.dart';

/// Maps stored rows onto the document the renderer prints.
///
/// The bill's own stored totals are used rather than recomputed here: they
/// were computed by `domain/billing.dart` when the bill was saved, and the
/// customer's copy must match what the shop's screen says, including for an
/// old bill saved under different arithmetic.
InvoiceDocument invoiceFromRows({
  required Bill bill,
  required List<BillLine> lines,
  Customer? customer,
  BusinessProfile? profile,
}) {
  final ordered = [...lines]..sort((a, b) => a.position.compareTo(b.position));

  return buildInvoice(
    shopName: profile?.shopName ?? '',
    shopAddress: profile?.address,
    shopPhone: profile?.phone,
    numberLabel:
        invoiceLabel(prefix: bill.numberPrefix, number: bill.number),
    issuedAt: DateTime.fromMillisecondsSinceEpoch(bill.occurredAt).toLocal(),
    // The name snapshotted on the bill wins over the customer's current name,
    // so a later rename cannot silently change what an old bill says.
    customerName: bill.customerName ?? customer?.name,
    customerPhone: customer?.phone,
    customerAddress: customer?.address,
    lines: [
      for (var i = 0; i < ordered.length; i++)
        InvoiceLine(
          position: i + 1,
          name: ordered[i].name,
          qtyThousandths: ordered[i].qty,
          unit: ordered[i].unit,
          unitPricePaise: ordered[i].unitPrice,
          lineTotalPaise: ordered[i].lineTotal,
        ),
    ],
    subtotalPaise: bill.subtotal,
    discountPaise: bill.discountAmount,
    discountType: DiscountType.fromWire(bill.discountType),
    discountValue: bill.discountValue,
    totalPaise: bill.total,
    paidPaise: bill.amountPaid,
    revision: bill.revision,
    note: bill.note,
  );
}
