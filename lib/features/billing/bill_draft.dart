import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../domain/billing.dart';

/// One line being built. Prices and costs are snapshotted off the item the
/// moment it is added, so editing the item afterwards cannot change a bill.
class DraftLine {
  const DraftLine({
    required this.itemId,
    required this.name,
    required this.unit,
    required this.qty,
    required this.unitPrice,
    required this.unitCost,
  });

  final String itemId;
  final String name;
  final String unit;
  final int qty;
  final int unitPrice;
  final int unitCost;

  int get total => lineTotal(qtyThousandths: qty, unitPricePaise: unitPrice);

  DraftLine copyWith({int? qty, int? unitPrice}) => DraftLine(
        itemId: itemId,
        name: name,
        unit: unit,
        qty: qty ?? this.qty,
        unitPrice: unitPrice ?? this.unitPrice,
        unitCost: unitCost,
      );

  BillLineDraft toDraft() => BillLineDraft(
        itemId: itemId,
        name: name,
        unit: unit,
        qty: qty,
        unitPrice: unitPrice,
        unitCost: unitCost,
      );
}

class BillDraft {
  const BillDraft({
    this.lines = const [],
    this.customerId,
    this.customerName,
    this.discount = const Discount.none(),
    this.credit = false,
    this.note,
    this.editingBillId,
  });

  final List<DraftLine> lines;
  final String? customerId;
  final String? customerName;
  final Discount discount;

  /// False means a cash sale, which is the common case over a counter.
  final bool credit;

  final String? note;

  /// Set when revising an existing bill rather than creating one.
  final String? editingBillId;

  bool get isEmpty => lines.isEmpty;
  bool get isEditing => editingBillId != null;
  int get itemCount => lines.length;

  BillTotals get totals =>
      totalsFor(lineTotals: lines.map((l) => l.total), discount: discount);

  BillDraft copyWith({
    List<DraftLine>? lines,
    Object? customerId = _unset,
    Object? customerName = _unset,
    Discount? discount,
    bool? credit,
    Object? note = _unset,
    Object? editingBillId = _unset,
  }) {
    return BillDraft(
      lines: lines ?? this.lines,
      customerId:
          customerId == _unset ? this.customerId : customerId as String?,
      customerName:
          customerName == _unset ? this.customerName : customerName as String?,
      discount: discount ?? this.discount,
      credit: credit ?? this.credit,
      note: note == _unset ? this.note : note as String?,
      editingBillId: editingBillId == _unset
          ? this.editingBillId
          : editingBillId as String?,
    );
  }

  static const Object _unset = Object();
}

class BillDraftNotifier extends Notifier<BillDraft> {
  @override
  BillDraft build() => const BillDraft();

  /// Adding an item already on the bill bumps its quantity instead of writing
  /// a second line. Tapping the same result twice meaning "two of those" is
  /// how people actually use a search box, and it saves an interaction.
  void addItem(Item item) {
    final index = state.lines.indexWhere((l) => l.itemId == item.id);
    if (index >= 0) {
      changeQty(index, state.lines[index].qty + 1000);
      return;
    }
    state = state.copyWith(
      lines: [
        ...state.lines,
        DraftLine(
          itemId: item.id,
          name: item.name,
          unit: item.unit,
          qty: 1000,
          unitPrice: item.salePrice,
          unitCost: item.purchasePrice,
        ),
      ],
    );
  }

  void changeQty(int index, int qty) {
    if (index < 0 || index >= state.lines.length) return;
    if (qty <= 0) {
      removeLine(index);
      return;
    }
    final lines = [...state.lines];
    lines[index] = lines[index].copyWith(qty: qty);
    state = state.copyWith(lines: lines);
  }

  void changePrice(int index, int unitPrice) {
    if (index < 0 || index >= state.lines.length) return;
    final lines = [...state.lines];
    lines[index] = lines[index].copyWith(unitPrice: unitPrice);
    state = state.copyWith(lines: lines);
  }

  void removeLine(int index) {
    if (index < 0 || index >= state.lines.length) return;
    final lines = [...state.lines]..removeAt(index);
    state = state.copyWith(lines: lines);
  }

  /// Passing null makes it a cash sale again, which also forces the bill back
  /// to paid — a credit sale with nobody attached is a debt owed by no one.
  void setCustomer(Customer? customer) {
    state = state.copyWith(
      customerId: customer?.id,
      customerName: customer?.name,
      credit: customer == null ? false : state.credit,
    );
  }

  void setDiscount(Discount discount) =>
      state = state.copyWith(discount: discount);

  void setNote(String? note) => state = state.copyWith(note: note);

  /// Returns false when credit was refused because there is no customer.
  bool setCredit(bool credit) {
    if (credit && state.customerId == null) return false;
    state = state.copyWith(credit: credit);
    return true;
  }

  void loadForEdit({
    required Bill bill,
    required List<BillLine> lines,
  }) {
    state = BillDraft(
      editingBillId: bill.id,
      customerId: bill.customerId,
      customerName: bill.customerName,
      credit: bill.amountPaid < bill.total,
      note: bill.note,
      discount: Discount(
        DiscountType.fromWire(bill.discountType),
        bill.discountValue,
      ),
      lines: [
        for (final l in lines)
          DraftLine(
            itemId: l.itemId ?? '',
            name: l.name,
            unit: l.unit,
            qty: l.qty,
            unitPrice: l.unitPrice,
            unitCost: l.unitCost,
          ),
      ],
    );
  }

  void clear() => state = const BillDraft();
}

final billDraftProvider =
    NotifierProvider<BillDraftNotifier, BillDraft>(BillDraftNotifier.new);
