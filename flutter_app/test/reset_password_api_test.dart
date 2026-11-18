import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/login_challenge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';

Future<T> withHttp<T>(Future<http.Response> Function(http.Request) handler,
        Future<T> Function() body) =>
    http.runWithClient(body, () => MockClient(handler));

const _forgotBody = {
  'message': 'If an account uses that email, we sent it a code.',
  'expiresInSeconds': 600,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // A saved token must never be sent on these signed-out calls.
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  test('forgotPassword posts only the email, with no Authorization header', () async {
    late http.Request sent;
    await withHttp((req) async {
      sent = req;
      return http.Response(jsonEncode(_forgotBody), 200);
    }, () => ApiClient.forgotPassword('a@nexus.test'));
    expect(sent.method, 'POST');
    expect(sent.url.path, endsWith('/auth/forgot-password'));
    expect(jsonDecode(sent.body), {'email': 'a@nexus.test'});
    expect(sent.headers.containsKey('Authorization'), isFalse);
  });

  test('resetPassword posts email, code and new password; a session body gives a LoginSession', () async {
    late http.Request sent;
    final result = await withHttp((req) async {
      sent = req;
      return http.Response(jsonEncode({'token': 'jwt-new', 'user': userJson()}), 200);
    }, () => ApiClient.resetPassword(email: 'a@nexus.test', code: '123456', newPassword: 'Nexus@2027!'));
    expect(sent.url.path, endsWith('/auth/reset-password'));
    expect(jsonDecode(sent.body),
        {'email': 'a@nexus.test', 'code': '123456', 'newPassword': 'Nexus@2027!'});
    expect(sent.headers.containsKey('Authorization'), isFalse);
    expect(result, isA<LoginSession>());
    expect((result as LoginSession).token, 'jwt-new');
  });

  test('a challenge body gives a LoginChallenge with the email', () async {
    final result = await withHttp((_) async => http.Response(jsonEncode(challengeJson), 200),
        () => ApiClient.resetPassword(email: 'a@nexus.test', code: '123456', newPassword: 'Nexus@2027!'));
    expect(result, isA<LoginChallenge>());
    final c = result as LoginChallenge;
    expect(c.challengeToken, 'challenge-1');
    expect(c.email, 'a@nexus.test');
  });

  test('a 400 is an ApiException with the server text', () async {
    const text = 'That code is wrong or has expired. Check it, or send a new one.';
    final call = withHttp((_) async => http.Response(jsonEncode({'error': text}), 400),
        () => ApiClient.resetPassword(email: 'a@nexus.test', code: '123456', newPassword: 'Nexus@2027!'));
    await expectLater(call, throwsA(isA<ApiException>()
        .having((e) => e.statusCode, 'statusCode', 400)
        .having((e) => e.message, 'message', text)));
  });

  test('a 429 from forgotPassword is an ApiException with the server text', () async {
    const text = 'Too many reset requests. Try again later.';
    final call = withHttp((_) async => http.Response(jsonEncode({'error': text}), 429),
        () => ApiClient.forgotPassword('a@nexus.test'));
    await expectLater(call, throwsA(isA<ApiException>()
        .having((e) => e.statusCode, 'statusCode', 429)
        .having((e) => e.message, 'message', text)));
  });

  test('a connection error becomes the readable "Can\'t reach" message', () async {
    final call = withHttp((_) async => throw http.ClientException('Connection refused'),
        () => ApiClient.forgotPassword('a@nexus.test'));
    await expectLater(call, throwsA(isA<ApiException>().having((e) => e.message, 'message',
        "Can't reach the Nexus server. Check your connection and try again.")));
  });
}
