import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'biometric_service.dart';
import 'secure_store.dart';

/// The only code that knows where the session token lives.
///
/// - **Face ID off:** the plain Keychain item.
/// - **Face ID on:** the Face ID protected item, and nothing else (S2). The
///   token is in memory only after a Face ID match ([unlock]).
/// - **Older versions** kept it in SharedPreferences: it is copied to the
///   Keychain, read back, and only then removed (S4).
///
/// Every flag is loaded once (on first use) and kept in memory, so [isLocked]
/// and [lock] are synchronous (S8).
class TokenStore {
  TokenStore._();

  static const _legacyKey = 'nexus_token';
  static const _bioUserKey = 'nexus_bio_user';
  static const _markerKey = 'nexus_bio_token_present';
  static const _readyKey = 'nexus_keychain_ready';

  static SecureStore _store = KeychainSecureStore();
  static BiometricService _biometrics = LocalAuthBiometricService();

  /// Face ID checks for [AuthProvider] (swapped in tests).
  static BiometricService get biometrics => _biometrics;

  @visibleForTesting
  static SecureStore get store => _store;

  // The token requests use. Null while locked or signed out.
  static String? _memory;
  // The last token loaded or saved, kept while locked. Only [rotate] reads it.
  static String? _lastKnown;
  // Mirrors of nexus_bio_user and nexus_bio_token_present.
  static String? _bioUser;
  static bool _markerSet = false;
  // Re-locked after time away (S23). Cleared only by a successful unlock(),
  // saveSession() and clearToken().
  static bool _appLocked = false;
  // The plain item couldn't be read this run (X19b): signed out.
  static bool _plainBroken = false;
  // Face ID off and the plain item read back empty: no need to ask the
  // Keychain again until a token is saved.
  static bool _plainEmpty = false;
  // +1 on every saveSession / clearToken: an unlock that finishes after one
  // of those is dropped.
  static int _generation = 0;
  static Future<void>? _loading;

  /// Id of the user who turned Face ID on for this phone (kept on sign-out).
  static String? get bioUser => _bioUser;

  /// True when a request must not go out: re-locked, or a Face ID protected
  /// token exists and isn't unlocked yet.
  static bool get isLocked => _appLocked || (_bioUser != null && _markerSet && _memory == null);

  /// Loads the flags and runs the start-up clean-up once. Safe to call again.
  static Future<void> load() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(_legacyKey);
      _bioUser = prefs.getString(_bioUserKey);
      _markerSet = prefs.getBool(_markerKey) ?? false;

      // S5: a fresh install (no flag and no legacy token) may still find the
      // Keychain items of an earlier install. Wipe them before any read.
      if (prefs.getBool(_readyKey) != true) {
        var ok = true;
        if (legacy == null) {
          try {
            await _store.wipeAll();
          } catch (_) {
            ok = false; // try again next start
          }
          await prefs.remove(_markerKey);
          await prefs.remove(_bioUserKey);
          _bioUser = null;
          _markerSet = false;
        }
        if (ok) await prefs.setBool(_readyKey, true);
      }

