import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:nexus_app/core/stats_model.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/core/trends.dart';
import 'package:nexus_app/screens/trends_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _abbr = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

/// Stats for [bounds]: older months 100 JD, the current one [current] JD
/// (Food 60 + Supermarket 50 by default), top store KFC, average 65 (+30%).
Map<String, dynamic> statsJson(List<DateTime> bounds,
    {double current = 110, int count = 2, bool empty = false}) {
  final periods = <PeriodStats>[];
  for (var i = 0; i < bounds.length - 1; i++) {
    final isCurrent = i == bounds.length - 2;
    periods.add(empty
        ? PeriodStats(from: bounds[i], to: bounds[i + 1], total: 0, count: 0, average: 0)
        : PeriodStats(
            from: bounds[i], to: bounds[i + 1],
            total: isCurrent ? current : 100,
            count: count,
            average: isCurrent ? 65 : 50,
            byCategory: isCurrent
                ? const [CategoryStat(category: 'Food', total: 60, count: 1),
                         CategoryStat(category: 'Supermarket', total: 50, count: 1)]
                : const [CategoryStat(category: 'Food', total: 100, count: 2)],
            topStore: StoreStat(storeName: isCurrent ? 'KFC' : 'Cozmo', total: 60, count: 1),
          ));
  }
  return SpendingStats(periods).toJson();
}

/// Answers /user/stats for whatever bounds the screen sent.
Future<http.Response> Function(http.Request) online(
        {double current = 110, bool empty = false}) =>
    (req) async {
      final bounds = req.url.queryParameters['bounds']!.split(',').map(DateTime.parse).toList();
      return http.Response(jsonEncode(statsJson(bounds, current: current, empty: empty)), 200);
    };

Future<http.Response> noInternet(http.Request _) async =>
    throw const SocketException('Failed host lookup');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // No font downloads in tests.
  GoogleFonts.config.allowRuntimeFetching = false;

  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  // Every HTTP call made while pumping goes to [handler] (it can be swapped).
  late Future<http.Response> Function(http.Request) handler;
  Future<void> run(Future<void> Function() body) =>
      http.runWithClient(body, () => MockClient((req) => handler(req)));

  Future<void> pumpTrends(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: const MaterialApp(home: TrendsScreen()),
      ),
    );
  }

  testWidgets('online: total, change chip, 6 months, biggest store and average', (tester) async {
    handler = online();
    await run(() async {
      await pumpTrends(tester);
      await tester.pumpAndSettle();
    });
    expect(find.text('110.00 JD'), findsOneWidget);
    expect(find.textContaining('+10% vs '), findsOneWidget);
    expect(find.text('2 receipts'), findsOneWidget);
    for (final b in monthBounds(DateTime.now()).take(6)) {
      expect(find.text(_abbr[b.month - 1]), findsOneWidget);
    }
    expect(find.text('KFC'), findsOneWidget);
    expect(find.text('65.00 JD'), findsOneWidget);
    expect(find.text('+30% vs last month'), findsOneWidget);
    expect(find.text('Supermarket'), findsOneWidget);
    expect(find.text('New'), findsOneWidget); // Supermarket was 0 last month
    expect(find.textContaining('saved on this phone'), findsNothing);
  });

  testWidgets('offline with saved stats: the content and the "trends" banner', (tester) async {
    await OfflineCache.saveStats(SpendingStats.fromJson(statsJson(monthBounds(DateTime.now()))));
    handler = noInternet;
    await run(() async {
      await pumpTrends(tester);
      await tester.pumpAndSettle();
    });
    expect(find.text('110.00 JD'), findsOneWidget);
    expect(find.textContaining('Showing trends saved on this phone'), findsOneWidget);
  });

  testWidgets('offline with nothing saved: error and Retry; Retry online shows the content', (tester) async {
    handler = noInternet;
    await run(() async {
      await pumpTrends(tester);
      await tester.pumpAndSettle();
    });
    expect(find.text('Could not load trends'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    handler = online();
    await run(() async {
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
    });
    expect(find.text('Could not load trends'), findsNothing);
    expect(find.text('110.00 JD'), findsOneWidget);
  });

  testWidgets('all zeros: "No spending yet"', (tester) async {
    handler = online(empty: true);
    await run(() async {
      await pumpTrends(tester);
      await tester.pumpAndSettle();
    });
    expect(find.text('No spending yet'), findsOneWidget);
  });

  testWidgets('saved stats show at once, with no spinner, then the fresh ones', (tester) async {
    await OfflineCache.saveStats(
        SpendingStats.fromJson(statsJson(monthBounds(DateTime.now()), current: 45)));
    final reply = Completer<http.Response>();
    handler = (_) => reply.future;
    await run(() async {
      await pumpTrends(tester);
      await tester.pump();
    });
    expect(find.text('45.00 JD'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('saved on this phone'), findsNothing);

    reply.complete(http.Response(
        jsonEncode(statsJson(monthBounds(DateTime.now()), current: 120)), 200));
    await tester.pumpAndSettle();
    expect(find.text('120.00 JD'), findsOneWidget);
    expect(find.text('45.00 JD'), findsNothing);
  });

  testWidgets('refresh with stats on screen keeps them (no spinner) and updates in place', (tester) async {
    handler = online();
    await run(() async {
      await pumpTrends(tester);
      await tester.pumpAndSettle();
    });
    final reply = Completer<http.Response>();
    handler = (_) => reply.future;
    await run(() async {
      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pump();
    });
    expect(find.text('110.00 JD'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    reply.complete(http.Response(
        jsonEncode(statsJson(monthBounds(DateTime.now()), current: 130)), 200));
    await tester.pumpAndSettle();
    expect(find.text('130.00 JD'), findsOneWidget);
  });

  testWidgets('a server error on refresh keeps the stats and shows a SnackBar', (tester) async {
    handler = online();
    await run(() async {
      await pumpTrends(tester);
      await tester.pumpAndSettle();
    });
    handler = (_) async => http.Response(jsonEncode({'error': 'Failed to load stats.'}), 500);
    await run(() async {
      await tester.tap(find.byIcon(Icons.refresh_rounded));
      await tester.pump();
      await tester.pump();
    });
    expect(find.text('110.00 JD'), findsOneWidget);
    expect(find.text('Failed to load stats.'), findsOneWidget); // SnackBar
    expect(find.text('Could not load trends'), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 5)); // let the SnackBar go
  });

  testWidgets('a 1.205 JD month shows as 1.21 JD (formatJd)', (tester) async {
    handler = online(current: 1.205);
    await run(() async {
      await pumpTrends(tester);
      await tester.pumpAndSettle();
    });
    expect(find.text('1.21 JD'), findsOneWidget);
  });
}
