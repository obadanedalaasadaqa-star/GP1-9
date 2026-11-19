import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/secure_store.dart';
import 'package:nexus_app/core/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/face_id_support.dart';
import 'support/fake_secure_store.dart';

Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

/// How many of {plain, protected, legacy} hold a token (S2: at most one).
Future<int> places() async =>
    [fakeStore.plain, fakeStore.protected, (await prefs()).getString('nexus_token')].where((t) => t != null).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('plain mode and the migration', () {
    test('T1 an existing user is moved to the Keychain and stays signed in', () async {
      SharedPreferences.setMockInitialValues({'nexus_token': 'test-token-a'});
      expect(await ApiClient.getToken(), 'test-token-a');
      expect(fakeStore.plain, 'test-token-a');
      expect((await prefs()).getString('nexus_token'), isNull);
      expect((await prefs()).getBool('nexus_keychain_ready'), isTrue);
    });

    test('T2 a failed migration write keeps the prefs token and retries next start', () async {
      SharedPreferences.setMockInitialValues({'nexus_token': 'test-token-a'});
      fakeStore.throwOnWritePlain = true;
      expect(await ApiClient.getToken(), 'test-token-a');
      expect((await prefs()).getString('nexus_token'), 'test-token-a');
      expect(fakeStore.plain, isNull);

      fakeStore.throwOnWritePlain = false;
      restartApp();
      expect(await ApiClient.getToken(), 'test-token-a');
      expect(fakeStore.plain, 'test-token-a');
      expect((await prefs()).getString('nexus_token'), isNull);
    });

    test('T3 / X6 a reinstall wipes the old Keychain items with no prompt', () async {
      SharedPreferences.setMockInitialValues({});
      fakeStore
        ..plain = 'test-token-a'
        ..protected = 'test-token-b';
      await TokenStore.load();
      expect(fakeStore.plain, isNull);
      expect(fakeStore.protected, isNull);
      expect(TokenStore.bioUser, isNull);
      expect(TokenStore.isLocked, isFalse);
      expect(await ApiClient.getToken(), isNull);
      expect(fakeStore.readProtectedCount, 0);
      expect((await prefs()).getBool('nexus_keychain_ready'), isTrue);
    });

    test('T4 clearToken removes every copy and the marker, and keeps nexus_bio_user', () async {
      seedFaceIdOn();
      await TokenStore.unlock();
      await (await prefs()).setString('nexus_token', 'test-token-old');
      await ApiClient.clearToken();
      expect(await ApiClient.getToken(), isNull);
      expect(fakeStore.plain, isNull);
      expect(fakeStore.protected, isNull);
      expect((await prefs()).getBool('nexus_bio_token_present'), isNull);
      expect((await prefs()).getString('nexus_token'), isNull);
      expect((await prefs()).getString('nexus_bio_user'), 'u1');
    });

    test('X5 after the migration and a later save, prefs has no nexus_token', () async {
      SharedPreferences.setMockInitialValues({'nexus_token': 'test-token-a'});
      await ApiClient.getToken();
      await ApiClient.saveToken('test-token-b');
      expect((await prefs()).getString('nexus_token'), isNull);
      expect(fakeStore.plain, 'test-token-b');
    });

    test('X19b (S21) an unreadable plain item on Android is "signed out", no crash, legacy untouched', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({'nexus_keychain_ready': true, 'nexus_token': 'test-token-a'});
      fakeStore.throwOnReadPlain = true;
      await TokenStore.load();
      expect(await ApiClient.getToken(), isNull);
      expect(fakeStore.writePlainCount, 0); // not migrated
      expect((await prefs()).getString('nexus_token'), 'test-token-a');
    });
  });

  group('protected mode', () {
    test('T5 Face ID on and locked: no token and no prompt', () async {
      seedFaceIdOn();
      expect(await ApiClient.getToken(), isNull);
      expect(TokenStore.isLocked, isTrue);
      expect(fakeStore.readProtectedCount, 0);
    });

    test('T6 saveSession with Face ID on: delete then write, marker after, plain gone', () async {
      seedFaceIdOn(marker: false);
      fakeStore.plain = 'stale';
      await TokenStore.load();
      fakeStore.ops.clear();
      await ApiClient.saveToken('test-token-b');
      expect(fakeStore.ops.take(2), ['deleteProtected', 'writeProtected']);
      expect(fakeStore.protected, 'test-token-b');
      expect((await prefs()).getBool('nexus_bio_token_present'), isTrue);
      expect(fakeStore.plain, isNull);
      expect(await ApiClient.getToken(), 'test-token-b');
    });

    test('T7 enable and disable move the token both ways', () async {
      seedPlain();
      await TokenStore.load();
      await TokenStore.enableProtection('u1');
      expect(fakeStore.protected, 'test-token-a');
      expect(fakeStore.plain, isNull);
      expect((await prefs()).getString('nexus_bio_user'), 'u1');
      expect((await prefs()).getBool('nexus_bio_token_present'), isTrue);
      expect(await places(), 1);

      await TokenStore.disableProtection();
      expect(fakeStore.plain, 'test-token-a');
      expect(fakeStore.protected, isNull);
      expect((await prefs()).getString('nexus_bio_user'), isNull);
      expect((await prefs()).getBool('nexus_bio_token_present'), isNull);
      expect(await places(), 1);
    });

    test('T8 many getToken() calls after unlock read the protected item once', () async {
      seedFaceIdOn();
      expect((await TokenStore.unlock()).status, ProtectedStatus.success);
      for (var i = 0; i < 5; i++) {
        expect(await ApiClient.getToken(), 'test-token-a');
      }
      expect(fakeStore.readProtectedCount, 1);
    });

    test('T38 (S23) lock() is synchronous and only a match, a save or a clear ends it', () async {
      // Face ID on, marker cleared, token in memory: the state an S22 write
      // failure leaves.
      seedFaceIdOn(marker: false);
      await TokenStore.load();
      fakeStore.throwOnWriteProtected = true;
      await TokenStore.saveSession('test-token-a');
      fakeStore.throwOnWriteProtected = false;
      fakeStore.protected = 'test-token-a';
      expect(TokenStore.isLocked, isFalse);

      TokenStore.lock();
      expect(TokenStore.isLocked, isTrue); // no await in between
      expect(await TokenStore.getToken(), isNull);

      fakeStore.nextProtectedResult = ProtectedStatus.failed;
      await TokenStore.unlock();
      expect(TokenStore.isLocked, isTrue);

      expect((await TokenStore.unlock()).status, ProtectedStatus.success);
      expect(TokenStore.isLocked, isFalse);

      TokenStore.lock();
      await TokenStore.saveSession('test-token-b');
      expect(TokenStore.isLocked, isFalse);

      TokenStore.lock();
      await TokenStore.clearToken();
      expect(TokenStore.isLocked, isFalse);
    });

    test('X2 (S2) a leftover plain item with Face ID on is deleted, never used', () async {
      seedFaceIdOn();
      fakeStore.plain = 'test-token-plain';
      expect(await ApiClient.getToken(), isNull);
      expect(TokenStore.isLocked, isTrue);
      expect(fakeStore.plain, isNull);
    });

    test('X3 (S2) a leftover legacy token with Face ID on is deleted, not migrated', () async {
      SharedPreferences.setMockInitialValues({
        'nexus_keychain_ready': true,
        'nexus_bio_user': 'u1',
        'nexus_bio_token_present': true,
        'nexus_token': 'test-token-legacy',
      });
      fakeStore.protected = 'test-token-a';
      expect(await ApiClient.getToken(), isNull);
      expect((await prefs()).getString('nexus_token'), isNull);
      expect(fakeStore.plain, isNull);
    });

    test('X4 (S2) after save, rotate, enable and disable at most one place holds a token', () async {
      seedPlain();
      await TokenStore.load();
      await TokenStore.saveSession('test-token-b');
      expect(await places(), 1);
      await TokenStore.rotate('test-token-c', before: 'test-token-b');
      expect(await places(), 1);
      await TokenStore.enableProtection('u1');
      expect(await places(), 1);
      await TokenStore.saveSession('test-token-d');
      expect(await places(), 1);
      await TokenStore.rotate('test-token-e', before: 'test-token-d');
      expect(await places(), 1);
      expect(fakeStore.protected, 'test-token-e');
      await TokenStore.disableProtection();
      expect(await places(), 1);
      expect(fakeStore.plain, 'test-token-e');
    });

    test('X7 (S16) deletePlain fails while turning on: the next start is locked and the plain item is gone', () async {
      seedPlain();
      await TokenStore.load();
      fakeStore.throwOnDeletePlain = true;
      await TokenStore.enableProtection('u1');
      expect(fakeStore.plain, 'test-token-a'); // left over for now
      fakeStore.throwOnDeletePlain = false;
      restartApp();
      await TokenStore.load();
      expect(TokenStore.isLocked, isTrue);
      expect(fakeStore.plain, isNull);
      expect(await ApiClient.getToken(), isNull);
    });

    test('S16 enable writes before it sets the flags (read-back with no prompt)', () async {
      seedPlain();
      await TokenStore.load();
      await TokenStore.enableProtection('u1');
      expect(fakeStore.protectedExistsCount, 1);
      expect(fakeStore.readProtectedCount, 0);
    });
  });

  group('X20 (S22) a failed protected write never falls back to plain', () {
    Future<void> expectMemoryOnly(String token) async {
      expect(fakeStore.plain, isNull);
      expect(fakeStore.protected, isNull);
      expect((await prefs()).getString('nexus_token'), isNull);
      expect((await prefs()).getBool('nexus_bio_token_present'), isNull);
      expect((await prefs()).getString('nexus_bio_user'), 'u1');
      expect(fakeStore.writePlainCount, 0);
      expect(await ApiClient.getToken(), token); // this run keeps working
      final reads = fakeStore.readProtectedCount;
      restartApp();
      await TokenStore.load();
      expect(TokenStore.isLocked, isFalse); // signed out, not "locked"
      expect(await ApiClient.getToken(), isNull);
      expect(fakeStore.readProtectedCount, reads); // no prompt on the next start
    }

    test('saveSession', () async {
      seedFaceIdOn();
      await TokenStore.load();
      fakeStore.throwOnWriteProtected = true;
      await TokenStore.saveSession('test-token-b');
      await expectMemoryOnly('test-token-b');
    });

    test('rotate', () async {
      seedFaceIdOn();
      await TokenStore.unlock();
      fakeStore.throwOnWriteProtected = true;
      await TokenStore.rotate('test-token-b', before: 'test-token-a');
      await expectMemoryOnly('test-token-b');
    });

    test('enableProtection throws and leaves Face ID off with the plain item untouched', () async {
      seedPlain();
      await TokenStore.load();
      fakeStore.throwOnWriteProtected = true;
      await expectLater(TokenStore.enableProtection('u1'), throwsA(anything));
      expect(fakeStore.plain, 'test-token-a');
      expect((await prefs()).getString('nexus_bio_user'), isNull);
      expect((await prefs()).getBool('nexus_bio_token_present'), isNull);
      expect(TokenStore.bioUser, isNull);
    });
  });

  group('rotate (S20)', () {
    test('a late answer after sign-out is dropped', () async {
      seedPlain();
      await TokenStore.load();
      await TokenStore.clearToken();
      await TokenStore.rotate('test-token-b', before: 'test-token-a');
      expect(await ApiClient.getToken(), isNull);
      expect(fakeStore.plain, isNull);
    });

    test('while locked it is kept but never unlocks', () async {
      seedFaceIdOn();
      await TokenStore.unlock();
      TokenStore.lock();
      await TokenStore.rotate('test-token-b', before: 'test-token-a');
      expect(await ApiClient.getToken(), isNull);
      expect(TokenStore.isLocked, isTrue);
      expect(fakeStore.protected, 'test-token-b');
      await TokenStore.unlock();
      expect(await ApiClient.getToken(), 'test-token-b');
    });
  });

  test('an unlock that finishes after a new sign-in is dropped', () async {
    seedFaceIdOn();
    await TokenStore.load();
    fakeStore.holdProtected = Completer.sync();
    final pending = TokenStore.unlock();
    await TokenStore.saveSession('test-token-new');
    fakeStore.holdProtected!.complete();
    expect((await pending).status, ProtectedStatus.cancelled);
    expect(await ApiClient.getToken(), 'test-token-new');
  });

  test('a rotation saved while the Face ID prompt is up wins over the token the read returns', () async {
    seedFaceIdOn();
    await TokenStore.load();
    await TokenStore.unlock();
    expect(await ApiClient.getToken(), 'test-token-a');
    TokenStore.lock(); // re-locked while a password change is in flight
    fakeStore.holdProtected = Completer.sync();
    final pending = TokenStore.unlock(); // reads test-token-a, prompt up
    await TokenStore.rotate('test-token-b', before: 'test-token-a');
    fakeStore.holdProtected!.complete();
    final read = await pending;
    expect(read.status, ProtectedStatus.success);
    expect(read.token, 'test-token-a'); // the Keychain answered before the write
    expect(await ApiClient.getToken(), 'test-token-b');
    expect(fakeStore.protected, 'test-token-b');
    expect(TokenStore.isLocked, isFalse);
  });

  test('signed out with Face ID off: the empty plain item is read once, then a save is seen', () async {
    SharedPreferences.setMockInitialValues({'nexus_keychain_ready': true});
    expect(await ApiClient.getToken(), isNull);
    final reads = fakeStore.readPlainCount;
    expect(await ApiClient.getToken(), isNull);
    expect(await ApiClient.getToken(), isNull);
    expect(fakeStore.readPlainCount, reads);
    await TokenStore.saveSession('test-token-a');
    expect(await ApiClient.getToken(), 'test-token-a');
    await TokenStore.clearToken();
    expect(await ApiClient.getToken(), isNull);
  });
}
