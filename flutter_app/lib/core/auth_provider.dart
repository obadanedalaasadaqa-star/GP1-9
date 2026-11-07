import 'package:flutter/material.dart';
import 'api_client.dart';
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

  User? get user => _user;
  bool get loading => _loading;
  bool get isLoggedIn => _user != null;

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
      final token = await ApiClient.getToken();
      if (token != null) {
        _wakingServer = true;
        notifyListeners();
        try {
          _user = await ApiClient.getMe(timeout: _kStartupTimeout);
        } on ApiException catch (e) {
          // Only a rejected token (401) or a deleted account (JSON 404 from our
          // server) logs the user out. A non-JSON 404 means the host itself is
          // missing/suspended, so keep the token and show Retry.
          if (e.statusCode == 401 || (e.statusCode == 404 && e.fromServer)) {
            await ApiClient.clearToken();
          } else {
            _startupError = e.message;
          }
        } catch (_) {
          // No connection, DNS failure, etc. — keep the token so Retry works
          _startupError = _kUnreachable;
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

  /// Try the startup session check again (after a startup error).
  Future<void> retry() async {
    _loading = true;
    _startupError = null;
    notifyListeners();
    await _init();
  }

  Future<void> login(String email, String password) async {
    final result = await ApiClient.login(email: email, password: password);
    await ApiClient.saveToken(result.token);
    _user = result.user;
    notifyListeners();
  }

  Future<void> register({
    required String firstName,
    required String lastName,
    required String phone,
    required String email,
    required String password,
  }) async {
    final result = await ApiClient.register(
      firstName: firstName,
      lastName: lastName,
      phone: phone,
      email: email,
      password: password,
    );
    await ApiClient.saveToken(result.token);
    _user = result.user;
    _justRegistered = true;
    notifyListeners();
  }

  Future<void> logout() async {
    await ApiClient.clearToken();
    _user = null;
    _startupError = null;
    notifyListeners();
  }

  Future<void> refreshUser() async {
    _user = await ApiClient.getMe();
    notifyListeners();
  }

  void updateUser(User updated) {
    _user = updated;
    notifyListeners();
  }
}
