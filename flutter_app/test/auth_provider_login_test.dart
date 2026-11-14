import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/auth_provider.dart';
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
}
