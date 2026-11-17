import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/login_challenge.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';

Future<T> withHttp<T>(Future<http.Response> Function(http.Request) handler,
        Future<T> Function() body) =>
    http.runWithClient(body, () => MockClient(handler));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  test('a { token, user } body gives a LoginSession; the request body is only email and password', () async {
    late http.Request sent;
    final result = await withHttp((req) async {
      sent = req;
      return http.Response(jsonEncode({'token': 'jwt', 'user': userJson()}), 200);
    }, () => ApiClient.login(email: 'a@nexus.test', password: 'pw'));
    expect(sent.url.path, endsWith('/auth/login'));
    expect(jsonDecode(sent.body), {'email': 'a@nexus.test', 'password': 'pw'});
    expect(sent.headers.containsKey('Authorization'), isFalse);
    expect(result, isA<LoginSession>());
    final session = result as LoginSession;
    expect(session.token, 'jwt');
    expect(session.user.loginTwoFactor, isFalse);
  });

  test('a challenge body gives a LoginChallenge with the typed email', () async {
    final result = await withHttp((_) async => http.Response(jsonEncode(challengeJson), 200),
        () => ApiClient.login(email: 'a@nexus.test', password: 'pw'));
    expect(result, isA<LoginChallenge>());
    final c = result as LoginChallenge;
    expect(c.challengeToken, 'challenge-1');
    expect(c.email, 'a@nexus.test');
  });

  test('sendLoginCode posts the challenge without an Authorization header', () async {
    late http.Request sent;
    await withHttp((req) async {
      sent = req;
      return http.Response(jsonEncode({'message': 'Code sent to a@nexus.test.'}), 200);
    }, () => ApiClient.sendLoginCode('challenge-1'));
    expect(sent.method, 'POST');
    expect(sent.url.path, endsWith('/auth/login/send-code'));
    expect(jsonDecode(sent.body), {'challengeToken': 'challenge-1'});
    expect(sent.headers.containsKey('Authorization'), isFalse);
  });

  test('verifyLogin posts challenge and code without auth and returns the session', () async {
    late http.Request sent;
    final res = await withHttp((req) async {
      sent = req;
      return http.Response(jsonEncode({'token': 'jwt-2', 'user': userJson(twoFactor: true)}), 200);
    }, () => ApiClient.verifyLogin('challenge-1', '123456'));
    expect(sent.url.path, endsWith('/auth/login/verify'));
    expect(jsonDecode(sent.body), {'challengeToken': 'challenge-1', 'code': '123456'});
    expect(sent.headers.containsKey('Authorization'), isFalse);
    expect(res.token, 'jwt-2');
    expect(res.user.loginTwoFactor, isTrue);
  });

  test('a 401 from verifyLogin is an ApiException with the server text', () async {
    final call = withHttp(
        (_) async => http.Response(jsonEncode({'error': 'Your sign-in expired. Please log in again.'}), 401),
        () => ApiClient.verifyLogin('old', '123456'));
    await expectLater(call, throwsA(isA<ApiException>()
        .having((e) => e.statusCode, 'statusCode', 401)
        .having((e) => e.message, 'message', 'Your sign-in expired. Please log in again.')));
  });

  test('setLoginTwoFactor(false, currentPassword) sends PATCH /user/security with auth and both fields', () async {
    late http.Request sent;
    final user = await withHttp((req) async {
      sent = req;
      return http.Response(jsonEncode(userJson()), 200);
    }, () => ApiClient.setLoginTwoFactor(false, currentPassword: 'x'));
    expect(sent.method, 'PATCH');
    expect(sent.url.path, endsWith('/user/security'));
    expect(sent.headers['Authorization'], 'Bearer t');
    expect(jsonDecode(sent.body), {'loginTwoFactor': false, 'currentPassword': 'x'});
    expect(user.loginTwoFactor, isFalse);
  });

  test('setLoginTwoFactor(true) sends no password field', () async {
    late http.Request sent;
    await withHttp((req) async {
      sent = req;
      return http.Response(jsonEncode(userJson(twoFactor: true)), 200);
    }, () => ApiClient.setLoginTwoFactor(true));
    expect(jsonDecode(sent.body), {'loginTwoFactor': true});
  });

  test('User.fromJson without loginTwoFactor reads false; toJson/copyWith keep it', () {
    final json = userJson()..remove('loginTwoFactor');
    final user = User.fromJson(json);
    expect(user.loginTwoFactor, isFalse);
    final on = user.copyWith(loginTwoFactor: true);
    expect(on.loginTwoFactor, isTrue);
    expect(User.fromJson(on.toJson()).loginTwoFactor, isTrue);
  });

  // Audit L2: these three changes end older sessions and return this device's new token.
  group('a new session token in the answer is saved', () {
    final calls = <String, Future<void> Function()>{
      'changePassword': () => ApiClient.changePassword(currentPassword: 'Old@2026', newPassword: 'New@2026'),
      'updateProfile (email)': () => ApiClient.updateProfile(
          firstName: 'Sara', lastName: 'Ali', email: 'new@nexus.test', currentPassword: 'Old@2026'),
      'setLoginTwoFactor(true)': () => ApiClient.setLoginTwoFactor(true),
    };
    final bodies = <String, Map<String, dynamic>>{
      'changePassword': {'message': 'Password updated.'},
      'updateProfile (email)': userJson(email: 'new@nexus.test', verified: false),
      'setLoginTwoFactor(true)': userJson(twoFactor: true),
    };

    for (final name in calls.keys) {
      test('$name with a token: getToken() returns the new one', () async {
        await withHttp((req) async {
          expect(req.headers['Authorization'], 'Bearer t'); // sent with the old one
          return http.Response(jsonEncode({...bodies[name]!, 'token': 'new-jwt'}), 200);
        }, calls[name]!);
        expect(await ApiClient.getToken(), 'new-jwt');
      });

      test('$name without a token: the saved token is unchanged', () async {
        await withHttp((_) async => http.Response(jsonEncode(bodies[name]), 200), calls[name]!);
        expect(await ApiClient.getToken(), 't');
      });

      // Code review 8, finding 1: a late answer must not undo a logout or
      // replace the next account's session.
      Future<void> answerLateAfter(Future<void> Function() meanwhile) async {
        final seen = Completer<void>();
        final release = Completer<void>();
        final done = withHttp((_) async {
          seen.complete();
          await release.future;
          return http.Response(jsonEncode({...bodies[name]!, 'token': 'new-jwt'}), 200);
        }, calls[name]!);
        await seen.future;
        await meanwhile();
        release.complete();
        await done;
      }

      test('$name answered after a logout: the token stays cleared', () async {
        await answerLateAfter(ApiClient.clearToken);
        expect(await ApiClient.getToken(), isNull);
      });

      test('$name answered after another sign-in: that sign-in keeps its token', () async {
        await answerLateAfter(() => ApiClient.saveToken('other-user'));
        expect(await ApiClient.getToken(), 'other-user');
      });
    }

    test('the token never ends up in the user JSON', () async {
      final updated = await withHttp(
          (_) async => http.Response(jsonEncode({...userJson(twoFactor: true), 'token': 'new-jwt'}), 200),
          () => ApiClient.setLoginTwoFactor(true));
      expect(updated.toJson().containsKey('token'), isFalse);
    });
  });

  test('logoutAll posts to /user/logout-all with the session token', () async {
    late http.Request sent;
    await withHttp((req) async {
      sent = req;
      return http.Response(jsonEncode({'message': 'Signed out on all devices.'}), 200);
    }, ApiClient.logoutAll);
    expect(sent.method, 'POST');
    expect(sent.url.path, endsWith('/user/logout-all'));
    expect(sent.headers['Authorization'], 'Bearer t');
  });
}
