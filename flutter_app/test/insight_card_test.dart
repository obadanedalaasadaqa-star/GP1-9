import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/ai_models.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/widgets/insight_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const summary = 'You spent 287.99 JD so far this month.';
const tip = 'Keep an eye on Electronics.';

http.Response readyReply({String text = summary}) => http.Response(jsonEncode({
      'status': 'ready', 'summary': text, 'tip': tip,
      'createdAt': DateTime.now().toUtc().subtract(const Duration(hours: 2)).toIso8601String(), 'cached': true,
    }), 200);

Future<http.Response> noInternet(http.Request _) async => throw const SocketException('Failed host lookup');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  late Future<http.Response> Function(http.Request) handler;
  Future<void> run(Future<void> Function() body) =>
      http.runWithClient(body, () => MockClient((req) => handler(req)));

  Future<void> saveOld() => OfflineCache.saveInsight(Insight.fromJson({
        'status': 'ready', 'summary': 'Saved summary.', 'tip': tip, 'createdAt': '2026-11-01T09:00:00.000Z',
      }));

  Future<void> pumpCard(WidgetTester tester, {bool compact = false, VoidCallback? onOpen, Key? key}) async {
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: MaterialApp(home: Scaffold(body: SingleChildScrollView(
        child: InsightCard(key: key, compact: compact, onOpen: onOpen)))),
    ));
  }

  group('full mode', () {
    testWidgets('ready: summary, tip and footer', (tester) async {
      handler = (_) async => readyReply();
      await run(() async {
        await pumpCard(tester);
        await tester.pumpAndSettle();
      });
      expect(find.text(summary), findsOneWidget);
      expect(find.text(tip), findsOneWidget);
      expect(find.byIcon(Icons.lightbulb_rounded), findsOneWidget);
      expect(find.text('AI-generated · updated 2 h ago'), findsOneWidget);
    });

    testWidgets('not enough data', (tester) async {
      handler = (_) async => http.Response('{"status":"not_enough_data","receiptCount":1,"minReceipts":3}', 200);
      await run(() async {
        await pumpCard(tester);
        await tester.pumpAndSettle();
      });
      expect(find.text('Your first insight appears after 3 receipts. You have 1 so far.'), findsOneWidget);
    });

    testWidgets('loading spinner, then the insight', (tester) async {
      final reply = Completer<http.Response>();
      handler = (_) => reply.future;
      await run(() async {
        await pumpCard(tester);
        await tester.pump();
        await tester.pump();
      });
      expect(find.text('Reading your spending…'), findsOneWidget);
      reply.complete(readyReply());
      await tester.pumpAndSettle();
      expect(find.text(summary), findsOneWidget);
    });

    testWidgets('a saved insight shows at once, then the fresh one', (tester) async {
      await saveOld();
      final reply = Completer<http.Response>();
      handler = (_) => reply.future;
      await run(() async {
        await pumpCard(tester);
        await tester.pump();
        await tester.pump();
      });
      expect(find.text('Saved summary.'), findsOneWidget);
      expect(find.text('Reading your spending…'), findsNothing);
      reply.complete(readyReply());
      await tester.pumpAndSettle();
      expect(find.text(summary), findsOneWidget);
    });

    testWidgets('offline with saved: the banner; reload online clears it', (tester) async {
      await saveOld();
      handler = noInternet;
      final key = GlobalKey<InsightCardState>();
      await run(() async {
        await pumpCard(tester, key: key);
        await tester.pumpAndSettle();
      });
      expect(find.text('Saved summary.'), findsOneWidget);
      expect(find.textContaining('Showing insight saved on this phone'), findsOneWidget);

      handler = (_) async => readyReply();
      await run(() async {
        await key.currentState!.reload();
        await tester.pumpAndSettle();
      });
      expect(find.textContaining('saved on this phone'), findsNothing);
      expect(find.text(summary), findsOneWidget);
    });

    testWidgets('offline with nothing saved: "Try again" works', (tester) async {
      handler = noInternet;
      await run(() async {
        await pumpCard(tester);
        await tester.pumpAndSettle();
      });
      expect(find.text("Couldn't load your insight."), findsOneWidget);
      handler = (_) async => readyReply();
      await run(() async {
        await tester.tap(find.text('Try again'));
        await tester.pumpAndSettle();
      });
      expect(find.text(summary), findsOneWidget);
    });

    testWidgets('server error with saved: the saved one plus a muted note', (tester) async {
      await saveOld();
      handler = (_) async => http.Response('{"error":"Could not create an insight right now. Try again later."}', 502);
      await run(() async {
        await pumpCard(tester);
        await tester.pumpAndSettle();
      });
      expect(find.text('Saved summary.'), findsOneWidget);
      expect(find.text("Couldn't update the insight right now."), findsOneWidget);
    });

    testWidgets('after logout (cache cleared) no old summary shows', (tester) async {
      await saveOld();
      await OfflineCache.clear();
      handler = noInternet;
      await run(() async {
        await pumpCard(tester);
        await tester.pumpAndSettle();
      });
      expect(find.text('Saved summary.'), findsNothing);
      expect(find.text("Couldn't load your insight."), findsOneWidget);
    });
  });

  group('compact mode', () {
    testWidgets('3 lines, Open and Ask AI, tap calls onOpen', (tester) async {
      var opened = 0;
      handler = (_) async => readyReply(text: 'Long text. ' * 40);
      await run(() async {
        await pumpCard(tester, compact: true, onOpen: () => opened++);
        await tester.pumpAndSettle();
      });
      final text = tester.widget<Text>(find.textContaining('Long text.'));
      expect(text.maxLines, 3);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Ask AI'), findsOneWidget);
      expect(find.text(tip), findsNothing);
      await tester.tap(find.text('AI insight'));
      await tester.tap(find.text('Open'));
      expect(opened, 2);
    });

    testWidgets('offline: one muted line, not the full banner', (tester) async {
      await saveOld();
      handler = noInternet;
      await run(() async {
        await pumpCard(tester, compact: true);
        await tester.pumpAndSettle();
      });
      expect(find.text('Offline · saved insight'), findsOneWidget);
      expect(find.textContaining('Showing insight saved on this phone'), findsNothing);
    });
  });
}
