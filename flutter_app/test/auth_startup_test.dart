import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Starts an AuthProvider with a saved token while /user/me answers with
/// [status] and [body], and waits for the startup check to finish.
Future<AuthProvider> startWith(int status, String body, {String type = 'application/json'}) async {
  SharedPreferences.setMockInitialValues({'nexus_token': 'saved-token'});
  final client = MockClient((_) async => http.Response(body, status, headers: {'content-type': type}));
  return http.runWithClient(() async {
    final auth = AuthProvider();
    while (auth.loading) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return auth;
  }, () => client);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('JSON 404 from our server (account deleted) clears the token', () async {
    final auth = await startWith(404, jsonEncode({'error': 'User not found.'}));
    expect(auth.isLoggedIn, isFalse);
    expect(auth.startupError, isNull);
    expect(await ApiClient.getToken(), isNull);
  });

  test('HTML 404 (host missing or suspended) keeps the token and shows Retry', () async {
    final auth = await startWith(404, '<html><body>Not Found</body></html>', type: 'text/html');
    expect(auth.isLoggedIn, isFalse);
    expect(auth.startupError, isNotNull);
    expect(await ApiClient.getToken(), 'saved-token');
  });

  test('401 clears the token', () async {
    final auth = await startWith(401, jsonEncode({'error': 'Invalid or expired token.'}));
    expect(auth.startupError, isNull);
    expect(await ApiClient.getToken(), isNull);
  });

  test('a 500 keeps the token and shows Retry', () async {
    final auth = await startWith(500, jsonEncode({'error': 'Failed to load profile.'}));
    expect(auth.startupError, 'Failed to load profile.');
    expect(await ApiClient.getToken(), 'saved-token');
  });
}
