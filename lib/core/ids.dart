import 'package:uuid/uuid.dart';

/// Rows get their identity on the device, not from the server.
///
/// Offline-first forces this: a bill needs an id the moment it is saved,
/// which may be hours before Supabase ever hears about it.
const _uuid = Uuid();

String newId() => _uuid.v4();
