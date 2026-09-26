/// The state of the device's data relative to Supabase.
///
/// The brief is explicit that this is never hidden from Ramesh, so it is a
/// first-class domain concept rather than a spinner somewhere.
library;

enum SyncPhase {
  /// Everything local has reached the server.
  synced,

  /// Local changes are waiting. Not an error — this is the normal state in a
  /// shop with bad coverage.
  pending,

  /// A push or pull is running right now.
  syncing,

  /// No network. Work continues; nothing is lost.
  offline,

  /// Something went wrong that retrying has not fixed.
  failed,

  /// Signed out, or sync not configured.
  inactive,
}

class SyncStatus {
  const SyncStatus({
    required this.phase,
    this.pendingCount = 0,
    this.lastSyncedAtMillis,
    this.message,
  });

  const SyncStatus.inactive()
      : phase = SyncPhase.inactive,
        pendingCount = 0,
        lastSyncedAtMillis = null,
        message = null;

  final SyncPhase phase;

  /// How many local rows have not reached the server.
  final int pendingCount;

  final int? lastSyncedAtMillis;

  /// Present only when [phase] is [SyncPhase.failed].
  final String? message;

  bool get hasPendingWork => pendingCount > 0;

  SyncStatus copyWith({
    SyncPhase? phase,
    int? pendingCount,
    int? lastSyncedAtMillis,
    String? message,
  }) {
    return SyncStatus(
      phase: phase ?? this.phase,
      pendingCount: pendingCount ?? this.pendingCount,
      lastSyncedAtMillis: lastSyncedAtMillis ?? this.lastSyncedAtMillis,
      message: message ?? this.message,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SyncStatus &&
      other.phase == phase &&
      other.pendingCount == pendingCount &&
      other.lastSyncedAtMillis == lastSyncedAtMillis &&
      other.message == message;

  @override
  int get hashCode => Object.hash(phase, pendingCount, lastSyncedAtMillis, message);
}
