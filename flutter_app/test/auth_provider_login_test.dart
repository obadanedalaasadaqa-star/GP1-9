import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';

Future<T> withHttp<T>(Future<http.Response> Function(http.Request) handler,
        Future<T> Function() body) =>
    http.runWithClient(body, () => MockClient(handler));

/// A logged-out provider that finished its startup.
Future<AuthProvider> loggedOut() async {
  SharedPreferences.setMockInitialValues({});
  final auth = AuthProvider();
  while (auth.loading) {
    await Future<void>.delayed(Duration.zero);
  }
  return auth;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a challenge leaves the user logged out and saves no token', () async {
    final auth = await loggedOut();
    var notified = 0;
    auth.addListener(() => notified++);
    final challenge = await withHttp((_) async => http.Response(jsonEncode(challengeJson), 200),
        () => auth.login('a@nexus.test', 'pw'));
    expect(challenge, isNotNull);
    expect(challenge!.challengeToken, 'challenge-1');
    expect(challenge.email, 'a@nexus.test');
    expect(auth.isLoggedIn, isFalse);
    expect(await ApiClient.getToken(), isNull);
    expect(notified, 0);
  });

  test('completeLogin saves the token and the user and notifies', () async {
    final auth = await loggedOut();
    var notified = 0;
    auth.addListener(() => notified++);
    await auth.completeLogin('jwt-2', User.fromJson(userJson(twoFactor: true)));
    expect(auth.isLoggedIn, isTrue);
    expect(auth.user!.loginTwoFactor, isTrue);
    expect(await ApiClient.getToken(), 'jwt-2');
    expect(notified, 1);
    expect(auth.consumeJustRegistered(), isFalse);
  });

  test('a session login behaves as before (returns null, logged in)', () async {
    final auth = await loggedOut();
    final challenge = await withHttp(
        (_) async => http.Response(jsonEncode({'token': 'jwt', 'user': userJson()}), 200),
        () => auth.login('a@nexus.test', 'pw'));
    expect(challenge, isNull);
    expect(auth.isLoggedIn, isTrue);
    expect(await ApiClient.getToken(), 'jwt');
  });

  // Audit L14: nothing of account A comes back after logout.
  group('late answers after the account changed', () {
    test('a refreshUser answered after logout leaves the user out and caches nothing', () async {
      final auth = await loggedOut();
      await auth.completeLogin('tA', User.fromJson(userJson(id: 'uA')));
      final requested = Completer<void>();
      final reply = Completer<http.Response>();
      final refresh = withHttp((_) {
        requested.complete();
        return reply.future;
      }, () => auth.refreshUser());
      await requested.future;
      await auth.logout();
      reply.complete(http.Response(jsonEncode(userJson(id: 'uA')), 200));
      await refresh;
      expect(auth.user, isNull);
      expect(await OfflineCache.loadUser(), isNull);
    });

    test('updateUser after logout is ignored', () async {
      final auth = await loggedOut();
      final a = User.fromJson(userJson(id: 'uA'));
      await auth.completeLogin('tA', a);
      await auth.logout();
      var notified = 0;
      auth.addListener(() => notified++);
      auth.updateUser(a);
      await Future<void>.delayed(Duration.zero);
      expect(auth.user, isNull);
      expect(await OfflineCache.loadUser(), isNull);
      expect(notified, 0);
    });

    test('updateUser for another account than the signed-in one is ignored', () async {
      final auth = await loggedOut();
      await auth.completeLogin('tB', User.fromJson(userJson(id: 'uB', email: 'b@nexus.test')));
      auth.updateUser(User.fromJson(userJson(id: 'uA')));
      await Future<void>.delayed(Duration.zero);
      expect(auth.user!.id, 'uB');
      expect((await OfflineCache.loadUser())!.id, 'uB');
    });

    test('updateUser for the signed-in account still works', () async {
      final auth = await loggedOut();
      await auth.completeLogin('tA', User.fromJson(userJson(id: 'uA')));
      auth.updateUser(User.fromJson(userJson(id: 'uA', twoFactor: true)));
      expect(auth.user!.loginTwoFactor, isTrue);
    });
  });
}
