import 'package:drift/drift.dart';

import '../db/database.dart';

/// Row <-> JSON for the synced tables.
///
/// Two columns are deliberately never pushed:
///   * `stock_qty`, because it is a local cache derived from the movements
///     that are pushed alongside it. Sending it would let a stale server copy
///     race the value a pull is about to recompute.
///   * `logo_path`, because a filesystem path on one phone means nothing on
///     another. The image itself travels through Supabase Storage (see
///     `data/sync/logo_sync.dart`); only `logo_version` rides with the row.
///   * `customers.balance` and `bills.amount_paid`, for the same reason as
///     `stock_qty`: both are sums of rows that are themselves synced, so a
///     fresh install recomputes them rather than trusting a number off the
///     wire.
class RowMappers {
  const RowMappers._();

  static int? _int(Object? value) => (value as num?)?.toInt();

  // --- items ---------------------------------------------------------------

  static Map<String, dynamic> itemToJson(Item row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'name': row.name,
        'code': row.code,
        'unit': row.unit,
        'sale_price': row.salePrice,
        'purchase_price': row.purchasePrice,
        'low_stock_threshold': row.lowStockThreshold,
        'category': row.category,
        'hsn_code': row.hsnCode,
        'tax_rate_bp': row.taxRateBp,
      };

  static ItemsCompanion itemFromJson(Map<String, dynamic> json) =>
      ItemsCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value(_int(json['created_at']) ?? 0),
        updatedAt: Value(_int(json['updated_at']) ?? 0),
        deletedAt: Value(_int(json['deleted_at'])),
        serverUpdatedAt: Value(_int(json['server_updated_at'])),
        name: Value(json['name'] as String? ?? ''),
        code: Value(json['code'] as String?),
        unit: Value(json['unit'] as String? ?? 'pcs'),
        salePrice: Value(_int(json['sale_price']) ?? 0),
        purchasePrice: Value(_int(json['purchase_price']) ?? 0),
        lowStockThreshold: Value(_int(json['low_stock_threshold'])),
        category: Value(json['category'] as String?),
        hsnCode: Value(json['hsn_code'] as String?),
        taxRateBp: Value(_int(json['tax_rate_bp']) ?? 0),
        // Arrives clean, and its stock cache is rebuilt from movements after
        // the pull rather than trusted from the wire.
        isDirty: const Value(false),
      );

  // --- stock movements -----------------------------------------------------

  static Map<String, dynamic> movementToJson(StockMovement row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'item_id': row.itemId,
        'qty_delta': row.qtyDelta,
        'unit_cost': row.unitCost,
        'reason': row.reason,
        'source_type': row.sourceType,
        'source_id': row.sourceId,
        'occurred_at': row.occurredAt,
        'note': row.note,
      };

  static StockMovementsCompanion movementFromJson(Map<String, dynamic> json) =>
      StockMovementsCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value(_int(json['created_at']) ?? 0),
        updatedAt: Value(_int(json['updated_at']) ?? 0),
        deletedAt: Value(_int(json['deleted_at'])),
        serverUpdatedAt: Value(_int(json['server_updated_at'])),
        itemId: Value(json['item_id'] as String),
        qtyDelta: Value(_int(json['qty_delta']) ?? 0),
        unitCost: Value(_int(json['unit_cost']) ?? 0),
        reason: Value(json['reason'] as String? ?? 'adjustment'),
        sourceType: Value(json['source_type'] as String?),
        sourceId: Value(json['source_id'] as String?),
        occurredAt: Value(_int(json['occurred_at']) ?? 0),
        note: Value(json['note'] as String?),
        isDirty: const Value(false),
      );

  // --- business profile ----------------------------------------------------

  static Map<String, dynamic> profileToJson(BusinessProfile row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'shop_name': row.shopName,
        'owner_name': row.ownerName,
        'phone': row.phone,
        'address': row.address,
        'invoice_prefix': row.invoicePrefix,
        'invoice_next_number': row.invoiceNextNumber,
        // Never a version still waiting to be uploaded: another phone would be
        // told about an image that is not in Storage yet, and would cache
        // whatever older image is there under the new version number.
        'logo_version': row.logoVersion == 0
            ? 0
            : (row.logoUploadedVersion < row.logoVersion
                ? row.logoUploadedVersion
                : row.logoVersion),
      };

  static BusinessProfilesCompanion profileFromJson(Map<String, dynamic> json) =>
      BusinessProfilesCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value(_int(json['created_at']) ?? 0),
        updatedAt: Value(_int(json['updated_at']) ?? 0),
        deletedAt: Value(_int(json['deleted_at'])),
        serverUpdatedAt: Value(_int(json['server_updated_at'])),
        shopName: Value(json['shop_name'] as String? ?? ''),
        ownerName: Value(json['owner_name'] as String?),
        phone: Value(json['phone'] as String?),
        address: Value(json['address'] as String?),
        invoicePrefix: Value(json['invoice_prefix'] as String? ?? ''),
        invoiceNextNumber: Value(_int(json['invoice_next_number']) ?? 1),
        logoVersion: Value(_int(json['logo_version']) ?? 0),
        // Storage has whatever version the server advertises, by definition.
        // Without this a later local edit of the profile would push an older
        // number back over it. `logo_path` and the cached version are left
        // alone: they describe this phone's copy, and a gap between them and
        // `logo_version` is what makes the next sync fetch the new image.
        logoUploadedVersion: Value(_int(json['logo_version']) ?? 0),
        isDirty: const Value(false),
      );
}

