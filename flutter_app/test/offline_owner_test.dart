import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/ai_models.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:nexus_app/core/stats_model.dart';
import 'package:nexus_app/core/trends.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/report_json.dart';
import 'support/auth_fixtures.dart';
import 'support/budget_fixtures.dart';

// Audit L14: an answer that arrives after logout must never land in the next
// account's offline cache.

final userA = User.fromJson(userJson(id: 'uA', email: 'a@nexus.test'));
final userB = User.fromJson(userJson(id: 'uB', email: 'b@nexus.test'));
final bounds = monthBounds(DateTime(2026, 11, 8));

Map<String, dynamic> statsJson() => SpendingStats([
      for (var i = 0; i < bounds.length - 1; i++)
        PeriodStats(
          from: bounds[i], to: bounds[i + 1], total: 10, count: 1, average: 10,
          byCategory: const [CategoryStat(category: 'Food', total: 10, count: 1)],
          topStore: const StoreStat(storeName: 'KFC', total: 10, count: 1),
        ),
    ]).toJson();

final receiptsJson = [
  {
    'id': 'rA', 'storeName': 'KFC', 'category': 'Food', 'totalAmount': 5.0,
    'items': ['Meal'], 'pointsEarned': 5, 'createdAt': '2026-11-03T10:00:00.000Z',
  },
];

final insightJson = {'status': 'ready', 'summary': 'A summary.', 'tip': 'A tip.'};

/// A signed-in provider for [user] with an empty phone.
Future<AuthProvider> signedIn(User user, String token) async {
  final auth = AuthProvider();
  while (auth.loading) {
    await Future<void>.delayed(Duration.zero);
  }
  await auth.completeLogin(token, user);
  return auth;
}

/// Starts [load] as account A with its answer held back, logs out while the
/// request is in flight, then lets the answer ([body]) arrive.
Future<void> loadAcrossLogout(AuthProvider auth, Object body, Future<void> Function() load) async {
  final requested = Completer<void>();
  final reply = Completer<http.Response>();
  final done = http.runWithClient(load, () => MockClient((_) {
        if (!requested.isCompleted) requested.complete();
        return reply.future;
      }));
  await requested.future;
  await auth.logout();
  reply.complete(http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
      headers: {'content-type': 'application/json; charset=utf-8'}));
  await done;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('control: an answer that arrives while still signed in is saved', () async {
    await signedIn(userA, 'tA');
    await http.runWithClient(() => ApiClient.loadStats(bounds),
        () => MockClient((_) async => http.Response(jsonEncode(statsJson()), 200)));
    expect(await OfflineCache.loadStats(), isNotNull);
  });

  test('1: loadStats answered after logout saves nothing, before or after B signs in', () async {
    final auth = await signedIn(userA, 'tA');
    await loadAcrossLogout(auth, statsJson(), () => ApiClient.loadStats(bounds));
    expect(await OfflineCache.loadStats(), isNull); // the generation check itself
    await auth.completeLogin('tB', userB);
    expect(await OfflineCache.loadStats(), isNull);
  });

  group('2: the other loads answered after logout', () {
    test('loadReceipts', () async {
      final auth = await signedIn(userA, 'tA');
      await loadAcrossLogout(auth, receiptsJson, () => ApiClient.loadReceipts());
      expect(await OfflineCache.loadReceipts(), isNull);
      await auth.completeLogin('tB', userB);
      final cached = await OfflineCache.loadReceipts();
      expect(cached?.map((r) => r.id) ?? const <String>[], isNot(contains('rA')));
    });

    test('loadInsight', () async {
      final auth = await signedIn(userA, 'tA');
      await loadAcrossLogout(auth, insightJson, () => ApiClient.loadInsight(bounds));
      expect(await OfflineCache.loadInsight(), isNull);
      await auth.completeLogin('tB', userB);
      expect(await OfflineCache.loadInsight(), isNull);
    });

    test('loadReport', () async {
      const r = ReportRequest(ReportPeriod.oneMonth);
      final auth = await signedIn(userA, 'tA');
      await loadAcrossLogout(auth, reportJson(), () => ApiClient.loadReport(r));
      expect(await OfflineCache.loadReport(r.cacheKey), isNull);
      await auth.completeLogin('tB', userB);
      expect(await OfflineCache.loadReport(r.cacheKey), isNull);
    });

    test('loadBudgets', () async {
      final auth = await signedIn(userA, 'tA');
      await loadAcrossLogout(auth, budgetListJson(budgets: [budgetJson('Food', 50, 10)]),
          () => ApiClient.loadBudgets());
      expect(await OfflineCache.loadBudgets(), isNull);
      await auth.completeLogin('tB', userB);
      expect(await OfflineCache.loadBudgets(), isNull);
    });

    test('saveBudget', () async {
      final auth = await signedIn(userA, 'tA');
      await loadAcrossLogout(auth, budgetListJson(budgets: [budgetJson('Food', 50, 10)]),
          () => ApiClient.saveBudget('Food', 50));
      expect(await OfflineCache.loadBudgets(), isNull);
      await auth.completeLogin('tB', userB);
      expect(await OfflineCache.loadBudgets(), isNull);
    });
  });

  test('3: account data with no saved profile is wiped when a user is saved', () async {
    await OfflineCache.saveStats(SpendingStats.fromJson(statsJson()), generation: OfflineCache.generation);
    expect(await OfflineCache.loadStats(), isNotNull);
    await OfflineCache.saveUser(userB);
    expect(await OfflineCache.loadStats(), isNull);
  });

  test('4: a save with an old generation writes nothing', () async {
    await OfflineCache.saveUser(userA);
    await OfflineCache.saveStats(SpendingStats.fromJson(statsJson()),
        generation: OfflineCache.generation - 1);
    expect(await OfflineCache.loadStats(), isNull);
    expect(await OfflineCache.statsSavedAt(), isNull);
  });
}
