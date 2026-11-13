import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/budget_models.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/screens/budgets_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/budget_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  Future<void> run(Future<void> Function() body) => http.runWithClient(body, () => MockClient((req) {
        requests.add(req);
        return handler(req);
      }));
  setUp(requests.clear);

  http.Response list(List<Map<String, dynamic>> budgets) =>
      http.Response(jsonEncode(budgetListJson(budgets: budgets)), 200);

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const MaterialApp(home: BudgetsScreen()),
    ));
  }

  testWidgets('list: month label, bars, sorted as the server sends them', (tester) async {
    handler = (_) async => list([budgetJson('Food', 50, 42.5), budgetJson('Pharmacy', 20, 5)]);
    await run(() async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();
    });
    expect(find.text('Monthly budgets'), findsOneWidget);
    expect(find.text('November 2026'), findsOneWidget);
    expect(find.text("We'll alert you at 80% and 100%."), findsOneWidget);
    expect(find.text('42.50 / 50.00 JD'), findsOneWidget);
    expect(find.text('5.00 / 20.00 JD'), findsOneWidget);
    expect(find.text('Add budget'), findsOneWidget);
    expect(requests.single.url.queryParameters, contains('tzOffsetMinutes'));
  });

  testWidgets('empty state with "Add a budget"', (tester) async {
    handler = (_) async => list([]);
    await run(() async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();
    });
    expect(find.text('No budgets yet'), findsOneWidget);
    expect(find.text('Add a budget'), findsOneWidget);
  });

  testWidgets('add: the picker skips budgeted categories; a 400 shows under the field; save works', (tester) async {
    handler = (_) async => list([budgetJson('Food', 50, 10)]);
    await run(() async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add budget'));
      await tester.pumpAndSettle();
    });
    await tester.tap(find.byKey(const ValueKey('budget-category')));
    await tester.pumpAndSettle();
    expect(find.text('Clothing').hitTestable(), findsWidgets);
    expect(find.descendant(of: find.byType(DropdownMenuItem<String>), matching: find.text('Food')), findsNothing);
    await tester.tap(find.text('Pharmacy').last);
    await tester.pumpAndSettle();

    // Checked in the app first.
    await tester.enterText(find.byKey(const ValueKey('budget-amount')), '12.345');
    await tester.tap(find.byKey(const ValueKey('budget-save')));
    await tester.pump();
    expect(find.text('Use at most 2 decimals.'), findsOneWidget);
    expect(requests.where((r) => r.method == 'PUT'), isEmpty);

    // A server 400 is shown under the field.
    handler = (req) async => req.method == 'PUT'
        ? http.Response(jsonEncode({'error': 'You can have up to 20 budgets.'}), 400)
        : list([budgetJson('Food', 50, 10)]);
    await tester.enterText(find.byKey(const ValueKey('budget-amount')), '30');
    await run(() async {
      await tester.tap(find.byKey(const ValueKey('budget-save')));
      await tester.pumpAndSettle();
    });
    expect(find.text('You can have up to 20 budgets.'), findsOneWidget);

    // Success: the sheet closes and the list is replaced by the reply.
    handler = (_) async => list([budgetJson('Pharmacy', 30, 0), budgetJson('Food', 50, 10)]);
    await run(() async {
      await tester.tap(find.byKey(const ValueKey('budget-save')));
      await tester.pumpAndSettle();
    });
    final put = requests.lastWhere((r) => r.method == 'PUT');
    expect(jsonDecode(put.body), containsPair('category', 'Pharmacy'));
    expect(jsonDecode(put.body), containsPair('limit', 30));
    expect(find.byKey(const ValueKey('budget-save')), findsNothing);
    expect(find.text('0.00 / 30.00 JD'), findsOneWidget);
  });

  testWidgets('a second tap while saving is blocked', (tester) async {
    handler = (_) async => list([]);
    await run(() async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add a budget'));
      await tester.pumpAndSettle();
    });
    final reply = Completer<http.Response>();
    handler = (_) => reply.future;
    await tester.enterText(find.byKey(const ValueKey('budget-amount')), '25');
    await run(() async {
      await tester.tap(find.byKey(const ValueKey('budget-save')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('budget-save')), warnIfMissed: false);
      await tester.pump();
    });
    expect(requests.where((r) => r.method == 'PUT'), hasLength(1));
    expect(find.descendant(of: find.byKey(const ValueKey('budget-save')),
        matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    reply.complete(list([budgetJson('Clothing', 25, 0)]));
    await tester.pumpAndSettle();
    expect(find.text('0.00 / 25.00 JD'), findsOneWidget);
  });

  testWidgets('edit and remove (with a confirmation)', (tester) async {
    handler = (_) async => list([budgetJson('Food', 50, 10)]);
    await run(() async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('10.00 / 50.00 JD'));
      await tester.pumpAndSettle();
    });
    expect(find.text('Food budget'), findsOneWidget);
    expect(find.byKey(const ValueKey('budget-category')), findsNothing);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('budget-amount'))).controller!.text, '50');

    handler = (_) async => list([budgetJson('Food', 40, 10)]);
    await tester.enterText(find.byKey(const ValueKey('budget-amount')), '40');
    await run(() async {
      await tester.tap(find.byKey(const ValueKey('budget-save')));
      await tester.pumpAndSettle();
    });
    expect(find.text('10.00 / 40.00 JD'), findsOneWidget);

    // Remove: Cancel does nothing, Remove deletes.
    await tester.tap(find.text('10.00 / 40.00 JD'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('budget-remove')));
    await tester.pumpAndSettle();
    expect(find.text('Remove the Food budget?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.method == 'DELETE'), isEmpty);

    // The tap that opens the dialog starts the delete, so it runs in the mock zone too.
    handler = (_) async => list([]);
    await run(() async {
      await tester.tap(find.byKey(const ValueKey('budget-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('budget-remove-confirm')));
      await tester.pumpAndSettle();
    });
    expect(requests.last.method, 'DELETE');
    expect(requests.last.url.pathSegments.last, 'Food');
    expect(find.text('No budgets yet'), findsOneWidget);
  });

  testWidgets('offline: the saved list with the banner and its month, editing disabled', (tester) async {
    await OfflineCache.saveBudgets(BudgetList.fromJson(
        budgetListJson(budgets: [budgetJson('Food', 50, 10)], label: 'October 2026')));
    handler = (_) async => throw const SocketException('Failed host lookup');
    await run(() async {
      await pumpScreen(tester);
      await tester.pumpAndSettle();
    });
    expect(find.textContaining('Showing budgets saved on this phone'), findsOneWidget);
    expect(find.text('October 2026'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('budget-add'))).onPressed, isNull);
    await tester.tap(find.text('10.00 / 50.00 JD'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('budget-save')), findsNothing);
  });

  test('budgetAmountError', () {
    expect(budgetAmountError('50'), isNull);
    expect(budgetAmountError('12.50'), isNull);
    expect(budgetAmountError('1'), isNull);
    expect(budgetAmountError('100000'), isNull);
    expect(budgetAmountError(''), 'Enter an amount.');
    expect(budgetAmountError('abc'), 'Enter a number, like 50 or 12.50.');
    expect(budgetAmountError('-5'), 'Enter a number, like 50 or 12.50.');
    expect(budgetAmountError('1.234'), 'Use at most 2 decimals.');
    expect(budgetAmountError('0.99'), 'Enter an amount between 1 and 100000 JD.');
    expect(budgetAmountError('100001'), 'Enter an amount between 1 and 100000 JD.');
    // Comma-decimal keypads and Arabic digits.
    expect(budgetAmountError('12,5'), isNull);
    expect(budgetAmountError('12,50'), isNull);
    expect(budgetAmountError('١٢٫٥'), isNull);
    expect(budgetAmountError('1,234'), 'Use at most 2 decimals.');
    expect(normalizeBudgetAmount(' 12,5 '), '12.5');
    expect(normalizeBudgetAmount('١٢٫٥٠'), '12.50');
    expect(normalizeBudgetAmount('۲۰'), '20');
  });
}
