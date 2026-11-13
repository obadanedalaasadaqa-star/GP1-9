import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus_app/core/budget_models.dart';
import 'package:nexus_app/core/constants.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/widgets/budget_alert.dart';
import 'package:nexus_app/widgets/budget_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/budget_fixtures.dart';

BudgetStatus status(double limit, double spent, {String category = 'Food'}) =>
    BudgetStatus.fromJson(budgetJson(category, limit, spent));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => ThemeProvider(),
          child: MaterialApp(home: Scaffold(body: SizedBox(width: 360, child: child))),
        ),
      );

  group('BudgetBar', () {
    test('colour: category under 80%, gold 80-99%, alert from 100%', () {
      expect(BudgetBar.colorFor(status(50, 25)), CategoryColors.of('Food'));
      expect(BudgetBar.colorFor(status(50, 42.5)), AppColors.gold);
      expect(BudgetBar.colorFor(status(50, 60)), AppColors.alert);
    });

    test('the fill is clamped to the full bar', () {
      expect(BudgetBar.fillOf(status(50, 25)), 0.5);
      expect(BudgetBar.fillOf(status(10, 25)), 1.0);
    });

    testWidgets('texts: amounts and "left" / "Over by" captions', (tester) async {
      await pump(tester, BudgetBar(status: status(50, 42.5)));
      expect(find.text('Food'), findsOneWidget);
      expect(find.text('42.50 / 50.00 JD'), findsOneWidget);
      expect(find.text('85% · 7.50 JD left'), findsOneWidget);

      await pump(tester, BudgetBar(status: status(10, 13.2)));
      expect(find.text('Over by 3.20 JD'), findsOneWidget);
      final fill = tester.widget<FractionallySizedBox>(find.byKey(const ValueKey('budget-bar-fill')));
      expect(fill.widthFactor, 1.0);
    });

    testWidgets('the empty track spans the full width, even at 0%', (tester) async {
      await pump(tester, BudgetBar(status: status(50, 0)));
      final track = tester.getSize(find.byKey(const ValueKey('budget-bar-track')));
      expect(track.width, 360);
      expect(track.height, 8);
      expect(tester.getSize(find.byKey(const ValueKey('budget-bar-fill'))).width, 0);

      await pump(tester, BudgetBar(status: status(50, 25)));
      expect(tester.getSize(find.byKey(const ValueKey('budget-bar-track'))).width, 360);
      expect(tester.getSize(find.byKey(const ValueKey('budget-bar-fill'))).width, 180);
    });

    testWidgets('onTap is called', (tester) async {
      var taps = 0;
      await pump(tester, BudgetBar(status: status(50, 10), onTap: () => taps++));
      await tester.tap(find.text('Food'));
      expect(taps, 1);
    });
  });

  testWidgets('BudgetAlertBanner shows the title and detail', (tester) async {
    await pump(tester, BudgetAlertBanner(alert: alert()));
    expect(find.text('Food budget: 85% used'), findsOneWidget);
    expect(find.text('42.50 of 50.00 JD used in November 2026'), findsOneWidget);
    expect(BudgetAlertBanner.colorFor(alert()), AppColors.gold);
    expect(BudgetAlertBanner.colorFor(alert(level: 100, percent: 110, spent: 55)), AppColors.alert);
  });

  testWidgets('BudgetAlertSheet buttons call back', (tester) async {
    var view = 0, done = 0;
    await pump(tester, SingleChildScrollView(
      child: BudgetAlertSheet(
        alert: alert(level: 100, percent: 110, spent: 55),
        onViewBudgets: () => view++,
        onDone: () => done++,
      ),
    ));
    expect(find.text('BUDGET ALERT'), findsOneWidget);
    expect(find.text('Over your Food budget'), findsOneWidget);
    await tester.tap(find.text('View budgets'));
    await tester.tap(find.text('OK'));
    expect((view, done), (1, 1));
  });
}
