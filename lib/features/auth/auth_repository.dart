import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// The signed-in shop owner.
class NivraUser {
  const NivraUser({required this.id, this.email, this.isLocalOnly = false});

  final String id;
  final String? email;

  /// True when the app is running without a Supabase project configured.
  /// Everything works; nothing leaves the device.
  final bool isLocalOnly;
}

class AuthFailure implements Exception {
  AuthFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class AuthRepository {
  Stream<NivraUser?> watchUser();

  NivraUser? get currentUser;

  Future<void> signIn({required String email, required String password});

  Future<void> signUp({required String email, required String password});

  Future<void> signOut();
}

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._auth);

  final sb.GoTrueClient _auth;

  /// An expired token must not lock Ramesh out of data that is sitting on his
  /// own phone. If a session exists at all we treat him as signed in and let
  /// sync be the thing that fails, loudly but harmlessly, until the network
  /// returns and the refresh succeeds.
  NivraUser? _toUser(sb.Session? session) {
    final user = session?.user;
    if (user == null) return null;
    return NivraUser(id: user.id, email: user.email);
  }

  @override
  NivraUser? get currentUser => _toUser(_auth.currentSession);

  @override
  Stream<NivraUser?> watchUser() async* {
    yield currentUser;
    yield* _auth.onAuthStateChange.map((event) => _toUser(event.session));
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    try {
      await _auth.signInWithPassword(email: email.trim(), password: password);
    } on sb.AuthException catch (e) {
      throw AuthFailure(_friendly(e));
    } catch (e) {
      throw AuthFailure('Could not sign in. Check your connection.');
    }
  }

  @override
  Future<void> signUp({required String email, required String password}) async {
    try {
      await _auth.signUp(email: email.trim(), password: password);
    } on sb.AuthException catch (e) {
      throw AuthFailure(_friendly(e));
    } catch (e) {
      throw AuthFailure('Could not create the account. Check your connection.');
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();

  String _friendly(sb.AuthException e) {
    final message = e.message.toLowerCase();
    if (message.contains('invalid login')) {
      return 'That email and password do not match.';
    }
    if (message.contains('already registered')) {
      return 'That email already has an account. Sign in instead.';
    }
    if (message.contains('password')) {
      return 'Password must be at least 6 characters.';
    }
    return e.message;
  }
}

/// Used when no Supabase project is configured. The app is fully usable and
/// every row is owned by [localUserId] until a real account claims it.
class LocalOnlyAuthRepository implements AuthRepository {
  static const String localUserId = 'local-only-user';

  final _controller = StreamController<NivraUser?>.broadcast();
  NivraUser? _user;

  @override
  NivraUser? get currentUser => _user;

  @override
  Stream<NivraUser?> watchUser() async* {
    yield _user;
    yield* _controller.stream;
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    _user = NivraUser(id: localUserId, email: email.trim(), isLocalOnly: true);
    _controller.add(_user);
  }

  @override
  Future<void> signUp({required String email, required String password}) => signIn(email: email, password: password);

  @override
  Future<void> signOut() async {
    _user = null;
    _controller.add(null);
  }
}
