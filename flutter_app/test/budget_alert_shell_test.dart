import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus_app/core/receipt_event.dart';
import 'package:nexus_app/core/receipt_model.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/widgets/budget_alert.dart';
import 'package:nexus_app/widgets/live_sheets.dart';
import 'package:nexus_app/widgets/new_receipt_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/budget_fixtures.dart';

/// The shell's sheet logic (LiveSheets) without the rest of the shell.
class _Host extends StatefulWidget {
  const _Host();
  @override
  State<_Host> createState() => HostState();
}

class HostState extends State<_Host> with LiveSheets<_Host> {
  int viewBudgets = 0;
  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.expand());
}

ReceiptEvent receipt(String id) => ReceiptEvent(
      receipt: Receipt(
        id: id, storeName: 'KFC', category: 'Food', totalAmount: 8.5,
        items: const ['Meal'], date: DateTime(2026, 11, 13), pointsEarned: 8),
      pointsEarned: 8,
      loyaltyPoints: 100,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<HostState> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const MaterialApp(home: _Host()),
    ));
    return tester.state<HostState>(find.byType(_Host));
  }

  void showAlert(HostState host, a) =>
      host.showBudgetAlert(a, onViewBudgets: () => host.viewBudgets++);

  testWidgets('an alert for the open receipt shows inside that sheet, no second sheet', (tester) async {
    final host = await pumpHost(tester);
    host.showReceiptSheet(receipt('r1'), onViewArchive: () {});
    await tester.pumpAndSettle();
    expect(find.byType(NewReceiptSheet), findsOneWidget);

    showAlert(host, alert(receiptId: 'r1'));
    await tester.pumpAndSettle();
    expect(find.text('Food budget: 85% used'), findsOneWidget);
    expect(find.byType(BudgetAlertSheet), findsNothing);
    expect(host.alertRoute, isNull);

    // A second level for the same receipt adds a second banner.
    showAlert(host, alert(receiptId: 'r1', level: 100, percent: 105, spent: 52.5));
    await tester.pumpAndSettle();
    expect(find.byType(BudgetAlertBanner), findsNWidgets(2));
  });

  testWidgets('an alert for another receipt (or with no sheet) opens a BudgetAlertSheet', (tester) async {
    final host = await pumpHost(tester);
    showAlert(host, alert(receiptId: 'rX'));
    await tester.pumpAndSettle();
    expect(find.byType(BudgetAlertSheet), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(BudgetAlertSheet), findsNothing);
    expect(host.alertRoute, isNull);

    host.showReceiptSheet(receipt('r1'), onViewArchive: () {});
    await tester.pumpAndSettle();
    showAlert(host, alert(receiptId: 'r2', category: 'Pharmacy'));
    await tester.pumpAndSettle();
    expect(find.byType(BudgetAlertSheet), findsOneWidget);
    expect(find.text('Pharmacy budget: 85% used'), findsOneWidget);
  });

  testWidgets('"View budgets" closes the sheet and calls back', (tester) async {
    final host = await pumpHost(tester);
    showAlert(host, alert(receiptId: 'rX'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View budgets'));
    await tester.pumpAndSettle();
    expect(find.byType(BudgetAlertSheet), findsNothing);
    expect(host.viewBudgets, 1);
  });

  testWidgets('a second alert replaces the first instead of stacking', (tester) async {
    final host = await pumpHost(tester);
    showAlert(host, alert(receiptId: 'rX'));
    await tester.pumpAndSettle();
    showAlert(host, alert(receiptId: 'rY', category: 'Pharmacy', level: 100, percent: 100, spent: 50));
    await tester.pumpAndSettle();
    expect(find.byType(BudgetAlertSheet), findsOneWidget);
    expect(find.text('Over your Pharmacy budget'), findsOneWidget);
    expect(find.text('Food budget: 85% used'), findsNothing);
  });

  testWidgets('a new receipt closes an open alert sheet', (tester) async {
    final host = await pumpHost(tester);
    showAlert(host, alert(receiptId: 'rX'));
    await tester.pumpAndSettle();
    host.showReceiptSheet(receipt('r2'), onViewArchive: () {});
    await tester.pumpAndSettle();
    expect(find.byType(BudgetAlertSheet), findsNothing);
    expect(find.byType(NewReceiptSheet), findsOneWidget);
    expect(find.byType(BudgetAlertBanner), findsNothing); // fresh sheet, no old banners
  });

  testWidgets('session expiry closes every live sheet', (tester) async {
    final host = await pumpHost(tester);
    host.showReceiptSheet(receipt('r1'), onViewArchive: () {});
    await tester.pumpAndSettle();
    showAlert(host, alert(receiptId: 'rX'));
    await tester.pumpAndSettle();
    expect(find.byType(BudgetAlertSheet), findsOneWidget);

    host.closeLiveSheets();
    await tester.pumpAndSettle();
    expect(find.byType(BudgetAlertSheet), findsNothing);
    expect(find.byType(NewReceiptSheet), findsNothing);
    expect(host.receiptRouteId, isNull);
  });

  testWidgets('after the receipt sheet is closed, its alert gets its own sheet', (tester) async {
    final host = await pumpHost(tester);
    host.showReceiptSheet(receipt('r1'), onViewArchive: () {});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    showAlert(host, alert(receiptId: 'r1'));
    await tester.pumpAndSettle();
    expect(find.byType(BudgetAlertSheet), findsOneWidget);
  });
}
