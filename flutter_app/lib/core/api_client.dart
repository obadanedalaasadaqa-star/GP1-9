import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_models.dart';
import 'constants.dart';
import 'offline_cache.dart';
import 'receipt_model.dart';
import 'stats_model.dart';
import 'user_model.dart';

const _kTimeout = Duration(seconds: 15);
const _kUnreachable = "Can't reach the Nexus server. Check your connection and try again.";

// AI calls can take a while (the model thinks, the chat calls tools).
const _kInsightTimeout = Duration(seconds: 40);
const _kInsightSlow = 'The AI is taking a while. Try again in a moment.';
const _kChatTimeout = Duration(seconds: 60);
const _kChatSlow = 'The AI is taking a while. Try again.';
const _kReportTimeout = Duration(seconds: 60);
const _kReportSlow = 'The report is taking a while. Try again.';
// The email may still arrive after a timeout, so don't invite a resend.
const _kEmailSlow = 'Sending is taking a while. Check your inbox in a minute before trying again.';

/// Receipts plus where they came from. [offline]: the server couldn't be
/// reached, so these are the copies saved on the phone (from [savedAt]).
typedef ReceiptsResult = ({List<Receipt> receipts, bool offline, DateTime? savedAt});

/// Trends stats plus where they came from (same rules as [ReceiptsResult]).
typedef StatsResult = ({SpendingStats stats, bool offline, DateTime? savedAt});

/// The AI insight plus where it came from. [offline]: the server couldn't be
/// reached. [stale]: the server was too slow (or failed), so the saved insight
/// is shown. Both come with [savedAt].
typedef InsightResult = ({Insight insight, bool offline, bool stale, DateTime? savedAt});

