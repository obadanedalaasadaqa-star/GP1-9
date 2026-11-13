import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/budget_models.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/budget_fixtures.dart';

Future<T> withHttp<T>(Future<http.Response> Function(http.Request) handler,
        Future<T> Function() body) =>
    http.runWithClient(body, () => MockClient(handler));

Future<http.Response> noInternet(http.Request _) async =>
    throw const SocketException('Failed host lookup');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  final tz = '${DateTime.now().timeZoneOffset.inMinutes}';
  final listBody = jsonEncode(budgetListJson(budgets: [budgetJson('Food', 50, 10)]));

  test('GET sends tzOffsetMinutes and the token; the list is saved', () async {
    late http.Request sent;
    final res = await withHttp((req) async {
      sent = req;
      return http.Response(listBody, 200);
    }, ApiClient.loadBudgets);
    expect(sent.method, 'GET');
    expect(sent.url.path, endsWith('/budgets'));
    expect(sent.url.queryParameters['tzOffsetMinutes'], tz);
    expect(sent.headers['Authorization'], 'Bearer t');
    expect(res.offline, isFalse);
    expect(res.list.budgets.single.category, 'Food');
    expect((await OfflineCache.loadBudgets())!.budgets.single.limit, 50);
  });

  test('PUT body has category, limit and tz', () async {
    late http.Request sent;
    await withHttp((req) async {
      sent = req;
      return http.Response(listBody, 200);
    }, () => ApiClient.saveBudget('Food', 12.5));
    expect(sent.method, 'PUT');
    expect(jsonDecode(sent.body), {'category': 'Food', 'limit': 12.5, 'tzOffsetMinutes': int.parse(tz)});
  });

  test('DELETE encodes the category', () async {
    late http.Request sent;
    await withHttp((req) async {
      sent = req;
      return http.Response(listBody, 200);
    }, () => ApiClient.deleteBudget('Food & Drinks'));
    expect(sent.method, 'DELETE');
    expect(sent.url.path, endsWith('/budgets/Food%20%26%20Drinks'));
    expect(sent.url.pathSegments.last, 'Food & Drinks');
  });

  test('a 400 surfaces the server text', () async {
    await expectLater(
      withHttp((_) async => http.Response(jsonEncode({'error': 'You can have up to 20 budgets.'}), 400),
          () => ApiClient.saveBudget('X', 5)),
      throwsA(isA<ApiException>()
          .having((e) => e.message, 'message', 'You can have up to 20 budgets.')
          .having((e) => e.fromServer, 'fromServer', isTrue)
          .having((e) => e.statusCode, 'statusCode', 400)),
    );
  });

  test('offline: the saved list, marked offline; nothing saved: a friendly error', () async {
    await expectLater(withHttp(noInternet, ApiClient.loadBudgets), throwsA(isA<ApiException>()));
    await OfflineCache.saveBudgets(BudgetList.fromJson(jsonDecode(listBody) as Map<String, dynamic>));
    final res = await withHttp(noInternet, ApiClient.loadBudgets);
    expect(res.offline, isTrue);
    expect(res.savedAt, isNotNull);
    expect(res.list.budgets.single.category, 'Food');
  });

  test('a server error is not hidden by the cache', () async {
    await OfflineCache.saveBudgets(BudgetList.fromJson(jsonDecode(listBody) as Map<String, dynamic>));
    await expectLater(
      withHttp((_) async => http.Response(jsonEncode({'error': 'Unauthorized'}), 401),
          ApiClient.loadBudgets),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401)),
    );
  });

  test('updateNotifications sends only the changed field plus tz', () async {
    late http.Request sent;
    final user = await withHttp((req) async {
      sent = req;
      return http.Response(jsonEncode({
        'id': 'u1', 'email': 'a@nexus.test', 'name': 'A B', 'firstName': 'A', 'lastName': 'B',
        'serialNumber': 'NXS-AAAAA-BBBBB', 'loyaltyPoints': 3, 'createdAt': '2026-01-01T00:00:00.000Z',
        'emailVerified': true, 'budgetAlertEmails': true, 'weeklySummaryEmails': true,
      }), 200);
    }, () => ApiClient.updateNotifications(weeklySummaryEmails: true));
    expect(sent.method, 'PATCH');
    expect(sent.url.path, endsWith('/user/notifications'));
    expect(jsonDecode(sent.body), {'weeklySummaryEmails': true, 'tzOffsetMinutes': int.parse(tz)});
    expect(user.weeklySummaryEmails, isTrue);
  });

  test('OfflineCache.clear() wipes the budgets', () async {
    await OfflineCache.saveBudgets(BudgetList.fromJson(jsonDecode(listBody) as Map<String, dynamic>));
    await OfflineCache.clear();
    expect(await OfflineCache.loadBudgets(), isNull);
    expect(await OfflineCache.budgetsSavedAt(), isNull);
  });
}
