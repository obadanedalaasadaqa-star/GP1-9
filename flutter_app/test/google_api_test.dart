import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/google_sign_in_result.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';

// Phase 12: User.passwordSet and ApiClient.googleSignIn (A1-A6).
Future<T> withHttp<T>(Future<http.Response> Function(http.Request) handler, Future<T> Function() body) =>
    http.runWithClient(body, () => MockClient(handler));

http.Response json(Object body, int status) => http.Response(jsonEncode(body), status);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  group('A1 User.passwordSet', () {
    test('parsed, true when missing, in toJson and copyWith', () {
      expect(User.fromJson({...userJson(), 'passwordSet': false}).passwordSet, isFalse);
      expect(User.fromJson(userJson()).passwordSet, isTrue);
      final u = User.fromJson({...userJson(), 'passwordSet': false});
      expect(u.toJson()['passwordSet'], isFalse);
      expect(User.fromJson(u.toJson()).passwordSet, isFalse);
      expect(u.copyWith(passwordSet: true).passwordSet, isTrue);
      expect(u.copyWith(firstName: 'X').passwordSet, isFalse);
    });
  });

  group('googleSignIn', () {
    test('A2 posts only the token (no Authorization); 200 → session, 201 → created', () async {
      late http.Request sent;
      final r = await withHttp((req) async {
        sent = req;
        return json({'token': 'jwt', 'user': userJson()}, 200);
      }, () => ApiClient.googleSignIn('g-token'));
      expect(sent.url.path, endsWith('/auth/google'));
      expect(jsonDecode(sent.body), {'idToken': 'g-token'});
      expect(sent.headers.containsKey('Authorization'), isFalse);
      expect(r, isA<GoogleSession>());
      expect((r as GoogleSession).created, isFalse);
      expect(r.token, 'jwt');

      final made = await withHttp((_) async => json({'token': 'jwt', 'user': userJson(), 'created': true}, 201),
          () => ApiClient.googleSignIn('g-token'));
      expect((made as GoogleSession).created, isTrue);
    });

    test('the password step sends the password too', () async {
      late http.Request sent;
      await withHttp((req) async {
        sent = req;
        return json({'token': 'jwt', 'user': userJson()}, 200);
      }, () => ApiClient.googleSignIn('g-token', password: 'Nexus@2026'));
      expect(jsonDecode(sent.body), {'idToken': 'g-token', 'password': 'Nexus@2026'});
    });

    test('A3 a 2FA body → GoogleChallenge with the Google email', () async {
      final r = await withHttp((_) async => json(challengeJson, 200),
          () => ApiClient.googleSignIn('g-token', email: 'g@nexus.test'));
      expect(r, isA<GoogleChallenge>());
      final c = (r as GoogleChallenge).challenge;
      expect(c.challengeToken, 'challenge-1');
      expect(c.email, 'g@nexus.test');
    });

    test('A3b the challenge names the stored Nexus email the server gives, not the Google one', () async {
      final r = await withHttp((_) async => json({...challengeJson, 'email': 'nexus@nexus.test'}, 200),
          () => ApiClient.googleSignIn('g-token', email: 'g@nexus.test'));
      expect((r as GoogleChallenge).challenge.email, 'nexus@nexus.test');
      final empty = await withHttp((_) async => json({...challengeJson, 'email': ''}, 200),
          () => ApiClient.googleSignIn('g-token', email: 'g@nexus.test'));
      expect((empty as GoogleChallenge).challenge.email, 'g@nexus.test');
    });

    test('A4 409 / 401 password_required → GooglePasswordNeeded', () async {
      const need = 'This email already has a Nexus account. Enter its password once to connect Google.';
      const wrong = "That password doesn't match. Try again, or tap Forgot password.";
      final first = await withHttp(
          (_) async => json({'error': need, 'code': 'password_required', 'email': 'a@nexus.test'}, 409),
          () => ApiClient.googleSignIn('g-token'));
      expect(first, isA<GooglePasswordNeeded>());
      first as GooglePasswordNeeded;
      expect(first.wrongPassword, isFalse);
      expect(first.email, 'a@nexus.test');
      expect(first.message, need);
      final again = await withHttp(
          (_) async => json({'error': wrong, 'code': 'password_required', 'email': 'a@nexus.test'}, 401),
          () => ApiClient.googleSignIn('g-token', password: 'x'));
      expect((again as GooglePasswordNeeded).wrongPassword, isTrue);
      expect(again.message, wrong);
    });

    test('A5 other refusals → ApiException with status and code; network → the unreachable text', () async {
      final cases = <(int, Map<String, Object>)>[
        (403, {'error': "Your Google email isn't verified yet.", 'code': 'google_email_unverified'}),
        (409, {'error': 'Other Google.', 'code': 'other_google'}),
        (429, {'error': 'Too many sign-in attempts. Try again in a few minutes.'}),
        (503, {'error': "Google sign-in isn't available right now."}),
        (500, {'error': "Sign-in didn't go through. Try again."}),
        (401, {'error': "Google sign-in didn't go through. Try again."}),
      ];
      for (final (status, body) in cases) {
        try {
          await withHttp((_) async => json(body, status), () => ApiClient.googleSignIn('g-token'));
          fail('expected an ApiException for $status');
        } on ApiException catch (e) {
          expect(e.statusCode, status);
          expect(e.message, body['error']);
          expect(e.code, body['code']);
          expect(e.fromServer, isTrue);
        }
      }
      try {
        await withHttp((_) async => throw http.ClientException('offline'), () => ApiClient.googleSignIn('g-token'));
        fail('expected an ApiException');
      } on ApiException catch (e) {
        expect(e.message, "Can't reach the Nexus server. Check your connection and try again.");
        expect(e.fromServer, isFalse);
      }
    });

    test('A6 ApiException.code defaults to null', () {
      expect(ApiException('x').code, isNull);
      expect(ApiException('x', statusCode: 400).code, isNull);
    });
  });
}
