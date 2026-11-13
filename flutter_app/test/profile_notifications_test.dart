import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/budget_models.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/widgets/budgets_alerts_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/budget_fixtures.dart';

Map<String, dynamic> userJson({bool verified = true, bool alerts = true, bool weekly = false}) => {
      'id': 'u1', 'email': 'a@nexus.test', 'name': 'A B', 'firstName': 'A', 'lastName': 'B',
      'serialNumber': 'NXS-AAAAA-BBBBB', 'loyaltyPoints': 3, 'createdAt': '2026-01-01T00:00:00.000Z',
      'emailVerified': verified, 'budgetAlertEmails': alerts, 'weeklySummaryEmails': weekly,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  setUp(requests.clear);
  Future<void> run(Future<void> Function() body) => http.runWithClient(body, () => MockClient((req) {
        requests.add(req);
        return handler(req);
      }));

  Switch switchOf(WidgetTester tester, String key) => tester.widget<Switch>(find.byKey(ValueKey(key)));

  Future<void> pumpCard(WidgetTester tester, {bool verified = true}) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    handler = (_) async => http.Response(jsonEncode(userJson(verified: verified)), 200);
    await run(() async {
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => context.watch<AuthProvider>().user == null
                ? const SizedBox()
                : const SingleChildScrollView(child: BudgetsAlertsCard())),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('switches show the user values; the budget count comes from the saved list', (tester) async {
    await OfflineCache.saveBudgets(BudgetList.fromJson(
        budgetListJson(budgets: [budgetJson('Food', 50, 1), budgetJson('Pharmacy', 9, 1)])));
    await pumpCard(tester);
    expect(find.text('BUDGETS & ALERTS'), findsOneWidget);
    expect(find.text('Monthly budgets'), findsOneWidget);
    expect(find.text('2 set'), findsOneWidget);
    expect(switchOf(tester, 'switch-budget-alerts').value, isTrue);
    expect(switchOf(tester, 'switch-weekly').value, isFalse);
    expect(find.text('Verify your email to get these emails'), findsNothing);
  });

  testWidgets('toggling calls PATCH, shows the new value at once and keeps it', (tester) async {
    await pumpCard(tester);
    final reply = Completer<http.Response>();
    handler = (_) => reply.future;
    await run(() async {
      await tester.tap(find.byKey(const ValueKey('switch-weekly')));
      await tester.pump();
    });
    expect(switchOf(tester, 'switch-weekly').value, isTrue);
    expect(switchOf(tester, 'switch-weekly').onChanged, isNull); // disabled while saving
    final patch = requests.last;
    expect(patch.method, 'PATCH');
    expect(jsonDecode(patch.body), containsPair('weeklySummaryEmails', true));
    expect(jsonDecode(patch.body), contains('tzOffsetMinutes'));

    reply.complete(http.Response(jsonEncode(userJson(weekly: true)), 200));
    await tester.pumpAndSettle();
    expect(switchOf(tester, 'switch-weekly').value, isTrue);
    expect(switchOf(tester, 'switch-weekly').onChanged, isNotNull);
    expect((await OfflineCache.loadUser())!.weeklySummaryEmails, isTrue);
  });

  testWidgets('a failure goes back to the old value with a SnackBar', (tester) async {
    await pumpCard(tester);
    handler = (_) async => http.Response(jsonEncode({'error': 'Failed to save settings.'}), 500);
    await run(() async {
      await tester.tap(find.byKey(const ValueKey('switch-budget-alerts')));
      await tester.pumpAndSettle();
    });
    expect(switchOf(tester, 'switch-budget-alerts').value, isTrue);
    expect(find.textContaining('Failed to save settings.'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('unverified email: both switches disabled and a "Verify" link', (tester) async {
    await pumpCard(tester, verified: false);
    expect(switchOf(tester, 'switch-budget-alerts').onChanged, isNull);
    expect(switchOf(tester, 'switch-weekly').onChanged, isNull);
    expect(find.text('Verify your email to get these emails'), findsOneWidget);
    expect(find.text('Verify'), findsOneWidget);
  });
}
