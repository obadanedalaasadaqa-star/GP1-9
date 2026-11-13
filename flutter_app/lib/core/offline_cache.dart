import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_models.dart';
import 'budget_models.dart';
import 'receipt_model.dart';
import 'stats_model.dart';
import 'user_model.dart';

/// Keeps the signed-in user's profile, receipts, trends, budgets and AI insight/report on the phone, so
/// the app still shows them with no internet. Cleared on logout and when
/// another account signs in, so one account never sees another's data.
class OfflineCache {
  static const _userKey     = 'nexus_cache_user';
  static const _receiptsKey = 'nexus_cache_receipts';
  static const _savedAtKey  = 'nexus_cache_saved_at';
  static const _statsKey        = 'nexus_cache_stats';
  static const _statsSavedAtKey = 'nexus_cache_stats_saved_at';
  static const _insightKey        = 'nexus_cache_insight';
  static const _insightSavedAtKey = 'nexus_cache_insight_saved_at';
  static const _reportKey         = 'nexus_cache_report';
  static const _reportSavedAtKey  = 'nexus_cache_report_saved_at';
  static const _budgetsKey        = 'nexus_cache_budgets';
  static const _budgetsSavedAtKey = 'nexus_cache_budgets_saved_at';

  // Everything that belongs to one account (all but the profile itself).
  static const _accountKeys = [
    _receiptsKey, _savedAtKey, _statsKey, _statsSavedAtKey,
    _insightKey, _insightSavedAtKey, _reportKey, _reportSavedAtKey,
    _budgetsKey, _budgetsSavedAtKey,
  ];

  // ── User ───────────────────────────────────────────────────────
  /// Save the profile. A different account than the cached one wipes the
  /// cached receipts, trends and AI insight/report first.
  static Future<void> saveUser(User user) async {
    final prefs = await SharedPreferences.getInstance();
    final old = _decodeUser(prefs.getString(_userKey));
    if (old != null && old.id != user.id) {
      for (final key in _accountKeys) {
        await prefs.remove(key);
      }
    }
    await prefs.setString(_userKey, jsonEncode(user.toJson()));
  }

  static Future<User?> loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeUser(prefs.getString(_userKey));
  }

  static User? _decodeUser(String? raw) {
    if (raw == null) return null;
    try {
      return User.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null; // old or broken entry: treat as no cache
    }
  }

  // ── Receipts ───────────────────────────────────────────────────
  /// Merge receipts fresh from the server. With a range, the server's answer
  /// is the full truth for [from, to), so cached ones in it are replaced.
  static Future<void> saveReceipts(List<Receipt> fresh,
      {DateTime? from, DateTime? to}) async {
    final prefs = await SharedPreferences.getInstance();
    final byId = {for (final r in _decodeReceipts(prefs.getString(_receiptsKey)) ?? <Receipt>[]) r.id: r};
    if (from != null && to != null) {
      byId.removeWhere((_, r) => _inRange(r, from, to));
    }
    for (final r in fresh) {
      byId[r.id] = r;
    }
    await prefs.setString(
        _receiptsKey, jsonEncode(byId.values.map((r) => r.toJson()).toList()));
    await prefs.setString(_savedAtKey, DateTime.now().toUtc().toIso8601String());
  }

  /// Cached receipts, newest first: those in [from, to), or the latest 50.
  /// Null when nothing was ever saved (so the caller can show an error).
  static Future<List<Receipt>?> loadReceipts({DateTime? from, DateTime? to}) async {
    final prefs = await SharedPreferences.getInstance();
    final all = _decodeReceipts(prefs.getString(_receiptsKey));
    if (all == null) return null;
    final list = (from != null && to != null)
        ? all.where((r) => _inRange(r, from, to)).toList()
        : all.toList();
    list.sort((a, b) => b.date.compareTo(a.date));
    return (from == null || to == null) ? list.take(50).toList() : list;
  }

  /// When receipts were last saved from the server.
  static Future<DateTime?> savedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_savedAtKey);
    return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
  }

  // ── Trends ─────────────────────────────────────────────────────
  /// One slot: the latest stats replace the older ones. Each period keeps
  /// its own from/to, so old stats are still labelled with the right months.
  static Future<void> saveStats(SpendingStats stats) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_statsKey, jsonEncode(stats.toJson()));
    await prefs.setString(_statsSavedAtKey, DateTime.now().toUtc().toIso8601String());
  }

  /// The saved stats, or null when missing or broken.
  static Future<SpendingStats?> loadStats() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_statsKey);
    if (raw == null) return null;
    try {
      return SpendingStats.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// When the stats were last saved from the server.
  static Future<DateTime?> statsSavedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_statsSavedAtKey);
    return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
  }

  // ── AI insight ─────────────────────────────────────────────────
  /// One slot: the latest insight (or "not enough data") replaces the older one.
  static Future<void> saveInsight(Insight insight) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_insightKey, jsonEncode(insight.toJson()));
    await prefs.setString(_insightSavedAtKey, DateTime.now().toUtc().toIso8601String());
  }

  /// The saved insight, or null when missing or broken.
  static Future<Insight?> loadInsight() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_insightKey);
    if (raw == null) return null;
    try {
      return Insight.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<DateTime?> insightSavedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_insightSavedAtKey);
    return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
  }

  // ── AI report ──────────────────────────────────────────────────
  /// One slot: the last report loaded, with the request key it belongs to.
  static Future<void> saveReport(String key, SpendingReport report) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_reportKey, jsonEncode({'key': key, 'report': report.toJson()}));
    await prefs.setString(_reportSavedAtKey, DateTime.now().toUtc().toIso8601String());
  }

  /// The saved report for [key], or null when missing, broken or for another period.
  static Future<SpendingReport?> loadReport(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_reportKey);
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['key'] != key) return null;
      return SpendingReport.fromJson(data['report'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<DateTime?> reportSavedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_reportSavedAtKey);
    return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
  }

  // ── Budgets ────────────────────────────────────────────────────
  /// One slot: the latest budget list. It keeps its month, so callers can
  /// tell a list from last month apart ([BudgetList.isMonthOf]).
  static Future<void> saveBudgets(BudgetList list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_budgetsKey, jsonEncode(list.toJson()));
    await prefs.setString(_budgetsSavedAtKey, DateTime.now().toUtc().toIso8601String());
  }

  /// The saved budget list, or null when missing or broken.
  static Future<BudgetList?> loadBudgets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_budgetsKey);
    if (raw == null) return null;
    try {
      return BudgetList.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<DateTime?> budgetsSavedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_budgetsSavedAtKey);
    return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
    for (final key in _accountKeys) {
      await prefs.remove(key);
    }
  }

  static bool _inRange(Receipt r, DateTime from, DateTime to) =>
      !r.date.isBefore(from) && r.date.isBefore(to);

  static List<Receipt>? _decodeReceipts(String? raw) {
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((e) => Receipt.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }
}
