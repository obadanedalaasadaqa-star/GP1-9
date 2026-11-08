import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus_app/core/receipt_model.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/screens/receipt_detail_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, Receipt r) async {
    tester.view.physicalSize = const Size(600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: MaterialApp(home: ReceiptDetailScreen(receipt: r)),
    ));
  }

  final storeReceipt = Receipt.fromJson({
    'id': 'ab12cd34-0000-0000-0000-000000000000',
    'storeName': 'Carrefour', 'category': 'Supermarket', 'totalAmount': 10.995,
    'items': ['Rice 2kg', 'Milk x2', 'Bread'],
    'lineItems': [
      {'name': 'Rice 2kg', 'qty': 1, 'unitPrice': 7.995},
      {'name': 'Milk', 'qty': 2, 'unitPrice': 1.25},
      {'name': 'Bread', 'qty': 1, 'unitPrice': 0.5},
    ],
    'pointsEarned': 10, 'createdAt': '2026-11-08T20:39:00.000Z',
  });

  test('lineItems survive the JSON round trip (offline cache)', () {
    final back = Receipt.fromJson(storeReceipt.toJson());
    expect(back.lineItems!.map((l) => [l.name, l.qty, l.unitPrice]).toList(), [
      ['Rice 2kg', 1, 7.995], ['Milk', 2, 1.25], ['Bread', 1, 0.5],
    ]);
    expect(Receipt.fromJson({...storeReceipt.toJson()}..remove('lineItems')).lineItems, isNull);
  });

  test('line totals are summed in fils', () {
    expect(const LineItem(name: 'x', qty: 3, unitPrice: 0.1).lineTotal, 0.3);
    expect(ReceiptDetailScreen.formatUnitPrice(7.995), '7.995');
    expect(ReceiptDetailScreen.formatUnitPrice(1.25), '1.25');
  });

  testWidgets('store receipt: every line with qty × price and line total, then the total', (tester) async {
    await pump(tester, storeReceipt);
    expect(find.text('Carrefour'), findsOneWidget);
    expect(find.text('Receipt #AB12CD34'), findsOneWidget);
    expect(find.text('Rice 2kg'), findsOneWidget);
    expect(find.text('1 × 7.995 JD'), findsOneWidget);
    expect(find.text('8.00 JD'), findsOneWidget);   // 7.995 → 8.00 (fils first)
    expect(find.text('Milk'), findsOneWidget);
    expect(find.text('2 × 1.25 JD'), findsOneWidget);
    expect(find.text('2.50 JD'), findsOneWidget);
    expect(find.text('1 × 0.50 JD'), findsOneWidget);
    expect(find.text('4 items'), findsOneWidget);   // 1 + 2 + 1
    final total = tester.widget<Text>(find.byKey(const ValueKey('receipt-total')));
    expect(total.data, '11.00 JD');                 // 10.995 → 11.00
    expect(find.text('+10 pts earned'), findsOneWidget);
    expect(find.textContaining('not saved'), findsNothing);
  });

  testWidgets('older receipt without prices: item names and a note', (tester) async {
    await pump(tester, Receipt(
      id: 'r2', storeName: 'Zara', category: 'Clothing', totalAmount: 80,
      items: const ['Jacket', 'Socks x2'], date: DateTime(2026, 10, 10, 14, 5)));
    expect(find.text('Jacket'), findsOneWidget);
    expect(find.text('Socks x2'), findsOneWidget);
    expect(find.text('Item prices were not saved for this receipt.'), findsOneWidget);
    expect(find.text('Sat, 10 Oct 2026 · 14:05'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('receipt-total'))).data, '80.00 JD');
    expect(find.textContaining('pts earned'), findsNothing);
  });
}
