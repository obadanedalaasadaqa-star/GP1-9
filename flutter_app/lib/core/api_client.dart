import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'constants.dart';
import 'receipt_model.dart';
import 'user_model.dart';

const _kTimeout = Duration(seconds: 15);

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  ApiException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

class ApiClient {
  static const _tokenKey = 'nexus_token';

  // ── Token storage ──────────────────────────────────────────────
  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  static Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  // ── HTTP helpers ───────────────────────────────────────────────
  static Future<Map<String, String>> _headers({bool auth = false}) async {
    final h = {'Content-Type': 'application/json'};
    if (auth) {
      final token = await getToken();
      if (token != null) h['Authorization'] = 'Bearer $token';
    }
    return h;
  }

  static Map<String, dynamic> _parse(http.Response res) {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      // Non-JSON response (e.g. HTML gateway error)
      throw ApiException(
        'Server error (${res.statusCode}) — please try again.',
        statusCode: res.statusCode,
      );
    }
    if (res.statusCode >= 400) {
      throw ApiException(
        body['error'] as String? ?? 'Request failed',
        statusCode: res.statusCode,
      );
    }
    return body;
  }

  // ── Auth ───────────────────────────────────────────────────────
  static Future<({String token, User user})> register({
    required String firstName,
    required String lastName,
    required String phone,
    required String email,
    required String password,
  }) async {
    final res = await http
        .post(
          Uri.parse('${AppConfig.baseUrl}/auth/register'),
          headers: await _headers(),
          body: jsonEncode({
            'firstName': firstName,
            'lastName': lastName,
            'phone': phone,
            'email': email,
            'password': password,
          }),
        )
        .timeout(
          _kTimeout,
          onTimeout: () => throw ApiException('Request timed out.'),
        );
    final data = _parse(res);
    return (
      token: data['token'] as String,
      user: User.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  static Future<({String token, User user})> login({
    required String email,
    required String password,
  }) async {
    final res = await http
        .post(
          Uri.parse('${AppConfig.baseUrl}/auth/login'),
          headers: await _headers(),
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(
          _kTimeout,
          onTimeout: () => throw ApiException('Request timed out.'),
        );
    final data = _parse(res);
    return (
      token: data['token'] as String,
      user: User.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  // ── User ───────────────────────────────────────────────────────
  static Future<User> getMe() async {
    final res = await http
        .get(
          Uri.parse('${AppConfig.baseUrl}/user/me'),
          headers: await _headers(auth: true),
        )
        .timeout(
          _kTimeout,
          onTimeout: () => throw ApiException('Request timed out.'),
        );
    return User.fromJson(_parse(res));
  }

  static Future<User> updateProfile({
    required String firstName,
    required String lastName,
    String? phone,
  }) async {
    final res = await http
        .patch(
          Uri.parse('${AppConfig.baseUrl}/user/me'),
          headers: await _headers(auth: true),
          body: jsonEncode({
            'firstName': firstName,
            'lastName': lastName,
            if (phone != null && phone.isNotEmpty) 'phone': phone,
          }),
        )
        .timeout(
          _kTimeout,
          onTimeout: () => throw ApiException('Request timed out.'),
        );
    return User.fromJson(_parse(res));
  }

  // ── Receipts ───────────────────────────────────────────────────
  static Future<List<Receipt>> getReceipts() async {
    final res = await http
        .get(
          Uri.parse('${AppConfig.baseUrl}/user/receipts'),
          headers: await _headers(auth: true),
        )
        .timeout(
          _kTimeout,
          onTimeout: () => throw ApiException('Request timed out.'),
        );
    final list = jsonDecode(res.body) as List<dynamic>;
    return list
        .map((e) => Receipt.fromJson(e as Map<String, dynamic>))
        .toList();
  }

}
