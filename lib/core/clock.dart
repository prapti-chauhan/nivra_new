/// The source of "now" for the whole app.
///
/// Every timestamp nivra stores is UTC epoch milliseconds (docs/decisions.md
/// D4). Nothing calls `DateTime.now()` directly — it goes through a [Clock] so
/// that tests can pin time and assert on exact `created_at` / `updated_at`
/// values instead of guessing at tolerances.
///
/// These readings come from the device clock, which on cheap Android hardware
/// is frequently wrong and which users reset by hand. They are used for display
/// and for last-write tie-breaking only. They are deliberately NOT the sync
/// pull cursor — that is `server_updated_at`, stamped by Postgres, because a
/// phone running twenty minutes fast would otherwise skip rows forever (D5).
library;

class Clock {
  const Clock();

  /// UTC epoch milliseconds.
  int nowMillis() => DateTime.now().toUtc().millisecondsSinceEpoch;
}

/// A [Clock] frozen at a chosen instant, for tests.
///
/// Time only moves when [advance] is called, so a test can assert that an edit
/// bumped `updated_at` by exactly the amount it expected.
class FixedClock implements Clock {
  FixedClock(this._millis);

  int _millis;

  @override
  int nowMillis() => _millis;

  /// Moves this clock forward by [millis].
  void advance(int millis) => _millis += millis;

  /// Jumps this clock to an absolute instant, including backwards — useful for
  /// exercising what happens when a device's clock is wrong.
  void setTo(int millis) => _millis = millis;
}