/// Slice two. Same rules: caches are never sent, and anything the server can
/// recompute from synced rows is recomputed rather than trusted.
extension BillingMappers on RowMappers {
  // --- customers -----------------------------------------------------------

  static Map<String, dynamic> customerToJson(Customer row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'name': row.name,
        'phone': row.phone,
        'address': row.address,
        'note': row.note,
        'gstin': row.gstin,
        'linked_supplier_id': row.linkedSupplierId,
      };

  static CustomersCompanion customerFromJson(Map<String, dynamic> json) =>
      CustomersCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value((json['created_at'] as num?)?.toInt() ?? 0),
        updatedAt: Value((json['updated_at'] as num?)?.toInt() ?? 0),
        deletedAt: Value((json['deleted_at'] as num?)?.toInt()),
        serverUpdatedAt: Value((json['server_updated_at'] as num?)?.toInt()),
        name: Value(json['name'] as String? ?? ''),
        phone: Value(json['phone'] as String?),
        address: Value(json['address'] as String?),
        note: Value(json['note'] as String?),
        gstin: Value(json['gstin'] as String?),
        linkedSupplierId: Value(json['linked_supplier_id'] as String?),
        isDirty: const Value(false),
      );

  // --- ledger entries ------------------------------------------------------

  static Map<String, dynamic> ledgerToJson(LedgerEntry row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'account_type': row.accountType,
        'account_id': row.accountId,
        'amount': row.amount,
        'reason': row.reason,
        'source_type': row.sourceType,
        'source_id': row.sourceId,
        'occurred_at': row.occurredAt,
        'note': row.note,
      };

  static LedgerEntriesCompanion ledgerFromJson(Map<String, dynamic> json) =>
      LedgerEntriesCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value((json['created_at'] as num?)?.toInt() ?? 0),
        updatedAt: Value((json['updated_at'] as num?)?.toInt() ?? 0),
        deletedAt: Value((json['deleted_at'] as num?)?.toInt()),
        serverUpdatedAt: Value((json['server_updated_at'] as num?)?.toInt()),
        accountType: Value(json['account_type'] as String? ?? 'cash'),
        accountId: Value(json['account_id'] as String?),
        amount: Value((json['amount'] as num?)?.toInt() ?? 0),
        reason: Value(json['reason'] as String? ?? 'adjustment'),
        sourceType: Value(json['source_type'] as String?),
        sourceId: Value(json['source_id'] as String?),
        occurredAt: Value((json['occurred_at'] as num?)?.toInt() ?? 0),
        note: Value(json['note'] as String?),
        isDirty: const Value(false),
      );

  // --- bills ---------------------------------------------------------------

  static Map<String, dynamic> billToJson(Bill row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'number': row.number,
        'number_prefix': row.numberPrefix,
        'customer_id': row.customerId,
        'customer_name': row.customerName,
        'subtotal': row.subtotal,
        'discount_type': row.discountType,
        'discount_value': row.discountValue,
        'discount_amount': row.discountAmount,
        'total': row.total,
        'occurred_at': row.occurredAt,
        'note': row.note,
        'revision': row.revision,
      };

  static BillsCompanion billFromJson(Map<String, dynamic> json) =>
      BillsCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value((json['created_at'] as num?)?.toInt() ?? 0),
        updatedAt: Value((json['updated_at'] as num?)?.toInt() ?? 0),
        deletedAt: Value((json['deleted_at'] as num?)?.toInt()),
        serverUpdatedAt: Value((json['server_updated_at'] as num?)?.toInt()),
        number: Value((json['number'] as num?)?.toInt() ?? 0),
        numberPrefix: Value(json['number_prefix'] as String? ?? ''),
        customerId: Value(json['customer_id'] as String?),
        customerName: Value(json['customer_name'] as String?),
        subtotal: Value((json['subtotal'] as num?)?.toInt() ?? 0),
        discountType: Value(json['discount_type'] as String? ?? 'none'),
        discountValue: Value((json['discount_value'] as num?)?.toInt() ?? 0),
        discountAmount: Value((json['discount_amount'] as num?)?.toInt() ?? 0),
        total: Value((json['total'] as num?)?.toInt() ?? 0),
        occurredAt: Value((json['occurred_at'] as num?)?.toInt() ?? 0),
        note: Value(json['note'] as String?),
        revision: Value((json['revision'] as num?)?.toInt() ?? 0),
        isDirty: const Value(false),
      );

  // --- bill lines ----------------------------------------------------------

  static Map<String, dynamic> billLineToJson(BillLine row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'bill_id': row.billId,
        'item_id': row.itemId,
        'name': row.name,
        'unit': row.unit,
        'qty': row.qty,
        'unit_price': row.unitPrice,
        'unit_cost': row.unitCost,
        'original_unit_cost': row.originalUnitCost,
        'cost_corrected_at': row.costCorrectedAt,
        'line_total': row.lineTotal,
        'tax_rate_bp': row.taxRateBp,
        'position': row.position,
      };

  static BillLinesCompanion billLineFromJson(Map<String, dynamic> json) =>
      BillLinesCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value((json['created_at'] as num?)?.toInt() ?? 0),
        updatedAt: Value((json['updated_at'] as num?)?.toInt() ?? 0),
        deletedAt: Value((json['deleted_at'] as num?)?.toInt()),
        serverUpdatedAt: Value((json['server_updated_at'] as num?)?.toInt()),
        billId: Value(json['bill_id'] as String),
        itemId: Value(json['item_id'] as String?),
        name: Value(json['name'] as String? ?? ''),
        unit: Value(json['unit'] as String? ?? 'pcs'),
        qty: Value((json['qty'] as num?)?.toInt() ?? 0),
        unitPrice: Value((json['unit_price'] as num?)?.toInt() ?? 0),
        unitCost: Value((json['unit_cost'] as num?)?.toInt() ?? 0),
        originalUnitCost: Value((json['original_unit_cost'] as num?)?.toInt()),
        costCorrectedAt: Value((json['cost_corrected_at'] as num?)?.toInt()),
        lineTotal: Value((json['line_total'] as num?)?.toInt() ?? 0),
        taxRateBp: Value((json['tax_rate_bp'] as num?)?.toInt() ?? 0),
        position: Value((json['position'] as num?)?.toInt() ?? 0),
        isDirty: const Value(false),
      );

  // --- bill revisions ------------------------------------------------------

  static Map<String, dynamic> billRevisionToJson(BillRevision row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'bill_id': row.billId,
        'revision': row.revision,
        'snapshot': row.snapshot,
        'replaced_at': row.replacedAt,
      };

  static BillRevisionsCompanion billRevisionFromJson(
    Map<String, dynamic> json,
  ) =>
      BillRevisionsCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value((json['created_at'] as num?)?.toInt() ?? 0),
        updatedAt: Value((json['updated_at'] as num?)?.toInt() ?? 0),
        deletedAt: Value((json['deleted_at'] as num?)?.toInt()),
        serverUpdatedAt: Value((json['server_updated_at'] as num?)?.toInt()),
        billId: Value(json['bill_id'] as String),
        revision: Value((json['revision'] as num?)?.toInt() ?? 0),
        snapshot: Value(json['snapshot'] as String? ?? '{}'),
        replacedAt: Value((json['replaced_at'] as num?)?.toInt() ?? 0),
        isDirty: const Value(false),
      );

  // --- payments ------------------------------------------------------------

  static Map<String, dynamic> paymentToJson(Payment row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'customer_id': row.customerId,
        'bill_id': row.billId,
        'supplier_id': row.supplierId,
        'purchase_id': row.purchaseId,
        'amount': row.amount,
        'method': row.method,
        'occurred_at': row.occurredAt,
        'note': row.note,
      };

  static PaymentsCompanion paymentFromJson(Map<String, dynamic> json) =>
      PaymentsCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value((json['created_at'] as num?)?.toInt() ?? 0),
        updatedAt: Value((json['updated_at'] as num?)?.toInt() ?? 0),
        deletedAt: Value((json['deleted_at'] as num?)?.toInt()),
        serverUpdatedAt: Value((json['server_updated_at'] as num?)?.toInt()),
        customerId: Value(json['customer_id'] as String?),
        billId: Value(json['bill_id'] as String?),
        supplierId: Value(json['supplier_id'] as String?),
        purchaseId: Value(json['purchase_id'] as String?),
        amount: Value((json['amount'] as num?)?.toInt() ?? 0),
        method: Value(json['method'] as String? ?? 'cash'),
        occurredAt: Value((json['occurred_at'] as num?)?.toInt() ?? 0),
        note: Value(json['note'] as String?),
        isDirty: const Value(false),
      );

  // --- suppliers -----------------------------------------------------------
  //
  // `balance` is absent on purpose, exactly as `customers.balance` is: the
  // cache is derived locally from the ledger and never crosses the wire.

  static Map<String, dynamic> supplierToJson(Supplier row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'name': row.name,
        'phone': row.phone,
        'address': row.address,
        'note': row.note,
        'gstin': row.gstin,
        'linked_customer_id': row.linkedCustomerId,
      };

  static SuppliersCompanion supplierFromJson(Map<String, dynamic> json) =>
      SuppliersCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value((json['created_at'] as num?)?.toInt() ?? 0),
        updatedAt: Value((json['updated_at'] as num?)?.toInt() ?? 0),
        deletedAt: Value((json['deleted_at'] as num?)?.toInt()),
        serverUpdatedAt: Value((json['server_updated_at'] as num?)?.toInt()),
        name: Value(json['name'] as String? ?? ''),
        phone: Value(json['phone'] as String?),
        address: Value(json['address'] as String?),
        note: Value(json['note'] as String?),
        gstin: Value(json['gstin'] as String?),
        linkedCustomerId: Value(json['linked_customer_id'] as String?),
        isDirty: const Value(false),
      );

  // --- purchases -----------------------------------------------------------
  //
  // `amount_paid` stays local for the same reason `bills.amount_paid` does:
  // it is rebuilt from the payments that arrive alongside.

  static Map<String, dynamic> purchaseToJson(Purchase row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'supplier_id': row.supplierId,
        'supplier_name': row.supplierName,
        'supplier_bill_no': row.supplierBillNo,
        'subtotal': row.subtotal,
        'discount_type': row.discountType,
        'discount_value': row.discountValue,
        'discount_amount': row.discountAmount,
        'total': row.total,
        'occurred_at': row.occurredAt,
        'note': row.note,
        'revision': row.revision,
      };

  static PurchasesCompanion purchaseFromJson(Map<String, dynamic> json) =>
      PurchasesCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value((json['created_at'] as num?)?.toInt() ?? 0),
        updatedAt: Value((json['updated_at'] as num?)?.toInt() ?? 0),
        deletedAt: Value((json['deleted_at'] as num?)?.toInt()),
        serverUpdatedAt: Value((json['server_updated_at'] as num?)?.toInt()),
        supplierId: Value(json['supplier_id'] as String? ?? ''),
        supplierName: Value(json['supplier_name'] as String?),
        supplierBillNo: Value(json['supplier_bill_no'] as String?),
        subtotal: Value((json['subtotal'] as num?)?.toInt() ?? 0),
        discountType: Value(json['discount_type'] as String? ?? 'none'),
        discountValue: Value((json['discount_value'] as num?)?.toInt() ?? 0),
        discountAmount: Value((json['discount_amount'] as num?)?.toInt() ?? 0),
        total: Value((json['total'] as num?)?.toInt() ?? 0),
        occurredAt: Value((json['occurred_at'] as num?)?.toInt() ?? 0),
        note: Value(json['note'] as String?),
        revision: Value((json['revision'] as num?)?.toInt() ?? 0),
        isDirty: const Value(false),
      );

  static Map<String, dynamic> purchaseRevisionToJson(PurchaseRevision row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'purchase_id': row.purchaseId,
        'revision': row.revision,
        'snapshot': row.snapshot,
        'replaced_at': row.replacedAt,
      };

  static PurchaseRevisionsCompanion purchaseRevisionFromJson(
    Map<String, dynamic> json,
  ) =>
      PurchaseRevisionsCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value((json['created_at'] as num?)?.toInt() ?? 0),
        updatedAt: Value((json['updated_at'] as num?)?.toInt() ?? 0),
        deletedAt: Value((json['deleted_at'] as num?)?.toInt()),
        serverUpdatedAt: Value((json['server_updated_at'] as num?)?.toInt()),
        purchaseId: Value(json['purchase_id'] as String),
        revision: Value((json['revision'] as num?)?.toInt() ?? 0),
        snapshot: Value(json['snapshot'] as String? ?? '{}'),
        replacedAt: Value((json['replaced_at'] as num?)?.toInt() ?? 0),
        isDirty: const Value(false),
      );

  static Map<String, dynamic> purchaseLineToJson(PurchaseLine row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'purchase_id': row.purchaseId,
        'item_id': row.itemId,
        'name': row.name,
        'unit': row.unit,
        'qty': row.qty,
        'unit_cost': row.unitCost,
        'line_total': row.lineTotal,
        'tax_rate_bp': row.taxRateBp,
        'position': row.position,
      };

  static PurchaseLinesCompanion purchaseLineFromJson(
          Map<String, dynamic> json) =>
      PurchaseLinesCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value((json['created_at'] as num?)?.toInt() ?? 0),
        updatedAt: Value((json['updated_at'] as num?)?.toInt() ?? 0),
        deletedAt: Value((json['deleted_at'] as num?)?.toInt()),
        serverUpdatedAt: Value((json['server_updated_at'] as num?)?.toInt()),
        purchaseId: Value(json['purchase_id'] as String? ?? ''),
        itemId: Value(json['item_id'] as String?),
        name: Value(json['name'] as String? ?? ''),
        unit: Value(json['unit'] as String? ?? 'pcs'),
        qty: Value((json['qty'] as num?)?.toInt() ?? 0),
        unitCost: Value((json['unit_cost'] as num?)?.toInt() ?? 0),
        lineTotal: Value((json['line_total'] as num?)?.toInt() ?? 0),
        taxRateBp: Value((json['tax_rate_bp'] as num?)?.toInt() ?? 0),
        position: Value((json['position'] as num?)?.toInt() ?? 0),
        isDirty: const Value(false),
      );

  // --- money entries -------------------------------------------------------

  static Map<String, dynamic> moneyEntryToJson(MoneyEntry row) => {
        'id': row.id,
        'user_id': row.userId,
        'created_at': row.createdAt,
        'updated_at': row.updatedAt,
        'deleted_at': row.deletedAt,
        'kind': row.kind,
        'amount': row.amount,
        'category': row.category,
        'method': row.method,
        'to_method': row.toMethod,
        'occurred_at': row.occurredAt,
        'note': row.note,
      };

  static MoneyEntriesCompanion moneyEntryFromJson(Map<String, dynamic> json) =>
      MoneyEntriesCompanion(
        id: Value(json['id'] as String),
        userId: Value(json['user_id'] as String),
        createdAt: Value((json['created_at'] as num?)?.toInt() ?? 0),
        updatedAt: Value((json['updated_at'] as num?)?.toInt() ?? 0),
        deletedAt: Value((json['deleted_at'] as num?)?.toInt()),
        serverUpdatedAt: Value((json['server_updated_at'] as num?)?.toInt()),
        kind: Value(json['kind'] as String? ?? 'expense'),
        amount: Value((json['amount'] as num?)?.toInt() ?? 0),
        category: Value(json['category'] as String?),
        method: Value(json['method'] as String? ?? 'cash'),
        toMethod: Value(json['to_method'] as String?),
        occurredAt: Value((json['occurred_at'] as num?)?.toInt() ?? 0),
        note: Value(json['note'] as String?),
        isDirty: const Value(false),
      );
}

