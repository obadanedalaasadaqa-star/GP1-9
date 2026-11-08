import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'receipt_model.dart';
import 'user_model.dart';

/// Keeps the signed-in user's profile and receipts on the phone, so the app
/// still shows them with no internet. Cleared on logout and when another
/// account signs in, so one account never sees another's receipts.
class OfflineCache {
  static const _userKey     = 'nexus_cache_user';
  static const _receiptsKey = 'nexus_cache_receipts';
  static const _savedAtKey  = 'nexus_cache_saved_at';

  // ── User ───────────────────────────────────────────────────────
  /// Save the profile. A different account than the cached one wipes the
  /// cached receipts first.
  static Future<void> saveUser(User user) async {
    final prefs = await SharedPreferences.getInstance();
    final old = _decodeUser(prefs.getString(_userKey));
    if (old != null && old.id != user.id) {
      await prefs.remove(_receiptsKey);
      await prefs.remove(_savedAtKey);
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

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
    await prefs.remove(_receiptsKey);
    await prefs.remove(_savedAtKey);
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