/// A spending report plus where it came from (same rules as [ReceiptsResult]).
typedef ReportResult = ({SpendingReport report, bool offline, DateTime? savedAt});

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

  // ── Stats (Trends) ─────────────────────────────────────────────
  /// Spending totals for each period between neighbouring [bounds]
  /// ([from, to), the same rule as [getReceipts]).
  static Future<SpendingStats> getStats(List<DateTime> bounds) async {
    final uri = Uri.parse('${AppConfig.baseUrl}/user/stats').replace(
      queryParameters: {
        'bounds': bounds.map((b) => b.toUtc().toIso8601String()).join(','),
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
    return SpendingStats.fromJson(_parse(res));
  }

  /// [getStats] that saves what it gets on the phone, and falls back to the
  /// saved stats when the server can't be reached. A real answer from our
  /// server (401, 400, ...) is still thrown, never hidden by the cache.
  static Future<StatsResult> loadStats(List<DateTime> bounds) async {
    try {
      final stats = await getStats(bounds);
      try {
        await OfflineCache.saveStats(stats);
      } catch (_) {
        // Saving is best effort: the fresh stats are still shown.
      }
      return (stats: stats, offline: false, savedAt: null);
    } on ApiException catch (e) {
      if (e.fromServer) rethrow;
      return _statsFromCache();
    } catch (_) {
      // No internet, DNS failure, connection reset, ...
      return _statsFromCache();
    }
  }

  static Future<StatsResult> _statsFromCache() async {
    final cached = await OfflineCache.loadStats();
    if (cached == null) throw ApiException(_kUnreachable);
    return (stats: cached, offline: true, savedAt: await OfflineCache.statsSavedAt());
  }

  // ── AI insight ─────────────────────────────────────────────────
  /// The AI summary + tip for the months between [bounds] (the same bounds as
  /// Trends). A timeout throws ApiException 408 ("taking a while").
  static Future<Insight> getInsight(List<DateTime> bounds,
      {Duration timeout = _kInsightTimeout}) async {
    final uri = Uri.parse('${AppConfig.baseUrl}/ai/insight').replace(
      queryParameters: {
        'bounds': bounds.map((b) => b.toUtc().toIso8601String()).join(','),
      },
    );
    final res = await http
        .get(uri, headers: await _headers(auth: true))
        .timeout(timeout, onTimeout: () => throw ApiException(_kInsightSlow, statusCode: 408));
    return Insight.fromJson(_parse(res));
  }

  /// [getInsight] that saves what it gets, and falls back to the saved
  /// insight when the server can't be reached ([offline]) or is too slow
  /// ([stale]). A JSON answer from our server (401, 502, ...) is still thrown.
  static Future<InsightResult> loadInsight(List<DateTime> bounds,
      {Duration timeout = _kInsightTimeout}) async {
    try {
      final insight = await getInsight(bounds, timeout: timeout);
      try {
        await OfflineCache.saveInsight(insight);
      } catch (_) {
        // Saving is best effort.
      }
      return (insight: insight, offline: false, stale: false, savedAt: null);
    } on ApiException catch (e) {
      if (e.fromServer) rethrow;
      if (e.statusCode == 408) {
        // Slow server, not offline: the saved insight, or the 408 itself.
        final cached = await OfflineCache.loadInsight();
        if (cached == null) rethrow;
        return (insight: cached, offline: false, stale: true, savedAt: await OfflineCache.insightSavedAt());
      }
      return _insightFromCache();
    } catch (_) {
      return _insightFromCache();
    }
  }

  static Future<InsightResult> _insightFromCache() async {
    final cached = await OfflineCache.loadInsight();
    if (cached == null) throw ApiException(_kUnreachable);
    return (insight: cached, offline: true, stale: false, savedAt: await OfflineCache.insightSavedAt());
  }

  // ── Ask AI ─────────────────────────────────────────────────────
  /// Ask a question about the user's own spending. [history]: earlier
  /// completed turns, sent as plain text. No offline cache for chat.
  static Future<({String answer, int? remainingToday})> askAi(
      String question, List<ChatMessage> history,
      {Duration timeout = _kChatTimeout}) async {
    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('${AppConfig.baseUrl}/ai/chat'),
            headers: await _headers(auth: true),
            body: jsonEncode({
              'question': question,
              'history': history.map((m) => m.toHistoryJson()).toList(),
              'tzOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
            }),
          )
          .timeout(timeout, onTimeout: () => throw ApiException(_kChatSlow, statusCode: 408));
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException(_kUnreachable);
    }
    final data = _parse(res);
    return (
      answer: data['answer'] as String,
      remainingToday: (data['remainingToday'] as num?)?.toInt(),
    );
  }

  // ── Reports ────────────────────────────────────────────────────
  static Future<SpendingReport> getReport(ReportRequest r,
      {Duration timeout = _kReportTimeout}) async {
    final uri = Uri.parse('${AppConfig.baseUrl}/ai/report').replace(
      queryParameters: r.toQuery(DateTime.now().timeZoneOffset.inMinutes),
    );
    final res = await http
        .get(uri, headers: await _headers(auth: true))
        .timeout(timeout, onTimeout: () => throw ApiException(_kReportSlow, statusCode: 408));
    return SpendingReport.fromJson(_parse(res));
  }

  /// [getReport] that saves what it gets under the request's key, and falls
  /// back to the saved report only when it is for the same period.
  static Future<ReportResult> loadReport(ReportRequest r,
      {Duration timeout = _kReportTimeout}) async {
    try {
      final report = await getReport(r, timeout: timeout);
      try {
        await OfflineCache.saveReport(r.cacheKey, report);
      } catch (_) {
        // Saving is best effort.
      }
      return (report: report, offline: false, savedAt: null);
    } on ApiException catch (e) {
      if (e.fromServer) rethrow;
      return _reportFromCache(r);
    } catch (_) {
      return _reportFromCache(r);
    }
  }

  static Future<ReportResult> _reportFromCache(ReportRequest r) async {
    final cached = await OfflineCache.loadReport(r.cacheKey);
    if (cached == null) throw ApiException(_kUnreachable);
    return (report: cached, offline: true, savedAt: await OfflineCache.reportSavedAt());
  }

  /// How long [emailReport] waits: the report timeout, so a slow server
  /// (cold start) is not mistaken for a failure and the email sent twice.
  static const Duration emailReportTimeout = _kReportTimeout;

  /// Email the report to the verified address. Returns the server's message.
  static Future<String> emailReport(ReportRequest r, {Duration timeout = emailReportTimeout}) async {
    final query = r.toQuery(DateTime.now().timeZoneOffset.inMinutes);
    final res = await http
        .post(
          Uri.parse('${AppConfig.baseUrl}/ai/report/email'),
          headers: await _headers(auth: true),
          body: jsonEncode({
            ...query,
            'tzOffsetMinutes': int.parse(query['tzOffsetMinutes']!),
          }),
        )
        .timeout(
          timeout,
          onTimeout: () => throw ApiException(_kEmailSlow),
        );
    return _parse(res)['message'] as String;
  }
}
