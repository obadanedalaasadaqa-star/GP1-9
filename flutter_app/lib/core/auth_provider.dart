import 'package:flutter/material.dart';
import 'api_client.dart';
import 'login_challenge.dart';
import 'offline_cache.dart';
import 'user_model.dart';

/// Startup /user/me timeout: a free Render server can take about a minute to wake up.
const _kStartupTimeout = Duration(seconds: 60);
const _kUnreachable = "Can't reach the Nexus server. Check your connection and try again.";

class AuthProvider extends ChangeNotifier {
  User? _user;
  bool _loading = true;
  bool _wakingServer = false;
  String? _startupError;
  bool _justRegistered = false;
  bool _offline = false;
  // +1 on every logout, login and register. A /user/me answer that arrives
  // after one of those belongs to the old session and is dropped.
  int _session = 0;

  User? get user => _user;
  bool get loading => _loading;
  bool get isLoggedIn => _user != null;

  /// True when the app opened with no connection and is using the profile
  /// saved on the phone. Cleared by the first successful [refreshUser].
  bool get offline => _offline;

  /// True while the startup profile request runs (the server may be waking up).
  bool get wakingServer => _wakingServer;

  /// Set when a saved session couldn't be checked (timeout, server down).
  /// The token is kept, so [retry] can log the user straight back in.
  String? get startupError => _startupError;

  /// True once right after registering, so the app can open email verification.
  bool consumeJustRegistered() {
    final v = _justRegistered;
    _justRegistered = false;
    return v;
  }

  AuthProvider() {
    _init();
  }

  Future<void> _init() async {
    try {
      final session = _session;
      final token = await ApiClient.getToken();
      if (token != null) {
        _wakingServer = true;
        notifyListeners();
        try {
          final me = await ApiClient.getMe(timeout: _kStartupTimeout);
          if (session != _session) return; // logged out or in again meanwhile
          _user = me;
          _offline = false;
          await _saveUser(me);
        } on ApiException catch (e) {
          // Only a rejected token (401) or a deleted account (JSON 404 from our
          // server) logs the user out. A non-JSON 404 means the host itself is
          // missing/suspended, so keep the token and show Retry.
          if (e.statusCode == 401 || (e.statusCode == 404 && e.fromServer)) {
            await ApiClient.clearToken();
            await OfflineCache.clear();
          } else if (!e.fromServer && await _openOffline()) {
            // Timeout: open with the saved profile.
          } else {
            _startupError = e.message;
          }
        } catch (_) {
          // No connection, DNS failure, etc. — keep the token. Open with the
          // saved profile if there is one, otherwise show Retry.
          if (!await _openOffline()) _startupError = _kUnreachable;
        }
      }
    } catch (_) {
      // SharedPreferences or other init failure — safe to ignore, user stays logged out
    } finally {
      _wakingServer = false;
      _loading = false;
      notifyListeners();
    }
  }

  /// Use the profile saved on the phone. False if there is none.
  Future<bool> _openOffline() async {
    final cached = await OfflineCache.loadUser();
    if (cached == null) return false;
    _user = cached;
    _offline = true;
    return true;
  }

  static Future<void> _saveUser(User user) async {
    try {
      await OfflineCache.saveUser(user);
    } catch (_) {
      // Best effort: offline mode just won't have this update.
    }
  }

  /// Try the startup session check again (after a startup error).
  Future<void> retry() async {
    _loading = true;
    _startupError = null;
    notifyListeners();
    await _init();
  }

  /// Null when logged in. A [LoginChallenge] when two-step sign-in is on:
  /// nothing is saved until the code screen calls [completeLogin].
  Future<LoginChallenge?> login(String email, String password) async {
    final result = await ApiClient.login(email: email, password: password);
    switch (result) {
      case LoginSession(:final token, :final user):
        await completeLogin(token, user);
        return null;
      case LoginChallenge():
        return result;
    }
  }

  /// Set a new password with a reset code. Null when signed in (through
  /// [completeLogin], like [login]). A [LoginChallenge] when two-step sign-in
  /// is on: nothing is saved, the code screen finishes the sign-in.
  Future<LoginChallenge?> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final result = await ApiClient.resetPassword(email: email, code: code, newPassword: newPassword);
    switch (result) {
      case LoginSession(:final token, :final user):
        await completeLogin(token, user);
        return null;
      case LoginChallenge():
        return result;
    }
  }

  /// Save the session and show the app (after a login or a sign-in code).
  Future<void> completeLogin(String token, User user) async {
    _session++;
    await ApiClient.saveToken(token);
    _user = user;
    _offline = false;
    await _saveUser(user);
    notifyListeners();
  }

  Future<void> register({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
  }) async {
    final result = await ApiClient.register(
      firstName: firstName,
      lastName: lastName,
      email: email,
      password: password,
    );
    _session++;
    await ApiClient.saveToken(result.token);
    _user = result.user;
    _offline = false;
    await _saveUser(result.user);
    _justRegistered = true;
    notifyListeners();
  }

  Future<void> logout() async {
    _session++;
    await ApiClient.clearToken();
    await OfflineCache.clear();
    _user = null;
    _offline = false;
    _startupError = null;
    notifyListeners();
  }

  Future<void> refreshUser() async {
    final session = _session;
    final me = await ApiClient.getMe();
    if (session != _session) return; // a late answer for the previous session
    _user = me;
    _offline = false;
    await _saveUser(me);
    notifyListeners();
  }

  /// Ignored after logout, and for another account than the signed-in one
  /// (a save or receipt event that finished after the account changed).
  void updateUser(User updated) {
    final current = _user;
    if (current == null || updated.id != current.id) return;
    _user = updated;
    _saveUser(updated);
    notifyListeners();
  }
}
