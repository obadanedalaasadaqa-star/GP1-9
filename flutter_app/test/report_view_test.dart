import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/ai_models.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:nexus_app/widgets/report_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/report_json.dart';

Map<String, dynamic> userJson({bool verified = true}) => {
  'id': 'u1', 'email': 'u1@nexus.test', 'name': 'Sim Tester', 'firstName': 'Sim', 'lastName': 'Tester',
  'emailVerified': verified, 'serialNumber': 'NXS-AAAAA-BBBBB', 'loyaltyPoints': 1,
  'createdAt': '2026-01-01T00:00:00.000Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  final requests = <http.Request>[];
  late Future<http.Response> Function(http.Request) report;
  var verified = true;
  Future<http.Response> handler(http.Request req) async {
    requests.add(req);
    if (req.url.path.endsWith('/user/me')) return http.Response(jsonEncode(userJson(verified: verified)), 200);
    if (req.url.path.endsWith('/ai/report/email')) {
      return http.Response(jsonEncode({'message': 'Report sent to u1@nexus.test.'}), 200);
    }
    if (req.url.path.endsWith('/ai/report')) return report(req);
    return http.Response('{"error":"not here"}', 404);
  }

  Future<void> run(Future<void> Function() body) => http.runWithClient(body, () => MockClient(handler));

  setUp(() {
    requests.clear();
    verified = true;
    report = (_) async => utf8Json(reportJson());
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpView(WidgetTester tester, {bool reduceMotion = false, bool wait = true}) async {
    tester.view.physicalSize = const Size(700, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = AuthProvider();
    for (var i = 0; i < 20 && auth.loading; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    auth.updateUser(User.fromJson(userJson(verified: verified)));
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider.value(value: auth),
      ],
      child: MaterialApp(home: Builder(builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: const Scaffold(body: ReportView()),
      ))),
    ));
    if (wait) await settle(tester);
  }

  List<String?> periodsAsked() => requests
      .where((r) => r.url.path.endsWith('/ai/report'))
      .map((r) => r.url.queryParameters['period'])
      .toList();

  testWidgets('first open asks 1m; "3 months" asks 3m; amounts via formatJd; AI text', (tester) async {
    await run(() async {
      await pumpView(tester);
      expect(periodsAsked(), ['1m']);
      expect(find.text('287.99 JD'), findsNWidgets(2)); // total and the month row
      expect(find.text('31%'), findsOneWidget);
      expect(find.text('0.00 JD'), findsOneWidget); // previous total
      expect(find.text('New'), findsOneWidget);
      expect(find.text('7 receipts · average 41.14 JD'), findsOneWidget);
      expect(find.text('November 2026 (so far)'), findsOneWidget);
      expect(find.text('You spent 287.99 JD so far.'), findsOneWidget);
      expect(find.text('Electronics was the biggest category at 89.99 JD.'), findsOneWidget);
      expect(find.text('Plan big purchases.'), findsOneWidget);
      await tester.tap(find.text('3 months'));
      await settle(tester);
    });
    expect(periodsAsked(), ['1m', '3m']);
  });

  testWidgets('visual report: cards, comparison wording, donut centre, compare labels', (tester) async {
    await run(() => pumpView(tester));
    for (final k in ['report-compare', 'report-donut', 'report-months', 'report-stores']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget);
    }
    expect(find.text('compared with 1 – 11 Oct 2026 (same days last month)'), findsOneWidget);
    expect(find.text('This period vs before'), findsOneWidget);
    expect(find.text('Compared with 1 – 11 Oct 2026'), findsNothing); // the dates show once
    expect(find.text('Compared with the previous period'), findsNothing);
    expect(find.text('2 categories'), findsOneWidget);
    expect(find.text('This period'), findsOneWidget);
    expect(find.text('Before'), findsOneWidget);
    expect(find.text('288'), findsOneWidget); // the month column, whole JD
    expect(find.text('Nov'), findsOneWidget);
    expect(find.text('7 receipts · average 41.14 JD'), findsOneWidget);
  });

  testWidgets('the total counts up, and ends exactly on the server number', (tester) async {
    await run(() => pumpView(tester, wait: false));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('287.99 JD'), findsOneWidget); // only the month row so far
    await settle(tester);
    expect(find.text('287.99 JD'), findsNWidgets(2));
  });

  testWidgets('reduce motion: the final total right away', (tester) async {
    await run(() async {
      await pumpView(tester, reduceMotion: true, wait: false);
      await tester.pump(const Duration(milliseconds: 50)); // the report request
    });
    await tester.pump();
    expect(find.text('287.99 JD'), findsNWidgets(2)); // total and the month row
  });

  testWidgets('AI unavailable: muted error, numbers still shown', (tester) async {
    report = (_) async => utf8Json(reportJson(ai: {'status': 'unavailable', 'error': 'AI summary is not set up on this server.'}));
    await run(() => pumpView(tester));
    expect(find.text('AI summary is not set up on this server.'), findsOneWidget);
    expect(find.text('287.99 JD'), findsNWidgets(2)); // total and the month row
  });

  testWidgets('not enough data and no receipts', (tester) async {
    report = (_) async => utf8Json(reportJson(
        receipts: 0, ai: {'status': 'not_enough_data', 'receiptCount': 0, 'minReceipts': 3}));
    await run(() => pumpView(tester));
    expect(find.text('The AI summary appears after 3 receipts in this period.'), findsOneWidget);
    expect(find.text('No receipts in this period.'), findsOneWidget);
    expect(find.text('By category'), findsNothing);
  });

  testWidgets('verified: email sends the same period and shows the SnackBar', (tester) async {
    await run(() async {
      await pumpView(tester);
      await tester.tap(find.text('Email me this report'));
      await settle(tester);
    });
    final email = requests.singleWhere((r) => r.url.path.endsWith('/ai/report/email'));
    expect((jsonDecode(email.body) as Map)['period'], '1m');
    expect(find.text('Report sent to u1@nexus.test.'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('unverified: the button asks to verify', (tester) async {
    verified = false;
    await run(() => pumpView(tester));
    expect(find.text('Verify your email to get reports by email'), findsOneWidget);
    expect(find.text('Email me this report'), findsNothing);
  });

  testWidgets('offline with a saved report for the same period: banner, email disabled', (tester) async {
    // Saved while this user was signed in (a cache without a profile is wiped).
    await OfflineCache.saveUser(User.fromJson(userJson()));
    await OfflineCache.saveReport('1m', SpendingReport.fromJson(reportJson()), generation: OfflineCache.generation);
    report = (_) async => throw const SocketException('down');
    await run(() => pumpView(tester));
    expect(find.textContaining('Showing report saved on this phone'), findsOneWidget);
    expect(find.text('287.99 JD'), findsNWidgets(2)); // total and the month row
    final button = tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('Email me this report'), matching: find.byWidgetPredicate((w) => w is OutlinedButton)));
    expect(button.onPressed, isNull);
  });

  testWidgets('offline with nothing saved for this period: error and Try again', (tester) async {
    await OfflineCache.saveUser(User.fromJson(userJson()));
    await OfflineCache.saveReport('3m', SpendingReport.fromJson(reportJson()), generation: OfflineCache.generation);
    report = (_) async => throw const SocketException('down');
    await run(() => pumpView(tester));
    expect(find.text("Couldn't load the report."), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
