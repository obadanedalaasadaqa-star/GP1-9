import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:nexus_app/core/stats_model.dart';
import 'package:nexus_app/core/trends.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:nexus_app/widgets/offline_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

User user(String id) => User(
      id: id, email: '$id@nexus.test', name: 'Obada Test', firstName: 'Obada',
      lastName: 'Test', serialNumber: 'NXS-AAAAA-BBBBB', loyaltyPoints: 12,
      createdAt: DateTime.utc(2026, 1, 1));

/// Server-style stats for the 6 months ending with the month of [now].
SpendingStats statsFor(DateTime now, {double currentTotal = 110}) {
  final b = monthBounds(now);
  return SpendingStats([
    for (var i = 0; i < b.length - 1; i++)
      PeriodStats(
        from: b[i], to: b[i + 1],
        total: i == b.length - 2 ? currentTotal : 100,
        count: 2, average: 50,
        byCategory: const [CategoryStat(category: 'Food', total: 100, count: 2)],
        topStore: const StoreStat(storeName: 'KFC', total: 100, count: 2),
      ),
  ]);
}

Future<T> withHttp<T>(Future<http.Response> Function(http.Request) handler,
        Future<T> Function() body) =>
    http.runWithClient(body, () => MockClient(handler));

Future<http.Response> noInternet(http.Request _) async =>
    throw const SocketException('Failed host lookup');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  final now = DateTime(2026, 11, 8);
  final bounds = monthBounds(now);
  final online = statsFor(now);

  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  test('online: stats are returned and saved; bounds has 7 UTC values', () async {
    Uri? sent;
    final res = await withHttp((req) async {
      sent = req.url;
      return http.Response(jsonEncode(online.toJson()), 200);
    }, () => ApiClient.loadStats(bounds));

    expect(res.offline, isFalse);
    expect(res.stats.current.total, 110);
    expect(sent!.path, endsWith('/user/stats'));
    final parts = sent!.queryParameters['bounds']!.split(',');
    expect(parts, hasLength(7));
    expect(parts.every((p) => p.endsWith('Z')), isTrue);
    expect(parts.map(DateTime.parse), bounds.map((b) => b.toUtc()));
    expect((await OfflineCache.loadStats())!.current.total, 110);
  });

  test('offline after an online load: the saved stats with offline and savedAt', () async {
    await withHttp((_) async => http.Response(jsonEncode(online.toJson()), 200),
        () => ApiClient.loadStats(bounds));
    final res = await withHttp(noInternet, () => ApiClient.loadStats(bounds));
    expect(res.offline, isTrue);
    expect(res.savedAt, isNotNull);
    expect(res.stats.current.total, 110);
  });

  test('a timeout or an HTML 502 also falls back to the cache', () async {
    await OfflineCache.saveStats(online);
    final html = await withHttp(
        (_) async => http.Response('<html>Bad gateway</html>', 502),
        () => ApiClient.loadStats(bounds));
    expect(html.offline, isTrue);

    // A reply that never comes hits the real 15 s timeout.
    final never = Completer<http.Response>();
    final slow = await withHttp((_) => never.future, () => ApiClient.loadStats(bounds));
    expect(slow.offline, isTrue);
    expect(slow.stats.current.total, 110);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a JSON 400 / 401 is rethrown and the cache is not used', () async {
    await OfflineCache.saveStats(online);
    for (final code in [400, 401]) {
      await expectLater(
        withHttp((_) async => http.Response(jsonEncode({'error': 'Nope.'}), code),
            () => ApiClient.loadStats(bounds)),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'status', code)
            .having((e) => e.fromServer, 'fromServer', isTrue)),
      );
    }
  });

  test('offline with nothing saved: the friendly error', () async {
    await expectLater(
      withHttp(noInternet, () => ApiClient.loadStats(bounds)),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', contains("Can't reach the Nexus server"))),
    );
  });

  test('another account signing in and clear() remove the saved stats', () async {
    await OfflineCache.saveUser(user('u1'));
    await OfflineCache.saveStats(online);
    await OfflineCache.saveUser(user('u1')); // same account keeps them
    expect(await OfflineCache.loadStats(), isNotNull);
    await OfflineCache.saveUser(user('u2'));
    expect(await OfflineCache.loadStats(), isNull);
    expect(await OfflineCache.statsSavedAt(), isNull);

    await OfflineCache.saveStats(online);
    await OfflineCache.clear();
    expect(await OfflineCache.loadStats(), isNull);
  });

  testWidgets('OfflineBanner says "trends" when asked, "receipts" by default', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Column(children: [
      OfflineBanner(what: 'trends'),
      OfflineBanner(),
    ]))));
    expect(find.textContaining('Showing trends saved on this phone'), findsOneWidget);
    expect(find.textContaining('Showing receipts saved on this phone'), findsOneWidget);
  });
}
