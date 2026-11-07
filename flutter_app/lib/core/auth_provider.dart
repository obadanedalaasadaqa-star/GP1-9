import 'package:flutter/material.dart';
import 'api_client.dart';
import 'user_model.dart';

class AuthProvider extends ChangeNotifier {
  User? _user;
  bool _loading = true;

  User? get user => _user;
  bool get loading => _loading;
  bool get isLoggedIn => _user != null;

  AuthProvider() {
    _init();
  }

  Future<void> _init() async {
    try {
      final token = await ApiClient.getToken();
      if (token != null) {
        try {
          _user = await ApiClient.getMe();
        } catch (_) {
          await ApiClient.clearToken();
        }
      }
    } catch (_) {
      // SharedPreferences or other init failure — safe to ignore, user stays logged out
    } finally {
      _loading = false;
      notifyListeners();
    }
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
    notifyListeners();
  }

  Future<void> logout() async {
    await ApiClient.clearToken();
    _user = null;
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
