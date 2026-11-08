import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/receipt_model.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:nexus_app/screens/dashboard_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  final now = DateTime.now();
  // Earlier days of this month, so they count in the month total.
  DateTime day(int d) => DateTime(now.year, now.month, d, 0, 30);
  final receipts = [
    Receipt(id: 'a', storeName: 'Carrefour', category: 'Supermarket', totalAmount: 0.1, items: const [], date: day(1)),
    Receipt(id: 'b', storeName: 'Carrefour', category: 'Supermarket', totalAmount: 0.1, items: const [], date: day(1)),
    Receipt(id: 'c', storeName: 'City Pharmacy', category: 'Pharmacy', totalAmount: 1.005, items: const [], date: day(1)),
  ];
  final user = {
    'id': 'u1', 'email': 'u1@nexus.test', 'name': 'Sim Tester', 'firstName': 'Sim',
    'lastName': 'Tester', 'emailVerified': true, 'serialNumber': 'NXS-AAAAA-BBBBB',
    'loyaltyPoints': 1, 'createdAt': '2026-01-01T00:00:00.000Z',
  };

  testWidgets('Home prints the month total and receipt amounts like Archive/Trends (fils first)',
      (tester) async {
    // Wide: test fonts draw every letter as a full square, so real-width rows overflow here.
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final client = MockClient((req) async =>
        http.Response(jsonEncode(receipts.map((r) => r.toJson()).toList()), 200));

    await http.runWithClient(() async {
      // No saved token: startup finishes without a network call; then sign the user in.
      final auth = AuthProvider();
      for (var i = 0; i < 20 && auth.loading; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      auth.updateUser(User.fromJson(user));
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider.value(value: auth),
        ],
        child: const MaterialApp(home: DashboardScreen()),
      ));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }, () => client);

    // 0.1 + 0.1 + 1.005 = 1.205 JD → 1.21 (the old toStringAsFixed printed 1.20)
    expect(find.text('1.21 JD'), findsOneWidget);
    expect(find.text('1.20 JD'), findsNothing);
    // A single 1.005 JD receipt → 1.01 (was 1.00)
    expect(find.textContaining('1.01 JD'), findsWidgets);
  });
}
