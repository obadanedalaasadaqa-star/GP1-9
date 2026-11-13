import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/screens/verify_code_screen.dart';
import 'package:nexus_app/screens/verify_email_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> userJson({bool phoneVerified = false}) => {
      'id': 'u1', 'email': 'a@nexus.test', 'name': 'A B', 'firstName': 'A', 'lastName': 'B',
      'phone': '+962791234567', 'serialNumber': 'NXS-AAAAA-BBBBB', 'loyaltyPoints': 0,
      'createdAt': '2026-01-01T00:00:00.000Z', 'emailVerified': false,
      'phoneVerified': phoneVerified,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  // Answers by path; /user/me always returns the profile.
  late Map<String, http.Response Function(http.Request)> routes;
  final requests = <http.Request>[];
  setUp(requests.clear);
  Future<void> run(Future<void> Function() body) => http.runWithClient(body, () => MockClient((req) async {
        requests.add(req);
        if (req.url.path.endsWith('/user/me')) return http.Response(jsonEncode(userJson()), 200);
        for (final e in routes.entries) {
          if (req.url.path.endsWith(e.key)) return e.value(req);
        }
        return http.Response(jsonEncode({'error': 'not found'}), 404);
      }));
  List<String> paths() => requests.map((r) => r.url.path).where((p) => !p.endsWith('/user/me')).toList();

  late AuthProvider auth;

  // Opens the screen from a button, so a successful verify can pop back.
  Future<void> open(WidgetTester tester, Future<void> Function(BuildContext) opener) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await run(() async {
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => auth = AuthProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => TextButton(
              onPressed: () => opener(context), child: const Text('open'))),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    });
  }

  Future<void> enterCode(WidgetTester tester, String code) => run(() async {
        await tester.enterText(find.byType(TextField), code);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      });

  final ok = http.Response(jsonEncode({'message': 'Code sent.'}), 200);

  testWidgets('email mode (old wrapper) sends an email code and keeps its texts', (tester) async {
    routes = {'/user/email/send-code': (_) => ok};
    await open(tester, (c) => VerifyEmailScreen.open(c));
    expect(find.text('Check your email'), findsOneWidget);
    expect(find.textContaining('a@nexus.test'), findsOneWidget);
    expect(find.text('Verify Email'), findsOneWidget);
    expect(find.text("Can't find it? Check your spam folder."), findsOneWidget);
    expect(paths(), [endsWith('/user/email/send-code')]);
  });

  testWidgets('email mode with sendOnOpen false sends nothing and starts the cooldown', (tester) async {
    routes = {};
    await open(tester, (c) => VerifyEmailScreen.open(c, sendOnOpen: false));
    expect(paths(), isEmpty);
    expect(find.textContaining('Resend code in'), findsOneWidget);
  });

  testWidgets('phone mode sends an SMS code and shows the number and footer', (tester) async {
    routes = {'/user/phone/send-code': (_) => ok};
    await open(tester, VerifyCodeScreen.openPhone);
    expect(find.text('Check your messages'), findsOneWidget);
    expect(find.textContaining('079 123 4567'), findsOneWidget);
    expect(find.text('Verify Number'), findsOneWidget);
    expect(find.textContaining('No SMS after a minute? Check the number in Profile.'), findsOneWidget);
    expect(find.byIcon(Icons.sms_rounded), findsOneWidget);
    expect(paths(), [endsWith('/user/phone/send-code')]);
  });

  testWidgets('6 digits verify the phone, update the user and pop', (tester) async {
    routes = {
      '/user/phone/send-code': (_) => ok,
      '/user/phone/verify': (_) => http.Response(jsonEncode(userJson(phoneVerified: true)), 200),
    };
    await open(tester, VerifyCodeScreen.openPhone);
    await enterCode(tester, '123456');
    final verify = requests.lastWhere((r) => r.url.path.endsWith('/user/phone/verify'));
    expect(jsonDecode(verify.body), {'code': '123456'});
    expect(auth.user!.phoneVerified, isTrue);
    await tester.pump(const Duration(milliseconds: 600)); // route transition
    expect(find.text('Phone number verified ✓'), findsOneWidget);
    expect(find.text('Check your messages'), findsNothing); // popped
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("a 400 with a reason shows the can't-receive message", (tester) async {
    const msg = "This number can't receive Nexus SMS yet: our demo SMS account can only text the team's numbers.";
    routes = {
      '/user/phone/send-code': (_) =>
          http.Response(jsonEncode({'error': msg, 'reason': 'trialOnly'}), 400),
    };
    await open(tester, VerifyCodeScreen.openPhone);
    expect(find.text(msg), findsOneWidget);
    expect(find.text('Resend code'), findsOneWidget); // no cooldown after a failed send
  });

  testWidgets('a wrong code shows the error and clears the boxes', (tester) async {
    routes = {
      '/user/phone/send-code': (_) => ok,
      '/user/phone/verify': (_) =>
          http.Response(jsonEncode({'error': 'Incorrect code. 4 attempts left.'}), 400),
    };
    await open(tester, VerifyCodeScreen.openPhone);
    await enterCode(tester, '000000');
    expect(find.text('Incorrect code. 4 attempts left.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(auth.user!.phoneVerified, isFalse);
  });

  test('localPhoneDisplay formats a normalized number', () {
    expect(localPhoneDisplay('+962791234567'), '079 123 4567');
    expect(localPhoneDisplay(null), '');
    expect(localPhoneDisplay('12345'), '12345');
  });
}
