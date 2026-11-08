import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus_app/core/receipt_model.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/widgets/new_receipt_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // No font downloads in tests.
  GoogleFonts.config.allowRuntimeFetching = false;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSheet(WidgetTester tester, {VoidCallback? onViewArchive, VoidCallback? onDone}) {
    final receipt = Receipt(
      id: 'r1',
      storeName: 'Carrefour',
      category: 'Supermarket',
      totalAmount: 12.5,
      items: const ['Milk x2', 'Bread', 'Eggs x12', 'Rice 2kg', 'Tea', 'Sugar'],
      date: DateTime(2026, 11, 8),
      pointsEarned: 12,
    );
    return tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: NewReceiptSheet(
                receipt: receipt,
                pointsEarned: 12,
                onViewArchive: onViewArchive ?? () {},
                onDone: onDone ?? () {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows the store, total, points and "and 2 more" for 6 items', (tester) async {
    await pumpSheet(tester);
    expect(find.text('Carrefour'), findsOneWidget);
    expect(find.text('Supermarket'), findsOneWidget);
    expect(find.text('12.50 JD'), findsOneWidget);
    expect(find.text('+12 pts'), findsOneWidget);
    expect(find.text('Milk x2'), findsOneWidget);
    expect(find.text('Rice 2kg'), findsOneWidget);
    expect(find.text('Tea'), findsNothing);
    expect(find.text('and 2 more'), findsOneWidget);
  });

  testWidgets('"View in Archive" and "Done" call their callbacks', (tester) async {
    var archive = 0, done = 0;
    await pumpSheet(tester, onViewArchive: () => archive++, onDone: () => done++);
    await tester.tap(find.text('View in Archive'));
    await tester.tap(find.text('Done'));
    expect(archive, 1);
    expect(done, 1);
  });
}
