import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'biometric_service.dart' show isIosPlatform;
import 'google_config.dart';

/// Why Google's own sheet didn't give a token: the plugin failed, or there
/// was no connection to Google. The sign-in tab picks its coral text by it.
enum GoogleFailureKind { plugin, network }

/// What Google's sheet gave back.
sealed class GoogleIdResult {
  const GoogleIdResult();
}

/// Google's ID token and the Google email. The token is only ever held in
/// memory and sent to the Nexus server; never saved or logged.
class GoogleIdToken extends GoogleIdResult {
  final String idToken;
  final String email;
  const GoogleIdToken(this.idToken, this.email);
}

/// The user closed Google's sheet.
class GoogleCancelled extends GoogleIdResult {
  const GoogleCancelled();
}

class GoogleFailed extends GoogleIdResult {
  final GoogleFailureKind kind;
  const GoogleFailed(this.kind);
}

/// Thrown by `AuthProvider.signInWithGoogle` when Google's sheet failed.
class GoogleAuthFailure implements Exception {
  final GoogleFailureKind kind;
  const GoogleAuthFailure(this.kind);
  @override
  String toString() => 'GoogleAuthFailure(${kind.name})';
}

/// What the plugin wrapper reports instead of the plugin's own exceptions.
enum GooglePluginErrorKind { cancelled, network, other }

class GooglePluginError implements Exception {
  final GooglePluginErrorKind kind;
  const GooglePluginError(this.kind);
  @override
  String toString() => 'GooglePluginError(${kind.name})';
}

/// The thin seam over the `google_sign_in` plugin, so tests can prove when it
/// is (and isn't) called (S37).
abstract class GooglePluginApi {
  Future<void> initialize({required String clientId});

  /// Google's sheet. Throws [GooglePluginError].
  Future<({String? idToken, String email})> authenticate();

  Future<void> signOut();
}

/// The only code in the app that touches `GoogleSignIn.instance`.
class GoogleSignInInstanceApi implements GooglePluginApi {
  const GoogleSignInInstanceApi();

  @override
  Future<void> initialize({required String clientId}) =>
      // No serverClientId (S34) and no nonce (Q11).
      GoogleSignIn.instance.initialize(clientId: clientId);

  @override
  Future<({String? idToken, String email})> authenticate() async {
    try {
      final account = await GoogleSignIn.instance.authenticate();
      return (idToken: account.authentication.idToken, email: account.email);
    } on GoogleSignInException catch (e) {
      throw GooglePluginError(_kindOf(e));
    }
  }

  @override
  Future<void> signOut() => GoogleSignIn.instance.signOut();

  static GooglePluginErrorKind _kindOf(GoogleSignInException e) {
    if (e.code == GoogleSignInExceptionCode.canceled) return GooglePluginErrorKind.cancelled;
    // The iOS SDK reports a lost connection as an unknown error from the
    // URL loading system; its text and details are the only hint.
    final text = '${e.description ?? ''} ${e.details ?? ''}'.toLowerCase();
    const hints = ['network', 'internet', 'offline', 'nsurlerrordomain', 'connection'];
    return hints.any(text.contains) ? GooglePluginErrorKind.network : GooglePluginErrorKind.other;
  }
}

/// Continue with Google on this phone.
abstract class GoogleAuthService {
  /// True only on iOS with a real client ID in the build (Q1).
  bool get available;

  /// Reads the client ID once and, when it is valid, sets the plugin up.
  Future<void> load();

  /// Google's sheet. Never throws.
  Future<GoogleIdResult> signIn();

  /// Local sign out of Google (not disconnect). Never throws.
  Future<void> signOut();
}

/// [GoogleAuthService] over the `google_sign_in` 7 plugin. When the client ID
/// is missing or invalid, the plugin is never called: no initialize, no
/// sheet, no sign out (S37).
class PluginGoogleAuthService implements GoogleAuthService {
  PluginGoogleAuthService({
    Future<String?> Function() loadClientId = loadGoogleIosClientId,
    GooglePluginApi? plugin,
  })  : _loadClientId = loadClientId,
        _plugin = plugin ?? const GoogleSignInInstanceApi();

  final Future<String?> Function() _loadClientId;
  final GooglePluginApi _plugin;
  Future<void>? _loading;
  bool _available = false;

  @override
  bool get available => _available;

  @override
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    String? id;
    try {
      id = await _loadClientId();
    } catch (_) {
      id = null;
    }
    if (!isIosPlatform || !isValidGoogleIosClientId(id)) return;
    try {
      await _plugin.initialize(clientId: id!);
      _available = true;
    } catch (_) {
      _available = false; // the button stays hidden
    }
  }

  @override
  Future<GoogleIdResult> signIn() async {
    if (!_available) return const GoogleFailed(GoogleFailureKind.plugin);
    try {
      final r = await _plugin.authenticate();
      final token = r.idToken;
      if (token == null || token.isEmpty) return const GoogleFailed(GoogleFailureKind.plugin);
      return GoogleIdToken(token, r.email);
    } on GooglePluginError catch (e) {
      return switch (e.kind) {
        GooglePluginErrorKind.cancelled => const GoogleCancelled(),
        GooglePluginErrorKind.network => const GoogleFailed(GoogleFailureKind.network),
        GooglePluginErrorKind.other => const GoogleFailed(GoogleFailureKind.plugin),
      };
    } catch (_) {
      return const GoogleFailed(GoogleFailureKind.plugin);
    }
  }

  @override
  Future<void> signOut() async {
    if (!_available) return;
    try {
      await _plugin.signOut();
    } catch (_) {}
  }
}

/// How `AuthProvider` gets its service when none is passed. Tests swap it for
/// a fake in `flutter_test_config.dart`.
@visibleForTesting
GoogleAuthService Function() createGoogleAuthService = PluginGoogleAuthService.new;

/// The default for `AuthProvider`: [createGoogleAuthService].
GoogleAuthService defaultGoogleAuthService() => createGoogleAuthService();
