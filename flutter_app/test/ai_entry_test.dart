import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/ai_chat_session.dart';
import 'package:nexus_app/core/ai_models.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:nexus_app/core/stats_model.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:nexus_app/screens/ai_screen.dart';
import 'package:nexus_app/screens/dashboard_screen.dart';
import 'package:nexus_app/screens/trends_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const summary = 'You spent 287.99 JD so far this month.';
final userJson = {
  'id': 'u1', 'email': 'u1@nexus.test', 'name': 'Sim Tester', 'firstName': 'Sim', 'lastName': 'Tester',
  'emailVerified': true, 'serialNumber': 'NXS-AAAAA-BBBBB', 'loyaltyPoints': 1, 'createdAt': '2026-01-01T00:00:00.000Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  var insightOnline = true;
  var insightCalls = 0;
  Future<http.Response> handler(http.Request req) async {
    final path = req.url.path;
    if (path.endsWith('/ai/insight')) {
      insightCalls++;
      if (!insightOnline) throw const SocketException('down');
      return http.Response(jsonEncode({
        'status': 'ready', 'summary': summary, 'tip': 'Tip.', 'createdAt': DateTime.now().toUtc().toIso8601String(),
      }), 200);
    }
    if (path.endsWith('/user/stats')) {
      final bounds = req.url.queryParameters['bounds']!.split(',').map(DateTime.parse).toList();
      return http.Response(jsonEncode(SpendingStats([
        for (var i = 0; i < bounds.length - 1; i++)
          PeriodStats(from: bounds[i], to: bounds[i + 1], total: 0, count: 0, average: 0),
      ]).toJson()), 200);
    }
    if (path.endsWith('/user/receipts')) return http.Response('[]', 200);
    if (path.endsWith('/user/me')) return http.Response(jsonEncode(userJson), 200);
    return http.Response('{"error":"not here"}', 404);
  }

  Future<void> run(Future<void> Function() body) => http.runWithClient(body, () => MockClient(handler));

  setUp(() {
    insightOnline = true;
    insightCalls = 0;
  });

  Future<void> pumpScreen(WidgetTester tester, Widget screen, {AiChatSession? session}) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = AuthProvider();
    for (var i = 0; i < 20 && auth.loading; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    auth.updateUser(User.fromJson(userJson));
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider.value(value: auth),
        if (session != null) ChangeNotifierProvider<AiChatSession>.value(value: session),
      ],
      child: MaterialApp(home: screen),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('the Home teaser opens the AI page; "Ask AI" opens it on Ask', (tester) async {
    await run(() async {
      await pumpScreen(tester, const DashboardScreen());
      expect(find.text(summary), findsOneWidget);
      await tester.tap(find.text('AI insight'));
      await settle(tester);
      expect(find.byType(AiScreen), findsOneWidget);
      expect(find.text('TRY ASKING'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await settle(tester);
      await tester.tap(find.text('Ask AI'));
      await settle(tester);
    });
    expect(find.text('Ask about your spending'), findsOneWidget);
  });

  testWidgets('the Trends AI button opens the page, also when Trends is empty', (tester) async {
    await run(() async {
      await pumpScreen(tester, const TrendsScreen());
      expect(find.text('No spending yet'), findsOneWidget);
      await tester.tap(find.byTooltip('AI insights'));
      await settle(tester);
    });
    expect(find.byType(AiScreen), findsOneWidget);
  });

  testWidgets('Home pull-to-refresh reloads the teaser: offline line gone, exactly 1 insight call', (tester) async {
    await OfflineCache.saveInsight(Insight.fromJson({'status': 'ready', 'summary': 'Saved.', 'tip': 'T.'}));
    insightOnline = false;
    await run(() async {
      await pumpScreen(tester, const DashboardScreen());
      await settle(tester);
      expect(find.text('Offline · saved insight'), findsOneWidget);
      insightOnline = true;
      final before = insightCalls;
      await tester.fling(find.byType(SingleChildScrollView).first, const Offset(0, 400), 1000);
      await settle(tester);
      expect(insightCalls - before, 1);
    });
    expect(find.text('Offline · saved insight'), findsNothing);
    expect(find.text(summary), findsOneWidget);
  });

  testWidgets('a shell chat session survives closing and reopening the page', (tester) async {
    final shell = AiChatSession();
    addTearDown(shell.dispose);
    await run(() async {
      await pumpScreen(tester, const TrendsScreen(), session: shell);
      await tester.tap(find.byTooltip('AI insights'));
      await settle(tester);
      expect(Provider.of<AiChatSession>(tester.element(find.byType(AiScreen)), listen: false), same(shell));
      await tester.tap(find.byTooltip('Back'));
      await settle(tester);
      await tester.tap(find.byTooltip('AI insights'));
      await settle(tester);
    });
    expect(shell.isDisposed, isFalse);
    expect(Provider.of<AiChatSession>(tester.element(find.byType(AiScreen)), listen: false), same(shell));
  });
}
