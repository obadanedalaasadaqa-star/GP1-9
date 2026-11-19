import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'biometric_service.dart';
import 'google_auth_service.dart';
import 'google_sign_in_result.dart';
import 'login_challenge.dart';
import 'offline_cache.dart';
import 'secure_store.dart';
import 'token_store.dart';
import 'user_model.dart';

/// Startup /user/me timeout: a free Render server can take about a minute to wake up.
const _kStartupTimeout = Duration(seconds: 60);
const _kUnreachable = "Can't reach the Nexus server. Check your connection and try again.";
// After a Face ID unlock the pill stays busy this long before the
// waking-server splash takes over.
const _kUnlockSplashDelay = Duration(seconds: 2);
const _kDeclinedKey = 'nexus_bio_declined';
// The Google token held for the "Connect Google" password step (S29).
const _kGoogleHoldFor = Duration(minutes: 10);

/// The amber notice on the sign-in tab after Face ID couldn't be used.
enum BiometricNotice { sessionEnded, invalidated, lockout, notAvailable, notEnrolled, error }

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

  // Face ID (see the lock state table in GP2 phase 11, plan 4.3).
  bool _biometricLocked = false;
  bool _appLocked = false;
  bool _autoPromptPending = false;
  bool _offerBiometrics = false;
  bool _unlocking = false;
  BiometricNotice? _biometricNotice;
  BiometricAvailability _availability = BiometricAvailability.notIos;

  // Continue with Google. The pending token lives only in this field, only
  // between a "password needed" answer and the password step (S29).
  final GoogleAuthService _google;
  ({String idToken, String email, DateTime at})? _pendingGoogle;

  /// The clock for the 10-minute hold (tests move it).
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

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

  // ── Face ID state ──────────────────────────────────────────────

  /// Cold start with a Face ID protected token and no unlock yet. [user] is
  /// null and the sign-in screen shows the Face ID pill (S6).
  bool get biometricLocked => _biometricLocked;

  /// Re-locked after time away: [user] stays in memory, the shell stays
  /// mounted under the lock overlay.
  bool get appLocked => _appLocked;

  /// Either lock: the shell's live handlers ignore everything meanwhile.
  bool get locked => _biometricLocked || _appLocked;

  /// The sign-in tab shows the Face ID pill, the outline password button and
  /// no "New here?" link. iOS only (S21).
  bool get showFacePill => _biometricLocked && isIosPlatform;

  /// A Face ID prompt (or the session check after it) is running.
  bool get unlocking => _unlocking;

  /// The amber notice on the sign-in tab (cleared on edit, tab switch, submit).
  BiometricNotice? get biometricNotice => _biometricNotice;

  /// Face ID is on for the signed-in user on this phone.
  bool get biometricsOn => _user != null && TokenStore.bioUser == _user!.id;

  /// Whether Face ID can be used now, and if not, why. Refreshed on resume
  /// and when Profile builds.
  BiometricAvailability get biometricAvailability => _availability;

  /// "Face ID", or "Touch ID" on Touch ID phones.
  String get biometricName => _availability.name;

  /// True once per locked cold start (not after a lockout), so the sign-in
  /// tab prompts by itself exactly once, whatever rebuilds or tab switches.
  bool consumeAutoPrompt() {
    final v = _autoPromptPending;
    _autoPromptPending = false;
    return v;
  }

  /// True once after a password sign-in when Face ID could be offered.
  bool consumeBiometricOffer() {
    final v = _offerBiometrics;
    _offerBiometrics = false;
    return v;
  }

  void clearBiometricNotice() {
    if (_biometricNotice == null) return;
    _biometricNotice = null;
    notifyListeners();
  }

  /// [google]: Continue with Google (the plugin by default; tests pass a fake).
  AuthProvider({GoogleAuthService? google}) : _google = google ?? defaultGoogleAuthService() {
    _loadGoogle();
    _init();
  }

  // ── Continue with Google ───────────────────────────────────────

  /// The Google button shows: iOS with a real client ID in the build.
  bool get googleAvailable => _google.available;

  /// Reads the client ID once, off the start-up path.
  Future<void> _loadGoogle() async {
    try {
      await _google.load();
    } catch (_) {
      return;
    }
    if (_google.available) notifyListeners();
  }

  /// Google's sheet, then the Nexus server. Null when signed in (through
  /// [completeLogin], like a password sign-in), when the sheet was cancelled,
  /// or when Google isn't available. A [GoogleChallenge] (two-step sign-in
  /// on) or [GooglePasswordNeeded] (the link sheet) otherwise. Throws
  /// [GoogleAuthFailure] when Google's sheet failed, [ApiException] for the
  /// server's refusals.
  Future<GoogleSignInResult?> signInWithGoogle() async {
    if (!googleAvailable) return null;
    _pendingGoogle = null;
    final id = await _google.signIn();
    switch (id) {
      case GoogleCancelled():
        return null;
      case GoogleFailed(:final kind):
        throw GoogleAuthFailure(kind);
      case GoogleIdToken(:final idToken, :final email):
        return _sendGoogle(idToken, email: email);
    }
  }

  /// The link sheet's "Connect Google": the held token again, with the Nexus
  /// password. [GoogleTokenExpired] without a request when the token is gone
  /// or older than 10 minutes. The password is never kept.
  Future<GoogleSignInResult?> continueGoogleWithPassword(String password) async {
    final held = _pendingGoogle;
    if (held == null || clock().difference(held.at) >= _kGoogleHoldFor) {
      _pendingGoogle = null;
      return const GoogleTokenExpired();
    }
    return _sendGoogle(held.idToken, email: held.email, password: password);
  }

  /// Cancel, swipe-down or Forgot password in the link sheet.
  void dropPendingGoogle() => _pendingGoogle = null;

  Future<GoogleSignInResult?> _sendGoogle(String idToken, {required String email, String? password}) async {
    final GoogleSignInResult result;
    try {
      result = await ApiClient.googleSignIn(idToken, password: password, email: email);
    } on ApiException catch (e) {
      // No connection or 429 keep the link sheet open (and the token, for a
      // retry); every other refusal ends the attempt.
      if (e.fromServer && e.statusCode != 429) _pendingGoogle = null;
      rethrow;
    }
    switch (result) {
      case GoogleSession(:final token, :final user, :final created):
        _pendingGoogle = null;
        // S30: a new account never inherits Face ID (as register).
        if (created) await TokenStore.forgetProtection();
        await completeLogin(token, user);
        return null;
      case GoogleChallenge():
        _pendingGoogle = null;
        return result;
      case GooglePasswordNeeded():
        // Held from the first answer; a wrong password keeps the same one.
        _pendingGoogle ??= (idToken: idToken, email: result.email.isEmpty ? email : result.email, at: clock());
        return result;
      case GoogleTokenExpired():
        _pendingGoogle = null;
        return result;
    }
  }

  Future<void> _init() async {
    try {
      final session = _session;
      await TokenStore.load();
      // Face ID on but surely unusable (not set up, no passcode): forget it,
      // so the user is never stuck. Anything less certain (turned off for
      // Nexus, which -6 also says when Face ID is briefly unavailable, or a
      // state the phone didn't report) keeps the session: the Keychain read
      // decides, and _refine forgets it only if that read fails.
      final a = await refreshBiometricAvailability(notify: false);
      if (TokenStore.bioUser != null && isIosPlatform) {
        if (a.reason == BiometricReason.notEnrolled || a.reason == BiometricReason.noPasscode) {
          final wasLocked = TokenStore.isLocked;
          await TokenStore.forgetProtection();
          if (wasLocked) _biometricNotice = _noticeFor(a.reason);
        }
      }
      // S6: locked cold start. No request, no saved profile, no socket.
      // isLocked (not just the flags), so a Retry after an unlock goes
      // straight to the session check instead of asking for Face ID again.
      if (TokenStore.isLocked) {
        _biometricLocked = true;
        if (_availability.reason == BiometricReason.lockout) {
          _biometricNotice = BiometricNotice.lockout; // the pill is the retry
        } else {
          _autoPromptPending = true;
        }
        return;
      }
      final token = await ApiClient.getToken();
      if (token != null) {
        _wakingServer = true;
        notifyListeners();
        await _checkSession(session);
      }
    } catch (_) {
      // SharedPreferences or other init failure — safe to ignore, user stays logged out
    } finally {
      _wakingServer = false;
      _loading = false;
      notifyListeners();
    }
  }

  /// The startup /user/me check with the saved (or just unlocked) token.
  Future<void> _checkSession(int session, {bool afterUnlock = false}) async {
    try {
      final me = await ApiClient.getMe(timeout: _kStartupTimeout);
      if (session != _session) return; // logged out or in again meanwhile
      _user = me;
      _offline = false;
      await _saveUser(me);
    } on ApiException catch (e) {
      if (session != _session) return;
      // Only a rejected token (401) or a deleted account (JSON 404 from our
      // server) logs the user out. A non-JSON 404 means the host itself is
      // missing/suspended, so keep the token and show Retry.
      if (e.statusCode == 401 || (e.statusCode == 404 && e.fromServer)) {
        await ApiClient.clearToken();
        await OfflineCache.clear();
        // S11: log out all, a password change elsewhere or the 7-day expiry
        // ends the Face ID session too.
        if (afterUnlock) _biometricNotice = BiometricNotice.sessionEnded;
      } else if (!e.fromServer && await _openOffline()) {
        // Timeout: open with the saved profile.
      } else {
        _startupError = e.message;
      }
    } catch (_) {
      if (session != _session) return;
      // No connection, DNS failure, etc. — keep the token. Open with the
      // saved profile if there is one, otherwise show Retry.
      if (!await _openOffline()) _startupError = _kUnreachable;
    }
  }

  /// The sign-in tab's Face ID pill (and its one-time auto-prompt). Reading
  /// the protected Keychain item is the Face ID check.
  Future<void> unlockWithBiometrics() async {
    if (_unlocking || !_biometricLocked) return;
    final session = _session;
    _unlocking = true;
    _biometricNotice = null;
    notifyListeners();
    Timer? splash;
    try {
      final read = await TokenStore.unlock();
      if (session != _session) return; // a password sign-in won
      final status = await _refine(read.status);
      switch (status) {
        case ProtectedStatus.success:
          // Same busy pill until /user/me answers; the waking-server splash
          // only if the server is slow.
          splash = Timer(_kUnlockSplashDelay, () {
            if (session != _session || _user != null) return;
            _loading = true;
            _wakingServer = true;
            notifyListeners();
          });
          await _checkSession(session, afterUnlock: true);
          if (session != _session) return;
          _biometricLocked = false;
        case ProtectedStatus.cancelled:
        case ProtectedStatus.failed:
          break; // back to rest, no notice
        case ProtectedStatus.error:
          _biometricNotice = BiometricNotice.error; // item kept, pill stays
        case ProtectedStatus.lockout:
          _biometricNotice = BiometricNotice.lockout; // item kept, pill stays
        case ProtectedStatus.invalidated:
        case ProtectedStatus.notAvailable:
          await TokenStore.forgetProtection();
          _biometricLocked = false;
          _biometricNotice = status == ProtectedStatus.invalidated
              ? BiometricNotice.invalidated
              : _noticeFor(_availability.reason) ?? BiometricNotice.notAvailable;
      }
    } finally {
      splash?.cancel();
      if (session == _session) {
        _unlocking = false;
        _loading = false;
        _wakingServer = false;
        notifyListeners();
      }
    }
  }

  /// The Keychain can't always say why a read failed: Face ID's own state
  /// tells a lockout or "turned off for Nexus" apart from a plain failure.
  Future<ProtectedStatus> _refine(ProtectedStatus status) async {
    if (status != ProtectedStatus.failed && status != ProtectedStatus.error) return status;
    final a = await refreshBiometricAvailability(notify: false);
    if (a.usable || a.reason == BiometricReason.unknown) return status; // unknown: keep the item
    return a.reason == BiometricReason.lockout ? ProtectedStatus.lockout : ProtectedStatus.notAvailable;
  }

  /// Face ID can't work for a protected item: not lockout (it passes), and
  /// never [BiometricReason.unknown] (the phone didn't say, so keep things).
  static bool _surelyUnusable(BiometricAvailability a) =>
      !a.usable && a.reason != BiometricReason.lockout && a.reason != BiometricReason.unknown;

  static BiometricNotice? _noticeFor(BiometricReason? reason) => switch (reason) {
        BiometricReason.turnedOffForApp => BiometricNotice.notAvailable,
        BiometricReason.lockout => BiometricNotice.lockout,
        BiometricReason.notEnrolled || BiometricReason.noPasscode || BiometricReason.noHardware =>
          BiometricNotice.notEnrolled,
        _ => null,
      };

  /// Ask the phone whether Face ID can be used now.
  Future<BiometricAvailability> refreshBiometricAvailability({bool notify = true}) async {
    BiometricAvailability a;
    try {
      a = isIosPlatform ? await TokenStore.biometrics.availability() : BiometricAvailability.notIos;
    } catch (_) {
      a = const BiometricAvailability.unusable(BiometricReason.unknown);
    }
    final changed = a.usable != _availability.usable || a.reason != _availability.reason || a.kind != _availability.kind;
    _availability = a;
    if (notify && changed) notifyListeners();
    return a;
  }

  /// Turn Face ID on (offer sheet, Profile switch): Face ID first, then the
  /// token moves to the protected item. [BioOutcome.error] if the move failed
  /// (S22): Face ID stays off.
  Future<BioOutcome> enableBiometrics() async {
    final user = _user;
    if (user == null || !isIosPlatform) return BioOutcome.notAvailable;
    final outcome = await TokenStore.biometrics.confirm('Turn on $biometricName for Nexus');
    if (outcome != BioOutcome.success) return outcome;
    if (_user?.id != user.id) return BioOutcome.cancelled; // signed out meanwhile
    try {
      await TokenStore.enableProtection(user.id);
    } catch (_) {
      return BioOutcome.error;
    }
    _offerBiometrics = false;
    notifyListeners();
    return BioOutcome.success;
  }

  /// Turn Face ID off (Profile switch). Asks for Face ID first (S19): any
  /// other outcome leaves it on, with the token still protected.
  Future<BioOutcome> disableBiometrics() async {
    final user = _user;
    if (user == null) return BioOutcome.notAvailable;
    final outcome = await TokenStore.biometrics.confirm('Turn off $biometricName for Nexus');
    if (outcome != BioOutcome.success) return outcome;
    if (_user?.id != user.id) return BioOutcome.cancelled;
    try {
      await TokenStore.disableProtection();
    } catch (_) {
      return BioOutcome.error;
    }
    notifyListeners();
    return BioOutcome.success;
  }

  /// "Not now" on the offer: don't offer again to this user on this phone.
  Future<void> declineBiometricOffer() async {
    _offerBiometrics = false;
    final user = _user;
    if (user == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kDeclinedKey, user.id);
    } catch (_) {}
  }

  Future<bool> _shouldOffer(User user) async {
    if (!isIosPlatform || TokenStore.bioUser == user.id) return false;
    if (!_availability.usable) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kDeclinedKey) != user.id;
    } catch (_) {
      return false;
    }
  }

  /// Re-lock after time away (AppLock). Synchronous (S8): the token is out
  /// of memory before this returns.
  void lockApp() {
    TokenStore.lock();
    _appLocked = true;
    notifyListeners();
  }

  /// The lock overlay's Face ID button. The overlay shows the outcome.
  Future<ProtectedStatus> unlockApp() async {
    final session = _session;
    final read = await TokenStore.unlock();
    if (session != _session || !_appLocked) return ProtectedStatus.cancelled;
    final status = await _refine(read.status);
    switch (status) {
      case ProtectedStatus.success:
        _appLocked = false;
        notifyListeners();
      case ProtectedStatus.invalidated:
      case ProtectedStatus.notAvailable:
        // Can never unlock now: only the password path is left. Still locked.
        await TokenStore.forgetProtection();
      default:
        break;
    }
    return status;
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
    final bioUser = TokenStore.bioUser;
    if (bioUser != null && bioUser != user.id) {
      // Face ID belongs to someone else on this phone: this account starts plain.
      await TokenStore.forgetProtection();
    } else if (bioUser == user.id && isIosPlatform) {
      // Same user (Q3, accepted): protected straight away, no new offer.
      // Unless Face ID can't work any more (not set up, no passcode, turned
      // off for Nexus): then plain, or every protected write would fail.
      final a = await refreshBiometricAvailability(notify: false);
      if (_surelyUnusable(a)) await TokenStore.forgetProtection();
    } else if (isIosPlatform) {
      await refreshBiometricAvailability(notify: false);
    }
    await ApiClient.saveToken(token);
    _user = user;
    _offline = false;
    _resetLockState();
    await _saveUser(user);
    _offerBiometrics = await _shouldOffer(user);
    notifyListeners();
  }

  void _resetLockState() {
    _biometricLocked = false;
    _appLocked = false;
    _autoPromptPending = false;
    _biometricNotice = null;
    _unlocking = false;
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
    // S17: a new account never inherits Face ID.
    await TokenStore.forgetProtection();
    await ApiClient.saveToken(result.token);
    _user = result.user;
    _offline = false;
    _resetLockState();
    _offerBiometrics = false;
    await _saveUser(result.user);
    _justRegistered = true;
    notifyListeners();
  }

  /// Deletes both Keychain copies (S12) and leaves any lock: the overlay's
  /// "Sign in with password" lands on a plain sign-in tab.
  Future<void> logout() async {
    _session++;
    _pendingGoogle = null;
    // S31: local Google sign out too (never disconnect); errors ignored.
    // Skipped when Google isn't set up in this build.
    if (_google.available) unawaited(_google.signOut().catchError((Object _) {}));
    await ApiClient.clearToken();
    await OfflineCache.clear();
    _user = null;
    _offline = false;
    _startupError = null;
    _offerBiometrics = false;
    _resetLockState();
    _loading = false;
    _wakingServer = false;
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
