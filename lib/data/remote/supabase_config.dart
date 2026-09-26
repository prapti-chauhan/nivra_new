/// Supabase credentials come from the build, never from the repository.
///
/// Run with:
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
///
/// When they are absent the app still runs, fully usable, in local-only mode
/// with sync reported as inactive. That is not a fallback bolted on for
/// convenience — an app that refuses to start without a backend is the wrong
/// shape for a shop with no signal.
class SupabaseConfig {
  const SupabaseConfig._();

  static const String url = String.fromEnvironment('SUPABASE_URL');

  /// Supabase renamed the anon key to the publishable key. Both spellings are
  /// accepted so an older build command keeps working.
  static const String _publishableKey =
      String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const String _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static String get publishableKey =>
      _publishableKey.isNotEmpty ? _publishableKey : _anonKey;

  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;
}
