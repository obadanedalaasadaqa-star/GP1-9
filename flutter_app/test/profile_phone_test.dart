import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/screens/profile_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> userJson({String? phone = '+962791234567', bool phoneVerified = false}) => {
      'id': 'u1', 'email': 'a@nexus.test', 'name': 'A B', 'firstName': 'A', 'lastName': 'B',
      'phone': phone, 'serialNumber': 'NXS-AAAAA-BBBBB', 'loyaltyPoints': 0,
      'createdAt': '2026-01-01T00:00:00.000Z', 'emailVerified': true,
      'phoneVerified': phoneVerified,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  late Map<String, dynamic> me;
  final requests = <http.Request>[];
  setUp(requests.clear);
  Future<void> run(Future<void> Function() body) => http.runWithClient(body, () => MockClient((req) async {
        requests.add(req);
        if (req.url.path.endsWith('/user/me')) return http.Response(jsonEncode(me), 200);
        if (req.url.path.endsWith('/user/phone/send-code')) {
          return http.Response(jsonEncode({'message': 'Code sent to 079 *** 4567.'}), 200);
        }
        return http.Response(jsonEncode({'error': 'not found'}), 404);
      }));

  Future<void> pumpProfile(WidgetTester tester) async {
    // Wide: the test font is much wider than the app's, so 390 would overflow.
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
                : const ProfileScreen()),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('no phone: the Phone Status row is hidden', (tester) async {
    me = userJson(phone: null);
    await pumpProfile(tester);
    expect(find.text('Email Status'), findsOneWidget);
    expect(find.text('Phone Status'), findsNothing);
  });

  testWidgets('verified phone shows a Verified chip', (tester) async {
    me = userJson(phoneVerified: true);
    await pumpProfile(tester);
    expect(find.text('Phone Status'), findsOneWidget);
    expect(find.byKey(const ValueKey('verify-phone')), findsNothing);
    // Email and phone are both verified.
    expect(find.text('Verified'), findsNWidgets(2));
  });

  testWidgets('unverified phone: "Verify" opens the SMS code screen', (tester) async {
    me = userJson();
    await pumpProfile(tester);
    expect(find.text('Phone Status'), findsOneWidget);
    expect(find.text('Not verified · Verify'), findsOneWidget);

    await run(() async {
      await tester.tap(find.byKey(const ValueKey('verify-phone')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    });
    expect(find.text('Check your messages'), findsOneWidget);
    expect(requests.where((r) => r.url.path.endsWith('/user/phone/send-code')), hasLength(1));
  });
}
