import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<T> withHttp<T>(Future<http.Response> Function(http.Request) handler,
        Future<T> Function() body) =>
    http.runWithClient(body, () => MockClient(handler));

Map<String, dynamic> userJson({bool phoneVerified = false}) => {
      'id': 'u1', 'email': 'a@nexus.test', 'name': 'A B', 'firstName': 'A', 'lastName': 'B',
      'phone': '+962791234567', 'serialNumber': 'NXS-AAAAA-BBBBB', 'loyaltyPoints': 0,
      'createdAt': '2026-01-01T00:00:00.000Z', 'phoneVerified': phoneVerified,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  test('sendPhoneCode posts to /user/phone/send-code with the token', () async {
    late http.Request sent;
    await withHttp((req) async {
      sent = req;
      return http.Response(jsonEncode({'message': 'Code sent to 079 *** 4567.'}), 200);
    }, ApiClient.sendPhoneCode);
    expect(sent.method, 'POST');
    expect(sent.url.path, endsWith('/user/phone/send-code'));
    expect(sent.headers['Authorization'], 'Bearer t');
  });

  test('verifyPhone sends the code and returns the verified user', () async {
    late http.Request sent;
    final user = await withHttp((req) async {
      sent = req;
      return http.Response(jsonEncode(userJson(phoneVerified: true)), 200);
    }, () => ApiClient.verifyPhone('123456'));
    expect(sent.url.path, endsWith('/user/phone/verify'));
    expect(jsonDecode(sent.body), {'code': '123456'});
    expect(user.phoneVerified, isTrue);
  });

  test('a 400 with a reason fills ApiException.reason', () async {
    const msg = "This number can't receive Nexus SMS yet: our demo SMS account can only text the team's numbers.";
    final err = await withHttp(
      (_) async => http.Response(jsonEncode({'error': msg, 'reason': 'trialOnly'}), 400),
      ApiClient.sendPhoneCode,
    ).then<Object?>((_) => null, onError: (Object e) => e);
    expect(err, isA<ApiException>());
    final e = err as ApiException;
    expect(e.statusCode, 400);
    expect(e.message, msg);
    expect(e.reason, 'trialOnly');
    expect(e.fromServer, isTrue);
  });

  test('reason is null when the body has none (or not a string)', () async {
    final err = await withHttp(
      (_) async => http.Response(jsonEncode({'error': 'Please wait 30s before requesting a new code.', 'waitSeconds': 30}), 429),
      ApiClient.sendPhoneCode,
    ).then<Object?>((_) => null, onError: (Object e) => e) as ApiException;
    expect(err.statusCode, 429);
    expect(err.reason, isNull);

    final odd = await withHttp(
      (_) async => http.Response(jsonEncode({'error': 'x', 'reason': 7}), 400),
      ApiClient.sendPhoneCode,
    ).then<Object?>((_) => null, onError: (Object e) => e) as ApiException;
    expect(odd.reason, isNull);
  });

  test('a wrong code surfaces the server message', () async {
    final err = await withHttp(
      (_) async => http.Response(jsonEncode({'error': 'Incorrect code. 4 attempts left.'}), 400),
      () => ApiClient.verifyPhone('000000'),
    ).then<Object?>((_) => null, onError: (Object e) => e) as ApiException;
    expect(err.message, 'Incorrect code. 4 attempts left.');
  });
}
