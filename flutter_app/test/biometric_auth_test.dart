import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/biometric_service.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:nexus_app/core/secure_store.dart';
import 'package:nexus_app/core/token_store.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';
import 'support/face_id_support.dart';
import 'support/fake_biometric_service.dart';
import 'support/fake_secure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Face ID is iOS only: these tests say so explicitly.
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  setUp(() {
    requests.clear();
    handler = (_) async => http.Response(jsonEncode(userJson()), 200);
  });
  Future<T> run<T>(Future<T> Function() body) => http.runWithClient(body, () => MockClient((req) {
        requests.add(req);
        return handler(req);
      }));

  Future<AuthProvider> start() => run(() async {
        final auth = AuthProvider();
        await settle(auth);
        return auth;
      });

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();
  final user = User.fromJson(userJson());

  test('T9 / X9 (S6) a Face ID cold start is locked: no user, no cache read, no request', () async {
    seedFaceIdOn();
    // A saved profile is on the phone, but must not be read.
    await OfflineCache.saveUser(user);
    final auth = await start();
    expect(auth.biometricLocked, isTrue);
    expect(auth.showFacePill, isTrue);
    expect(auth.user, isNull);
    expect(auth.offline, isFalse);
    expect(requests, isEmpty);
    expect(fakeStore.readProtectedCount, 0);
    expect(auth.consumeAutoPrompt(), isTrue);
    expect(auth.consumeAutoPrompt(), isFalse); // once
  });

  test('T10 success: /user/me with the unlocked token, signed in', () async {
    seedFaceIdOn();
    final auth = await start();
    await run(auth.unlockWithBiometrics);
    expect(auth.isLoggedIn, isTrue);
    expect(auth.biometricLocked, isFalse);
    expect(requests.single.url.path, endsWith('/user/me'));
    expect(bearer(requests.single), 'Bearer test-token-a');
    expect(auth.biometricsOn, isTrue);
  });

  test('T11 cancel: still locked, no request, no notice, and the password works', () async {
    seedFaceIdOn();
    final auth = await start();
    fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
    await run(auth.unlockWithBiometrics);
    expect(auth.showFacePill, isTrue);
    expect(auth.isLoggedIn, isFalse);
    expect(auth.biometricNotice, isNull);
    expect(requests, isEmpty);

    handler = (_) async => http.Response(jsonEncode({'token': 'test-token-b', 'user': userJson()}), 200);
    await run(() => auth.login('a@nexus.test', 'Nexus@2026'));
    expect(auth.isLoggedIn, isTrue);
    expect(auth.showFacePill, isFalse);
    // Same user: protected straight away (Q3), no new offer.
    expect(fakeStore.protected, 'test-token-b');
    expect(auth.consumeBiometricOffer(), isFalse);
  });

  for (final c in [
    (BiometricReason.notEnrolled, BiometricNotice.notEnrolled),
    (BiometricReason.noPasscode, BiometricNotice.notEnrolled),
  ]) {
    test('T12 ${c.$1.name} at cold start: pill hidden, notice, Face ID forgotten, password works', () async {
      seedFaceIdOn();
      final fake = FakeBiometricService()..current = BiometricAvailability.unusable(c.$1);
      TokenStore.resetForTest(store: fakeStore, biometrics: fake);
      final auth = await start();
      expect(auth.biometricLocked, isFalse);
      expect(auth.showFacePill, isFalse);
      expect(auth.biometricNotice, c.$2);
      expect(fakeStore.protected, isNull);
      expect((await prefs()).getString('nexus_bio_user'), isNull);
      expect((await prefs()).getBool('nexus_bio_token_present'), isNull);
      expect(auth.consumeAutoPrompt(), isFalse);

      handler = (_) async => http.Response(jsonEncode({'token': 'test-token-b', 'user': userJson()}), 200);
      await run(() => auth.login('a@nexus.test', 'Nexus@2026'));
      expect(auth.isLoggedIn, isTrue);
      expect(fakeStore.plain, 'test-token-b');
    });
  }

  test('T12b turned off for Nexus (-6) at cold start: kept until the Keychain read fails too', () async {
    seedFaceIdOn();
    fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.turnedOffForApp);
    final auth = await start();
    // -6 is also what a briefly unavailable Face ID says: nothing deleted yet.
    expect(auth.biometricLocked, isTrue);
    expect(auth.showFacePill, isTrue);
    expect(auth.biometricNotice, isNull);
    expect(fakeStore.protected, 'test-token-a');
    expect((await prefs()).getString('nexus_bio_user'), 'u1');
    expect(auth.consumeAutoPrompt(), isTrue);

    // The read fails as well: now it is really off for Nexus.
    fakeStore.nextProtectedResult = ProtectedStatus.failed;
    await run(auth.unlockWithBiometrics);
    expect(auth.showFacePill, isFalse);
    expect(auth.biometricNotice, BiometricNotice.notAvailable);
    expect(fakeStore.protected, isNull);
    expect((await prefs()).getString('nexus_bio_user'), isNull);
    expect(requests, isEmpty);
  });

  test('T12c -6 at cold start but the read works: signed in, Face ID still on', () async {
    seedFaceIdOn();
    fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.turnedOffForApp);
    final auth = await start();
    fakeBiometrics.current = const BiometricAvailability.usable();
    await run(auth.unlockWithBiometrics);
    expect(auth.isLoggedIn, isTrue);
    expect(auth.biometricsOn, isTrue);
    expect(fakeStore.protected, 'test-token-a');
  });

  group('T12d an unknown Face ID state never deletes the session', () {
    test('unknown at cold start: locked, pill, auto-prompt, item and flags kept', () async {
      seedFaceIdOn();
      fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.unknown);
      final auth = await start();
      expect(auth.biometricLocked, isTrue);
      expect(auth.showFacePill, isTrue);
      expect(auth.biometricNotice, isNull);
      expect(auth.consumeAutoPrompt(), isTrue);
      expect(fakeStore.protected, 'test-token-a');
      expect((await prefs()).getString('nexus_bio_user'), 'u1');
      expect((await prefs()).getBool('nexus_bio_token_present'), isTrue);
    });

    test('a status check that throws is unknown, not "no hardware"', () async {
      seedFaceIdOn();
      TokenStore.resetForTest(store: fakeStore, biometrics: _ThrowingBiometrics());
      final auth = await start();
      expect(auth.biometricAvailability.reason, BiometricReason.unknown);
      expect(auth.showFacePill, isTrue);
      expect(fakeStore.protected, 'test-token-a');
      expect((await prefs()).getString('nexus_bio_user'), 'u1');
    });

    test('the read decides: a match signs in', () async {
      seedFaceIdOn();
      fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.unknown);
      final auth = await start();
      await run(auth.unlockWithBiometrics);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.biometricsOn, isTrue);
    });

    for (final status in [ProtectedStatus.failed, ProtectedStatus.error]) {
      test('a ${status.name} read with an unknown state keeps the item and the pill', () async {
        seedFaceIdOn();
        fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.unknown);
        final auth = await start();
        fakeStore.nextProtectedResult = status;
        await run(auth.unlockWithBiometrics);
        expect(auth.showFacePill, isTrue);
        expect(fakeStore.protected, 'test-token-a');
        expect((await prefs()).getString('nexus_bio_user'), 'u1');
        expect(auth.biometricNotice, status == ProtectedStatus.error ? BiometricNotice.error : isNull);
      });
    }

    test('same-user sign-in with an unknown state stays protected', () async {
      seedFaceIdOn(marker: false);
      final auth = await start();
      fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.unknown);
      await run(() => auth.completeLogin('test-token-b', user));
      expect(fakeStore.protected, 'test-token-b');
      expect(fakeStore.plain, isNull);
      expect((await prefs()).getString('nexus_bio_user'), 'u1');
    });
  });

  test('T13 lockout at cold start: notice, pill kept, item kept, no auto-prompt', () async {
    seedFaceIdOn();
    fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.lockout);
    final auth = await start();
    expect(auth.biometricNotice, BiometricNotice.lockout);
    expect(auth.showFacePill, isTrue);
    expect(fakeStore.protected, 'test-token-a');
    expect(auth.consumeAutoPrompt(), isFalse);
    expect(fakeStore.readProtectedCount, 0);
  });

  test('T14 faces changed: item deleted, flags removed, pill hidden, notice', () async {
    seedFaceIdOn();
    final auth = await start();
    fakeStore.nextProtectedResult = ProtectedStatus.invalidated;
    await run(auth.unlockWithBiometrics);
    expect(fakeStore.protected, isNull);
    expect((await prefs()).getString('nexus_bio_user'), isNull);
    expect((await prefs()).getBool('nexus_bio_token_present'), isNull);
    expect(auth.showFacePill, isFalse);
    expect(auth.biometricNotice, BiometricNotice.invalidated);
    expect(requests, isEmpty);
  });

  for (final reply in [
    http.Response(jsonEncode({'error': 'Invalid or expired token.'}), 401),
    http.Response(jsonEncode({'error': 'User not found.'}), 404),
  ]) {
    test('T15 (S11) a ${reply.statusCode} after unlock ends the Face ID session', () async {
      seedFaceIdOn();
      await OfflineCache.saveUser(user);
      final auth = await start();
      handler = (_) async => reply;
      await run(auth.unlockWithBiometrics);
      expect(auth.isLoggedIn, isFalse);
      expect(fakeStore.protected, isNull);
      expect(fakeStore.plain, isNull);
      expect((await prefs()).getBool('nexus_bio_token_present'), isNull);
      expect(await OfflineCache.loadUser(), isNull);
      expect(auth.biometricNotice, BiometricNotice.sessionEnded);
      expect(auth.showFacePill, isFalse);
      expect(auth.startupError, isNull);
    });
  }

  test('T16 (Q4) unlock with no connection opens offline with the saved profile', () async {
    seedFaceIdOn();
    await OfflineCache.saveUser(user);
    final auth = await start();
    handler = (_) async => throw const SocketLikeException();
    await run(auth.unlockWithBiometrics);
    expect(auth.isLoggedIn, isTrue);
    expect(auth.offline, isTrue);
    expect(auth.biometricLocked, isFalse);
  });

  test('T16b Retry after unlock and an unreachable server goes straight to /user/me (no second prompt)', () async {
    seedFaceIdOn();
    final auth = await start();
    handler = (_) async => throw const SocketLikeException();
    await run(auth.unlockWithBiometrics);
    expect(auth.startupError, isNotNull);
    expect(auth.isLoggedIn, isFalse);
    expect(fakeStore.readProtectedCount, 1);

    handler = (_) async => http.Response(jsonEncode(userJson()), 200);
    requests.clear();
    await run(() async {
      final f = auth.retry();
      await f;
      await settle(auth);
    });
    expect(fakeStore.readProtectedCount, 1);
    expect(auth.biometricLocked, isFalse);
    expect(auth.isLoggedIn, isTrue);
    expect(bearer(requests.single), 'Bearer test-token-a');
  });

  test('T16c the pill stays busy until /user/me answers (no splash on a quick answer)', () async {
    seedFaceIdOn();
    final auth = await start();
    final reply = Completer<http.Response>();
    handler = (_) => reply.future;
    late Future<void> pending;
    await run(() async {
      pending = auth.unlockWithBiometrics();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(auth.unlocking, isTrue);
    expect(auth.loading, isFalse);
    expect(auth.showFacePill, isTrue);
    reply.complete(http.Response(jsonEncode(userJson()), 200));
    await pending;
    expect(auth.unlocking, isFalse);
    expect(auth.isLoggedIn, isTrue);
  });

  test('T17 logout with Face ID on deletes the protected item and the marker', () async {
    seedFaceIdOn();
    final auth = await start();
    await run(auth.unlockWithBiometrics);
    await run(auth.logout);
    expect(fakeStore.protected, isNull);
    expect((await prefs()).getBool('nexus_bio_token_present'), isNull);
    expect((await prefs()).getString('nexus_bio_user'), 'u1'); // D5: the choice is kept
  });

  test('T36 after sign-out the next start is signed out: no pill, no prompt', () async {
    seedFaceIdOn();
    final auth = await start();
    await run(auth.unlockWithBiometrics);
    await run(auth.logout);
    final reads = fakeStore.readProtectedCount;
    restartApp();
    final again = await start();
    expect(again.biometricLocked, isFalse);
    expect(again.showFacePill, isFalse);
    expect(again.isLoggedIn, isFalse);
    expect(fakeStore.readProtectedCount, reads);
  });

  test('T18 a password change while unlocked puts the new token in the protected item, no prompt', () async {
    seedFaceIdOn();
    final auth = await start();
    await run(auth.unlockWithBiometrics);
    handler = (_) async => http.Response(jsonEncode({'message': 'ok', 'token': 'test-token-b'}), 200);
    await run(() => ApiClient.changePassword(currentPassword: 'Nexus@2026', newPassword: 'Nexus@2027!'));
    expect(fakeStore.protected, 'test-token-b');
    expect(fakeStore.readProtectedCount, 1);
    expect(await ApiClient.getToken(), 'test-token-b');
  });

  group('T19 the offer', () {
    Future<AuthProvider> signedOut() async {
      SharedPreferences.setMockInitialValues({'nexus_keychain_ready': true});
      return start();
    }

    test('after login and after a 2FA completeLogin', () async {
      final auth = await signedOut();
      handler = (_) async => http.Response(jsonEncode({'token': 'test-token-a', 'user': userJson()}), 200);
      await run(() => auth.login('a@nexus.test', 'Nexus@2026'));
      expect(auth.consumeBiometricOffer(), isTrue);
      expect(auth.consumeBiometricOffer(), isFalse);
      await run(auth.logout);
      await run(() => auth.completeLogin('test-token-b', user));
      expect(auth.consumeBiometricOffer(), isTrue);
    });

    test('not after register', () async {
      final auth = await signedOut();
      handler = (_) async => http.Response(jsonEncode({'token': 'test-token-a', 'user': userJson()}), 201);
      await run(() => auth.register(firstName: 'Sara', lastName: 'Ali', email: 'a@nexus.test', password: 'Nexus@2026'));
      expect(auth.consumeBiometricOffer(), isFalse);
    });

    test('not when Face ID is unavailable, and not on Android', () async {
      final auth = await signedOut();
      fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.notEnrolled);
      await run(() => auth.completeLogin('test-token-a', user));
      expect(auth.consumeBiometricOffer(), isFalse);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      fakeBiometrics.current = const BiometricAvailability.usable();
      await run(() => auth.completeLogin('test-token-b', user));
      expect(auth.consumeBiometricOffer(), isFalse);
    });

    test('not when this user declined, but again for a different user', () async {
      final auth = await signedOut();
      await run(() => auth.completeLogin('test-token-a', user));
      await auth.declineBiometricOffer();
      await run(auth.logout);
      await run(() => auth.completeLogin('test-token-b', user));
      expect(auth.consumeBiometricOffer(), isFalse);
      await run(auth.logout);
      await run(() => auth.completeLogin('test-token-c', User.fromJson(userJson(id: 'u2'))));
      expect(auth.consumeBiometricOffer(), isTrue);
    });
  });

  test('T19b completeLogin when Face ID is on for this user but no longer set up: saved plain', () async {
    seedFaceIdOn(marker: false); // S22 left the marker cleared
    final auth = await start();
    fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.noPasscode);
    await run(() => auth.completeLogin('test-token-b', user));
    expect(fakeStore.plain, 'test-token-b');
    expect(fakeStore.writeProtectedCount, 0);
    expect((await prefs()).getString('nexus_bio_user'), isNull);
    restartApp();
    final again = await start();
    expect(again.isLoggedIn, isTrue); // stays signed in across starts
  });

  test('T19c completeLogin with a lockout still saves protected (adding needs no match)', () async {
    seedFaceIdOn(marker: false);
    final auth = await start();
    fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.lockout);
    await run(() => auth.completeLogin('test-token-b', user));
    expect(fakeStore.protected, 'test-token-b');
    expect(fakeStore.plain, isNull);
  });

  group('X8 (S3) only a match unlocks', () {
    for (final status in [
      ProtectedStatus.cancelled,
      ProtectedStatus.failed,
      ProtectedStatus.lockout,
      ProtectedStatus.invalidated,
      ProtectedStatus.notAvailable,
      ProtectedStatus.error,
    ]) {
      test(status.name, () async {
        seedFaceIdOn();
        final auth = await start();
        fakeStore.nextProtectedResult = status;
        await run(auth.unlockWithBiometrics);
        expect(auth.user, isNull);
        expect(await ApiClient.getToken(), isNull);
        expect(requests, isEmpty);
        if (status == ProtectedStatus.error) {
          expect(fakeStore.protected, 'test-token-a');
          expect(auth.biometricNotice, BiometricNotice.error);
          expect(auth.showFacePill, isTrue);
        }
        if (status == ProtectedStatus.lockout) {
          expect(fakeStore.protected, 'test-token-a');
          expect(auth.showFacePill, isTrue);
        }
        handler = (_) async => http.Response(jsonEncode({'token': 'test-token-b', 'user': userJson()}), 200);
        await run(() => auth.login('a@nexus.test', 'Nexus@2026'));
        expect(auth.isLoggedIn, isTrue);
      });
    }

    test('a failed read while Face ID reports a lockout is shown as a lockout', () async {
      seedFaceIdOn();
      final auth = await start();
      fakeStore.nextProtectedResult = ProtectedStatus.failed;
      fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.lockout);
      await run(auth.unlockWithBiometrics);
      expect(auth.biometricNotice, BiometricNotice.lockout);
      expect(auth.showFacePill, isTrue);
    });
  });

  test('X10 (S10) a 2FA challenge writes nothing and sets no offer', () async {
    SharedPreferences.setMockInitialValues({'nexus_keychain_ready': true});
    final auth = await start();
    handler = (_) async => http.Response(jsonEncode(challengeJson), 200);
    final challenge = await run(() => auth.login('a@nexus.test', 'Nexus@2026'));
    expect(challenge, isNotNull);
    expect(fakeStore.plain, isNull);
    expect(fakeStore.protected, isNull);
    expect(fakeStore.ops, isEmpty);
    expect(auth.consumeBiometricOffer(), isFalse);
  });

  test('X11 (S17) a new account never inherits Face ID', () async {
    seedFaceIdOn(user: 'uA');
    final auth = await start();
    handler = (_) async => http.Response(jsonEncode({'token': 'test-token-c', 'user': userJson(id: 'uC')}), 201);
    await run(() => auth.register(firstName: 'Cara', lastName: 'Lee', email: 'c@nexus.test', password: 'Nexus@2026'));
    expect(fakeStore.plain, 'test-token-c');
    expect(fakeStore.protected, isNull);
    expect((await prefs()).getString('nexus_bio_user'), isNull);
    expect((await prefs()).getBool('nexus_bio_token_present'), isNull);
    expect(auth.showFacePill, isFalse);
  });

  test('another user signing in on a Face ID phone starts plain', () async {
    seedFaceIdOn(user: 'uA');
    final auth = await start();
    await run(() => auth.completeLogin('test-token-b', User.fromJson(userJson(id: 'uB'))));
    expect(fakeStore.plain, 'test-token-b');
    expect(fakeStore.protected, isNull);
    expect(TokenStore.bioUser, isNull);
  });

  group('T37 (S19, S22) turning Face ID on and off', () {
    test('off with a cancelled prompt leaves it on and protected', () async {
      seedFaceIdOn();
      final auth = await start();
      await run(auth.unlockWithBiometrics);
      fakeBiometrics.nextConfirm = BioOutcome.cancelled;
      expect(await auth.disableBiometrics(), BioOutcome.cancelled);
      expect(auth.biometricsOn, isTrue);
      expect(fakeStore.protected, 'test-token-a');
      expect(fakeStore.plain, isNull);
    });

    test('on with a match but a failed protected write: error, still off', () async {
      seedPlain();
      final auth = await start();
      fakeStore.throwOnWriteProtected = true;
      expect(await auth.enableBiometrics(), BioOutcome.error);
      expect(auth.biometricsOn, isFalse);
      expect(fakeStore.plain, 'test-token-a');
    });

    test('on and off with a match move the token and ask Face ID each time', () async {
      seedPlain();
      final auth = await start();
      expect(await auth.enableBiometrics(), BioOutcome.success);
      expect(auth.biometricsOn, isTrue);
      expect(fakeStore.protected, 'test-token-a');
      expect(await auth.disableBiometrics(), BioOutcome.success);
      expect(auth.biometricsOn, isFalse);
      expect(fakeStore.plain, 'test-token-a');
      expect(fakeBiometrics.reasons, ['Turn on Face ID for Nexus', 'Turn off Face ID for Nexus']);
    });
  });
}

/// A transport failure (no connection), like a SocketException.
class SocketLikeException implements Exception {
  const SocketLikeException();
}

/// A status check whose platform channel fails.
class _ThrowingBiometrics extends FakeBiometricService {
  @override
  Future<BiometricAvailability> availability() async => throw StateError('channel');
}
