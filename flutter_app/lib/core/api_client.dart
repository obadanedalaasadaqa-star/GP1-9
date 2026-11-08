import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'constants.dart';
import 'offline_cache.dart';
import 'receipt_model.dart';
import 'user_model.dart';

const _kTimeout = Duration(seconds: 15);
const _kUnreachable = "Can't reach the Nexus server. Check your connection and try again.";

/// Receipts plus where they came from. [offline]: the server couldn't be
/// reached, so these are the copies saved on the phone (from [savedAt]).
typedef ReceiptsResult = ({List<Receipt> receipts, bool offline, DateTime? savedAt});

class ApiException implements Exception {
  final String message;
  final int? statusCode;

  /// True when our server answered with a JSON `{ "error": ... }` body.
  /// False for timeouts and non-JSON replies (e.g. an HTML 404 from the host).
  final bool fromServer;
  ApiException(this.message, {this.statusCode, this.fromServer = false});
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
      final error = body['error'];
      throw ApiException(
        error is String ? error : 'Request failed',
        statusCode: res.statusCode,
        fromServer: error is String,
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
          onTimeout: () => throw ApiException('Server is waking up or unreachable. Please try again.'),
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
          onTimeout: () => throw ApiException('Server is waking up or unreachable. Please try again.'),
        );
    final data = _parse(res);
    return (
      token: data['token'] as String,
      user: User.fromJson(data['user'] as Map<String, dynamic>),
    );
  }

  // ── User ───────────────────────────────────────────────────────
  /// [timeout] is longer for the startup call, while a sleeping server wakes up.
  static Future<User> getMe({Duration timeout = _kTimeout}) async {
    final res = await http
        .get(
          Uri.parse('${AppConfig.baseUrl}/user/me'),
          headers: await _headers(auth: true),
        )
        .timeout(
          timeout,
          onTimeout: () => throw ApiException('Server is waking up or unreachable. Please try again.'),
        );
    return User.fromJson(_parse(res));
  }

  static Future<User> updateProfile({
    required String firstName,
    required String lastName,
    String? phone,
    String? email,
    String? currentPassword,
  }) async {
    final res = await http
        .patch(
          Uri.parse('${AppConfig.baseUrl}/user/me'),
          headers: await _headers(auth: true),
          body: jsonEncode({
            'firstName': firstName,
            'lastName': lastName,
            if (phone != null && phone.isNotEmpty) 'phone': phone,
            if (email != null && email.isNotEmpty) 'email': email,
            if (currentPassword != null && currentPassword.isNotEmpty)
              'currentPassword': currentPassword,
          }),
        )
        .timeout(
          _kTimeout,
          onTimeout: () => throw ApiException('Server is waking up or unreachable. Please try again.'),
        );
    return User.fromJson(_parse(res));
  }

  /// Ask the backend to email a new verification code.
  /// Throws ApiException (statusCode 429) if one was sent under a minute ago.
  static Future<void> sendEmailCode() async {
    final res = await http
        .post(
          Uri.parse('${AppConfig.baseUrl}/user/email/send-code'),
          headers: await _headers(auth: true),
        )
        .timeout(
          _kTimeout,
          onTimeout: () => throw ApiException('Server is waking up or unreachable. Please try again.'),
        );
    _parse(res);
  }

  static Future<User> verifyEmail(String code) async {
    final res = await http
        .post(
          Uri.parse('${AppConfig.baseUrl}/user/email/verify'),
          headers: await _headers(auth: true),
          body: jsonEncode({'code': code}),
        )
        .timeout(
          _kTimeout,
          onTimeout: () => throw ApiException('Server is waking up or unreachable. Please try again.'),
        );
    return User.fromJson(_parse(res));
  }

  static Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final res = await http
        .patch(
          Uri.parse('${AppConfig.baseUrl}/user/password'),
          headers: await _headers(auth: true),
          body: jsonEncode({
            'currentPassword': currentPassword,
            'newPassword': newPassword,
          }),
        )
        .timeout(
          _kTimeout,
          onTimeout: () => throw ApiException('Server is waking up or unreachable. Please try again.'),
        );
    _parse(res);
  }

  // ── Receipts ───────────────────────────────────────────────────
  /// Latest 50 receipts, or all receipts in [from, to) when a range is given.
  static Future<List<Receipt>> getReceipts({DateTime? from, DateTime? to}) async {
    final uri = Uri.parse('${AppConfig.baseUrl}/user/receipts').replace(
      queryParameters: {
        if (from != null) 'from': from.toUtc().toIso8601String(),
        if (to != null) 'to': to.toUtc().toIso8601String(),
      },
    );
    final res = await http
        .get(
          uri,
          headers: await _headers(auth: true),
        )
        .timeout(
          _kTimeout,
          onTimeout: () => throw ApiException('Server is waking up or unreachable. Please try again.'),
        );
    if (res.statusCode >= 400) _parse(res); // throws ApiException with the server's error
    final list = jsonDecode(res.body) as List<dynamic>;
    return list
        .map((e) => Receipt.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// [getReceipts] that saves what it gets on the phone, and falls back to
  /// the saved copies when the server can't be reached. A real answer from
  /// our server (401, 400, ...) is still thrown, never hidden by the cache.
  static Future<ReceiptsResult> loadReceipts({DateTime? from, DateTime? to}) async {
    try {
      final receipts = await getReceipts(from: from, to: to);
      try {
        await OfflineCache.saveReceipts(receipts, from: from, to: to);
      } catch (_) {
        // Saving is best effort: the fresh list is still shown.
      }
      return (receipts: receipts, offline: false, savedAt: null);
    } on ApiException catch (e) {
      if (e.fromServer) rethrow;
      return _fromCache(from, to);
    } catch (_) {
      // No internet, DNS failure, connection reset, ...
      return _fromCache(from, to);
    }
  }

  static Future<ReceiptsResult> _fromCache(DateTime? from, DateTime? to) async {
    final cached = await OfflineCache.loadReceipts(from: from, to: to);
    if (cached == null) throw ApiException(_kUnreachable);
    return (receipts: cached, offline: true, savedAt: await OfflineCache.savedAt());
  }

}
