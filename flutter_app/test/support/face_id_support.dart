import 'package:http/http.dart' as http;
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_secure_store.dart';

/// Prefs for a phone where [user] turned Face ID on and the token sits in
/// the protected item (a locked cold start). Use before anything loads.
void seedFaceIdOn({String user = 'u1', String token = 'test-token-a', bool marker = true}) {
  SharedPreferences.setMockInitialValues({
    'nexus_keychain_ready': true,
    'nexus_bio_user': user,
    if (marker) 'nexus_bio_token_present': true,
  });
  if (marker) fakeStore.protected = token;
}

/// Prefs for a phone signed in with Face ID off (token in the plain item).
void seedPlain({String token = 'test-token-a'}) {
  SharedPreferences.setMockInitialValues({'nexus_keychain_ready': true});
  fakeStore.plain = token;
}

/// A new app start on the same phone: memory is gone, the fake Keychain and
/// SharedPreferences stay.
void restartApp() {
  TokenStore.resetForTest(store: fakeStore, biometrics: TokenStore.biometrics);
}

/// Waits until the startup check of [auth] is done.
Future<void> settle(AuthProvider auth) async {
  for (var i = 0; i < 400 && auth.loading; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  // Let the last notifications and microtasks run.
  await Future<void>.delayed(Duration.zero);
}

/// The Authorization header of [r] (null if there is none).
String? bearer(http.BaseRequest r) => r.headers['Authorization'];