      if (_bioUser != null) {
        // S2: Face ID is on, so a plain copy must not exist. Never use one.
        try {
          await _store.deletePlain();
        } catch (_) {}
        if (legacy != null) await prefs.remove(_legacyKey);
        _memory = null;
      } else {
        _memory = await _loadPlain(prefs, legacy);
      }
      _lastKnown = _memory;
    } catch (_) {
      // SharedPreferences failed: signed out for this run.
    }
  }

  /// The plain item, or the legacy token migrated into it.
  static Future<String?> _loadPlain(SharedPreferences prefs, String? legacy) async {
    final String? plain;
    try {
      plain = await _store.readPlain();
    } catch (_) {
      // X19b: unreadable (for example an Android backup restored without its
      // key). Signed out; the next sign-in's write replaces it.
      _plainBroken = true;
      return null;
    }
    if (plain != null) {
      if (legacy != null) await prefs.remove(_legacyKey);
      return plain;
    }
    if (legacy == null) return null;
    // S4: copy, read back, and only then remove. On any failure keep using
    // the old copy and try again next start.
    try {
      await _store.writePlain(legacy);
      if (await _store.readPlain() == legacy) await prefs.remove(_legacyKey);
    } catch (_) {}
    return legacy;
  }

  /// The token for requests. Never reads the protected item (no prompt), and
  /// with Face ID on never falls back to a plain copy (S2).
  static Future<String?> getToken() async {
    await load();
    if (_appLocked) return null;
    if (_memory != null || _bioUser != null || _plainBroken || _plainEmpty) return _memory;
    // Face ID off and nothing in memory: a token saved since start-up.
    try {
      final prefs = await SharedPreferences.getInstance();
      _memory = await _loadPlain(prefs, prefs.getString(_legacyKey));
      _lastKnown ??= _memory;
      _plainEmpty = _memory == null && !_plainBroken;
    } catch (_) {}
    return _memory;
  }

  /// A new session (sign-in, sign-in code, reset, register).
  static Future<void> saveSession(String token) async {
    await load();
    _generation++;
    _memory = _lastKnown = token;
    _appLocked = false;
    _plainBroken = _plainEmpty = false;
    await _persist(token);
  }

  /// A rotated token from the server (password, email or two-step change).
  /// Saved only if [before] is still the last known token (S20): a sign-out
  /// or another sign-in meanwhile wins. Never unlocks the app.
  static Future<void> rotate(String token, {required String? before}) async {
    await load();
    if (before == null || _lastKnown != before) return;
    final locked = isLocked;
    _lastKnown = token;
    if (!locked) _memory = token;
    await _persist(token);
  }

  static Future<void> _persist(String token) async {
    final prefs = await SharedPreferences.getInstance();
    if (_bioUser != null) {
      try {
        await _store.writeProtected(token);
        await _setMarker(prefs, true); // only after a write that worked (S22)
      } catch (_) {
        // S22: memory only for this run. Never a plain copy. The next cold
        // start is "signed out", and the next password sign-in tries again.
        await _setMarker(prefs, false);
      }
      try {
        await _store.deletePlain();
      } catch (_) {}
    } else {
      try {
        await _store.writePlain(token);
      } catch (_) {
        // Memory only for this run; the next start asks for the password.
      }
      try {
        await _store.deleteProtected();
      } catch (_) {}
      await _setMarker(prefs, false);
    }
    await prefs.remove(_legacyKey);
  }

  /// Sign-out, a refused token, or a session the server ended. Keeps
  /// [bioUser] (Q8): the same user's next password sign-in is protected again.
  static Future<void> clearToken() async {
    await load();
    _generation++;
    _memory = _lastKnown = null;
    _appLocked = false;
    try {
      await _store.deletePlain();
    } catch (_) {}
    try {
      await _store.deleteProtected();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await _setMarker(prefs, false);
    await prefs.remove(_legacyKey);
  }

  /// Turn Face ID on for [userId] (S16 order). Throws, with Face ID still
  /// off and the plain item untouched, if the protected write fails (S22).
  static Future<void> enableProtection(String userId) async {
    await load();
    final token = _memory;
    if (token == null) throw StateError('No session to protect');
    await _store.writeProtected(token);
    if (!await _store.protectedExists()) {
      try {
        await _store.deleteProtected();
      } catch (_) {}
      throw StateError('Protected write not found');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bioUserKey, userId);
    _bioUser = userId;
    await _setMarker(prefs, true);
    try {
      await _store.deletePlain();
    } catch (_) {
      // The next start's S2 clean-up deletes it (X7).
    }
  }

  /// Turn Face ID off: the token goes back to the plain item. The caller
  /// asks for Face ID first (S19). Throws, with Face ID still on, if the
  /// plain write fails.
  static Future<void> disableProtection() async {
    await load();
    final token = _memory;
    if (token == null) throw StateError('No session');
    await _store.writePlain(token);
    await forgetProtection();
  }

  /// Face ID can't be used any more (faces changed, turned off, not set up):
  /// delete the protected item and forget the choice for this phone.
  static Future<void> forgetProtection() async {
    await load();
    try {
      await _store.deleteProtected();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await _setMarker(prefs, false);
    await prefs.remove(_bioUserKey);
    _bioUser = null;
  }

  /// Re-lock after time away. Synchronous on purpose (S8): the socket's
  /// lifecycle handler, which runs right after, already sees "locked".
  static void lock() {
    _appLocked = true;
    _memory = null;
  }

  /// Read the protected item (iOS shows the Face ID prompt). Only a match
  /// puts a token in memory (S3); nothing else falls back to another store.
  static Future<ProtectedRead> unlock() async {
    await load();
    final generation = _generation;
    final before = _lastKnown;
    final read = await _store.readProtected();
    if (generation != _generation) {
      // Signed in or out meanwhile: this answer belongs to the old session.
      return const ProtectedRead(ProtectedStatus.cancelled);
    }
    if (read.status == ProtectedStatus.success) {
      // A rotation (password change) saved a newer token while the prompt
      // was up. Its write ran after this read, so the read has the old one.
      final rotated = _lastKnown != null && _lastKnown != before;
      _memory = _lastKnown = rotated ? _lastKnown : read.token;
      _appLocked = false;
    }
    return read;
  }

  static Future<void> _setMarker(SharedPreferences prefs, bool on) async {
    _markerSet = on;
    if (on) {
      await prefs.setBool(_markerKey, true);
    } else {
      await prefs.remove(_markerKey);
    }
  }

  /// Fresh state and fakes for each test (`test/flutter_test_config.dart`).
  @visibleForTesting
  static void resetForTest({required SecureStore store, required BiometricService biometrics}) {
    _store = store;
    _biometrics = biometrics;
    _memory = _lastKnown = _bioUser = null;
    _markerSet = _appLocked = _plainBroken = _plainEmpty = false;
    _generation = 0;
    _loading = null;
  }
}
