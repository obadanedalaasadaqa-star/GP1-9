import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/google_auth_service.dart';
import 'package:nexus_app/core/google_sign_in_result.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:nexus_app/core/token_store.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';
import 'support/face_id_support.dart';
import 'support/fake_google_auth_service.dart';
import 'support/fake_secure_store.dart';

// Phase 12: AuthProvider + Continue with Google (F1-F14). Google is a fake;
// F14 uses the real PluginGoogleAuthService over a recording plugin seam.
const _idToken = 'google-id-token-f';
const _password = 'Nexus@2026-link';
const _need = 'This email already has a Nexus account. Enter its password once to connect Google.';
const _wrong = "That password doesn't match. Try again, or tap Forgot password.";

User userFrom() => User.fromJson(userJson());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  setUp(() {
    requests.clear();
    handler = (_) async => http.Response(jsonEncode({'token': 'jwt-g', 'user': userJson()}), 200);
  });
  Future<T> run<T>(Future<T> Function() body) => http.runWithClient(
    body,
    () => MockClient((req) {
      requests.add(req);
      return handler(req);
    }),
  );
  http.Response reply(Object body, int status) => http.Response(jsonEncode(body), status);
  final needReply = reply({'error': _need, 'code': 'password_required', 'email': 'a@nexus.test'}, 409);

  late FakeGoogleAuthService google;
  Future<AuthProvider> start({bool available = true, bool keychainReady = true}) => run(() async {
    if (keychainReady) SharedPreferences.setMockInitialValues({'nexus_keychain_ready': true});
    google = FakeGoogleAuthService(available: available);
    final auth = AuthProvider(google: google);
    await settle(auth);
    return auth;
  });

  void nextGoogle(GoogleIdResult r) => google.results.add(r);
  Future<String> prefsDump() async {
    final p = await SharedPreferences.getInstance();
    return p.getKeys().map((k) => '$k=${p.get(k)}').join('\n');
  }

  // iOS for the provider tests; the F14 widget tests use the iOS variant.
  group('provider', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('F1 a Google session goes through completeLogin: Keychain, cache, signed in', () async {
      final auth = await start();
      nextGoogle(const GoogleIdToken(_idToken, 'a@nexus.test'));
      final r = await run(auth.signInWithGoogle);
      expect(r, isNull);
      expect(auth.isLoggedIn, isTrue);
      expect(fakeStore.plain, 'jwt-g');
      expect(await ApiClient.getToken(), 'jwt-g');
      expect((await OfflineCache.loadUser())?.id, 'u1');
      expect(jsonDecode(requests.single.body), {'idToken': _idToken});
      expect(requests.single.url.path, endsWith('/auth/google'));
    });

    Future<AuthProvider> startAsIs() => run(() async {
      google = FakeGoogleAuthService(available: true);
      final a = AuthProvider(google: google);
      await settle(a);
      return a;
    });

    test('F2 a new account forgets Face ID first, then gets the offer like a password sign-in', () async {
      seedFaceIdOn(user: 'u1'); // left over on this phone
      final auth = await startAsIs();
      expect(TokenStore.bioUser, 'u1');
      nextGoogle(const GoogleIdToken(_idToken, 'a@nexus.test'));
      handler = (_) async => reply({'token': 'jwt-new', 'user': userJson(), 'created': true}, 201);
      await run(auth.signInWithGoogle);
      expect(TokenStore.bioUser, isNull);
      expect(fakeStore.protected, isNull);
      expect(fakeStore.plain, 'jwt-new');
      expect(auth.consumeJustRegistered(), isFalse); // no verify screen
      expect(auth.consumeBiometricOffer(), isTrue);
    });

    test('F3 a returning user with Face ID on: protected save, no new offer', () async {
      seedFaceIdOn(user: 'u1');
      final auth = await startAsIs();
      expect(auth.biometricLocked, isTrue);
      nextGoogle(const GoogleIdToken(_idToken, 'a@nexus.test'));
      handler = (_) async => reply({'token': 'jwt-back', 'user': userJson()}, 200);
      await run(auth.signInWithGoogle);
      expect(auth.isLoggedIn, isTrue);
      expect(fakeStore.protected, 'jwt-back');
      expect(fakeStore.plain, isNull);
      expect(auth.consumeBiometricOffer(), isFalse);
    });

    test('F4 a cancelled sheet: null, no request, no change', () async {
      final auth = await start();
      var notified = 0;
      auth.addListener(() => notified++);
      nextGoogle(const GoogleCancelled());
      expect(await run(auth.signInWithGoogle), isNull);
      expect(requests, isEmpty);
      expect(auth.isLoggedIn, isFalse);
      expect(notified, 0);
    });

    test('F5 a challenge saves nothing; the code screen finishes through completeLogin', () async {
      final auth = await start();
      nextGoogle(const GoogleIdToken(_idToken, 'g@nexus.test'));
      handler = (_) async => reply(challengeJson, 200);
      final r = await run(auth.signInWithGoogle);
      expect(r, isA<GoogleChallenge>());
      expect((r as GoogleChallenge).challenge.email, 'g@nexus.test');
      expect(auth.isLoggedIn, isFalse);
      expect(await ApiClient.getToken(), isNull);
      await run(() => auth.completeLogin('jwt-2fa', userFrom()));
      expect(auth.isLoggedIn, isTrue);
    });

    test('F5b the code screen names the stored Nexus email from the server', () async {
      final auth = await start();
      nextGoogle(const GoogleIdToken(_idToken, 'g@nexus.test'));
      handler = (_) async => reply({...challengeJson, 'email': 'nexus@nexus.test'}, 200);
      final r = await run(auth.signInWithGoogle);
      expect((r as GoogleChallenge).challenge.email, 'nexus@nexus.test');
      expect(auth.isLoggedIn, isFalse);
    });

    test('F6 password needed saves nothing; the password step re-sends the same token', () async {
      final auth = await start();
      nextGoogle(const GoogleIdToken(_idToken, 'a@nexus.test'));
      handler = (_) async => needReply;
      final r = await run(auth.signInWithGoogle);
      expect(r, isA<GooglePasswordNeeded>());
      expect((r as GooglePasswordNeeded).email, 'a@nexus.test');
      expect(await ApiClient.getToken(), isNull);
      handler = (_) async => reply({'token': 'jwt-linked', 'user': userJson()}, 200);
      expect(await run(() => auth.continueGoogleWithPassword(_password)), isNull);
      expect(jsonDecode(requests.last.body), {'idToken': _idToken, 'password': _password});
      expect(auth.isLoggedIn, isTrue);
    });

    group('F7 the held token is cleared', () {
      Future<AuthProvider> held() async {
        final auth = await start();
        nextGoogle(const GoogleIdToken(_idToken, 'a@nexus.test'));
        handler = (_) async => needReply;
        await run(auth.signInWithGoogle);
        return auth;
      }

      Future<void> expectGone(AuthProvider auth) async {
        final before = requests.length;
        expect(await run(() => auth.continueGoogleWithPassword(_password)), isA<GoogleTokenExpired>());
        expect(requests.length, before); // no request
      }

      test('after success', () async {
        final auth = await held();
        handler = (_) async => reply({'token': 'jwt', 'user': userJson()}, 200);
        await run(() => auth.continueGoogleWithPassword(_password));
        await expectGone(auth);
      });

      test('after a server failure (500), but not after a wrong password', () async {
        final auth = await held();
        handler = (_) async => reply({'error': _wrong, 'code': 'password_required', 'email': 'a@nexus.test'}, 401);
        final wrong = await run(() => auth.continueGoogleWithPassword('nope'));
        expect((wrong as GooglePasswordNeeded).wrongPassword, isTrue);
        handler = (_) async => reply({'error': "Sign-in didn't go through. Try again."}, 500);
        await expectLater(run(() => auth.continueGoogleWithPassword(_password)), throwsA(isA<ApiException>()));
        await expectGone(auth);
      });

      test('after cancel (dropPendingGoogle)', () async {
        final auth = await held();
        auth.dropPendingGoogle();
        await expectGone(auth);
      });

      test('after 10 minutes, without a request', () async {
        var now = DateTime(2026, 11, 19, 12);
        AuthProvider.clock = () => now;
        final auth = await held();
        now = now.add(const Duration(minutes: 10));
        await expectGone(auth);
      });

      test('after logout', () async {
        final auth = await held();
        await run(auth.logout);
        await expectGone(auth);
      });
    });

    group('F8 logout', () {
      test('signs out of Google, ignores its errors, clears both Keychain items', () async {
        final auth = await start();
        nextGoogle(const GoogleIdToken(_idToken, 'a@nexus.test'));
        await run(auth.signInWithGoogle);
        google.signOutThrows = true;
        fakeStore.protected = 'stale';
        await run(auth.logout);
        expect(google.signOuts, 1);
        expect(auth.isLoggedIn, isFalse);
        expect(fakeStore.plain, isNull);
        expect(fakeStore.protected, isNull);
      });

      test('skips Google when it is not available', () async {
        final auth = await start(available: false);
        await run(() => auth.completeLogin('jwt', userFrom()));
        await run(auth.logout);
        expect(google.signOuts, 0);
      });
    });

    test('F9 after "Sign out of all devices" a Google session ends like a password one', () async {
      final auth = await start();
      nextGoogle(const GoogleIdToken(_idToken, 'a@nexus.test'));
      await run(auth.signInWithGoogle);
      expect(fakeStore.plain, 'jwt-g');
      // Next start: the server says 401 for the old token.
      restartApp();
      handler = (_) async => reply({'error': 'Unauthorized'}, 401);
      final again = await run(() async {
        final a = AuthProvider(google: FakeGoogleAuthService(available: true));
        await settle(a);
        return a;
      });
      expect(again.isLoggedIn, isFalse);
      expect(await ApiClient.getToken(), isNull);
    });

    test('F10 not available: no button state, signInWithGoogle never calls the service; load can turn it on', () async {
      final auth = await start(available: false);
      expect(auth.googleAvailable, isFalse);
      expect(await run(auth.signInWithGoogle), isNull);
      expect(google.signIns, 0);
      expect(requests, isEmpty);

      final late = FakeGoogleAuthService(becomesAvailableOnLoad: true);
      final auth2 = AuthProvider(google: late);
      var notified = false;
      auth2.addListener(() => notified = notified || auth2.googleAvailable);
      await settle(auth2);
      expect(late.loads, 1);
      expect(auth2.googleAvailable, isTrue);
      expect(notified, isTrue);
    });

    group('F11 failures are handed to the screen with the right copy and tone', () {
      test('plugin and network failures throw GoogleAuthFailure', () async {
        final auth = await start();
        nextGoogle(const GoogleFailed(GoogleFailureKind.plugin));
        await expectLater(
          run(auth.signInWithGoogle),
          throwsA(isA<GoogleAuthFailure>().having((e) => e.kind, 'kind', GoogleFailureKind.plugin)),
        );
        nextGoogle(const GoogleFailed(GoogleFailureKind.network));
        await expectLater(
          run(auth.signInWithGoogle),
          throwsA(isA<GoogleAuthFailure>().having((e) => e.kind, 'kind', GoogleFailureKind.network)),
        );
        expect(requests, isEmpty);
      });

      test('a 503 is an ApiException', () async {
        final auth = await start();
        nextGoogle(const GoogleIdToken(_idToken, 'a@nexus.test'));
        handler = (_) async => reply({
          'error': "Google sign-in isn't available right now. Try again soon, or use your email and password.",
        }, 503);
        await expectLater(run(auth.signInWithGoogle), throwsA(isA<ApiException>()));
      });
    });

    test('F12 / F13 neither the ID token nor the password reaches prefs, the Keychain or the logs', () async {
      final logs = <String>[];
      final saved = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
      try {
        final auth = await start();
        nextGoogle(const GoogleIdToken(_idToken, 'a@nexus.test'));
        handler = (_) async => needReply;
        await run(auth.signInWithGoogle);
        handler = (_) async => reply({'error': _wrong, 'code': 'password_required', 'email': 'a@nexus.test'}, 401);
        await run(() => auth.continueGoogleWithPassword('Wrong@$_password'));
        handler = (_) async => reply({'token': 'jwt-ok', 'user': userJson()}, 200);
        await run(() => auth.continueGoogleWithPassword(_password));
        expect(auth.isLoggedIn, isTrue);
        final everything = [await prefsDump(), '${fakeStore.plain}', '${fakeStore.protected}', ...logs].join('\n');
        expect(everything, isNot(contains(_idToken)));
        expect(everything, isNot(contains(_password)));
      } finally {
        debugPrint = saved;
      }
    });
  });

  group('F14 (S37) the real service never calls the plugin without a valid ID', () {
    // The auth screen half (no button / button) is in google_sign_in_ui_test.dart.
    for (final bad in <String?>[
      '',
      null,
      'paste-client-id-here.apps.googleusercontent.com',
      r'$(GOOGLE_IOS_CLIENT_ID)',
      ' 123-abc.apps.googleusercontent.com',
    ]) {
      test('ID ${bad == null ? 'null' : "'$bad'"}: zero plugin calls through load, logout and a sign-in', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        SharedPreferences.setMockInitialValues({'nexus_keychain_ready': true});
        final plugin = RecordingGooglePluginApi();
        final service = PluginGoogleAuthService(loadClientId: () async => bad, plugin: plugin);
        final auth = AuthProvider(google: service);
        await settle(auth);
        await service.load();
        expect(service.available, isFalse);
        expect(auth.googleAvailable, isFalse);
        expect(await auth.signInWithGoogle(), isNull);
        expect(await service.signIn(), isA<GoogleFailed>());
        await service.signOut();
        await auth.logout();
        expect(plugin.calls, isEmpty);
      });
    }

    test('positive control: a valid ID → available, exactly one initialize', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({'nexus_keychain_ready': true});
      final plugin = RecordingGooglePluginApi();
      final service = PluginGoogleAuthService(
        loadClientId: () async => '123-abc.apps.googleusercontent.com',
        plugin: plugin,
      );
      final auth = AuthProvider(google: service);
      await settle(auth);
      await service.load();
      expect(service.available, isTrue);
      expect(auth.googleAvailable, isTrue);
      expect(plugin.calls, ['initialize']);
      expect(plugin.clientIds, ['123-abc.apps.googleusercontent.com']);
    });

    test('on Android a valid ID still never reaches the plugin', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final plugin = RecordingGooglePluginApi();
      final service = PluginGoogleAuthService(
        loadClientId: () async => '123-abc.apps.googleusercontent.com',
        plugin: plugin,
      );
      await service.load();
      expect(service.available, isFalse);
      expect(plugin.calls, isEmpty);
    });

    test('the plugin seam maps cancel, network and other errors', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final plugin = RecordingGooglePluginApi();
      final service = PluginGoogleAuthService(
        loadClientId: () async => '123-abc.apps.googleusercontent.com',
        plugin: plugin,
      );
      await service.load();
      expect(await service.signIn(), isA<GoogleIdToken>());
      plugin.error = const GooglePluginError(GooglePluginErrorKind.cancelled);
      expect(await service.signIn(), isA<GoogleCancelled>());
      plugin.error = const GooglePluginError(GooglePluginErrorKind.network);
      expect((await service.signIn() as GoogleFailed).kind, GoogleFailureKind.network);
      plugin.error = const GooglePluginError(GooglePluginErrorKind.other);
      expect((await service.signIn() as GoogleFailed).kind, GoogleFailureKind.plugin);
      plugin.error = null;
      plugin.next = (idToken: null, email: 'a@nexus.test');
      expect((await service.signIn() as GoogleFailed).kind, GoogleFailureKind.plugin);
    });
  });
}
