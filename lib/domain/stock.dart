/// Stock rules. Pure Dart — no Drift, no Flutter, no clock.
///
/// Stock on hand is defined as the sum of an item's movements. The cached
/// `stock_qty` column on `items` is an optimisation over this function and
/// must always agree with it; `rebuildStockCache` exists to prove that.
library;

/// Why a stock movement happened. Stored as a string so the set can grow
/// without a migration.
enum MovementReason {
  opening('opening'),
  purchase('purchase'),
  sale('sale'),
  adjustment('adjustment'),
  reversal('reversal');

  const MovementReason(this.wire);

  /// The value written to the database and sent to Supabase.
  final String wire;

  static MovementReason fromWire(String value) => MovementReason.values
      .firstWhere((r) => r.wire == value, orElse: () => MovementReason.adjustment);
}

/// What produced a movement, so any stock figure can be traced to a document.
enum MovementSource {
  bill('bill'),
  purchase('purchase'),
  adjustment('adjustment');

  const MovementSource(this.wire);
  final String wire;

  static MovementSource? fromWire(String? value) {
    if (value == null) return null;
    for (final s in MovementSource.values) {
      if (s.wire == value) return s;
    }
    return null;
  }
}

/// The authoritative definition of stock on hand.
int stockFromMovements(Iterable<int> deltas) =>
    deltas.fold<int>(0, (sum, delta) => sum + delta);

enum StockStatus {
  /// Nothing left, or somehow negative.
  out,

  /// At or below the threshold Ramesh set for this item.
  low,

  healthy,

  /// No threshold set, so we have nothing useful to say. We stay quiet
  /// rather than inventing a warning he will learn to ignore.
  untracked,
}

StockStatus stockStatusFor({
  required int qtyThousandths,
  int? thresholdThousandths,
}) {
  if (qtyThousandths <= 0) return StockStatus.out;
  if (thresholdThousandths == null) return StockStatus.untracked;
  if (qtyThousandths <= thresholdThousandths) return StockStatus.low;
  return StockStatus.healthy;
}
