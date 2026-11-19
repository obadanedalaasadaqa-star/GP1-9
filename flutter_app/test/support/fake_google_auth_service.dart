import 'dart:async';

import 'package:nexus_app/core/google_auth_service.dart';

/// A scripted Continue with Google: [available] (false by default, so every
/// screen test sees Phase 11's sign-in tab), and the next [signIn] answers.
class FakeGoogleAuthService implements GoogleAuthService {
  FakeGoogleAuthService({this.available = false, this.becomesAvailableOnLoad = false});

  @override
  bool available;

  /// load() turns [available] on (to test the late notify).
  bool becomesAvailableOnLoad;

  /// Answers for the next signIn() calls, in order; then [GoogleCancelled].
  final List<GoogleIdResult> results = [];
  /// Holds signIn() until completed (Google's sheet is up).
  Completer<void>? hold;
  int loads = 0;
  int signIns = 0;
  int signOuts = 0;
  bool signOutThrows = false;

  @override
  Future<void> load() async {
    loads++;
    if (becomesAvailableOnLoad) available = true;
  }

  @override
  Future<GoogleIdResult> signIn() async {
    signIns++;
    final h = hold;
    if (h != null) await h.future;
    return results.isEmpty ? const GoogleCancelled() : results.removeAt(0);
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    if (signOutThrows) throw StateError('google sign out failed');
  }
}

/// Records every call into the plugin seam (F14).
class RecordingGooglePluginApi implements GooglePluginApi {
  final List<String> calls = [];
  final List<String> clientIds = [];
  ({String? idToken, String email}) next = (idToken: 'google-id-token', email: 'a@nexus.test');
  GooglePluginError? error;

  @override
  Future<void> initialize({required String clientId}) async {
    calls.add('initialize');
    clientIds.add(clientId);
  }

  @override
  Future<({String? idToken, String email})> authenticate() async {
    calls.add('authenticate');
    final e = error;
    if (e != null) throw e;
    return next;
  }

  @override
  Future<void> signOut() async {
    calls.add('signOut');
  }
}
