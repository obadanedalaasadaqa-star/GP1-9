import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/screens/verify_email_screen.dart';
import 'package:nexus_app/widgets/security_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';

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
  List<http.Request> securityCalls() => requests.where((r) => r.url.path.endsWith('/user/security')).toList();

  late AuthProvider auth;
  Switch theSwitch(WidgetTester tester) => tester.widget<Switch>(find.byKey(const ValueKey('switch-2fa')));

  Future<void> pumpCard(WidgetTester tester, {bool verified = true, bool on = false}) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    handler = (_) async => http.Response(jsonEncode(userJson(verified: verified, twoFactor: on)), 200);
    await run(() async {
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => auth = AuthProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => context.watch<AuthProvider>().user == null
                ? const SizedBox()
                : const SingleChildScrollView(child: SecurityCard())),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    });
    requests.clear();
  }

  Future<void> tapSwitch(WidgetTester tester) => run(() async {
        await tester.tap(find.byKey(const ValueKey('switch-2fa')));
        await tester.pumpAndSettle();
      });

  testWidgets('unverified: the switch is disabled with the reason, and Verify opens the code screen', (tester) async {
    await pumpCard(tester, verified: false);
    expect(find.text('SIGN-IN SECURITY'), findsOneWidget);
    expect(find.text('Two-step sign-in'), findsOneWidget);
    expect(theSwitch(tester).onChanged, isNull);
    expect(theSwitch(tester).value, isFalse);
    expect(find.text('Verify your email to turn this on'), findsOneWidget);
    handler = (_) async => http.Response(jsonEncode({'message': 'Code sent.'}), 200);
    await run(() async {
      await tester.tap(find.text('Verify'));
      await tester.pumpAndSettle();
    });
    expect(find.byType(VerifyEmailScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stop the resend timer
  });

  testWidgets('verified and off: tapping turns it on without a password field', (tester) async {
    await pumpCard(tester);
    expect(find.text('Ask for an email code when I log in with my password'), findsOneWidget);
    expect(find.text('Verify your email to turn this on'), findsNothing);
    final reply = Completer<http.Response>();
    handler = (_) => reply.future;
    await run(() async {
      await tester.tap(find.byKey(const ValueKey('switch-2fa')));
      await tester.pump();
    });
    // Shows the new value while the request runs.
    expect(theSwitch(tester).value, isTrue);
    reply.complete(http.Response(jsonEncode(userJson(twoFactor: true)), 200));
    await run(() => tester.pumpAndSettle());
    final call = securityCalls().single;
    expect(call.method, 'PATCH');
    expect(jsonDecode(call.body), {'loginTwoFactor': true});
    expect(theSwitch(tester).value, isTrue);
    expect(auth.user!.loginTwoFactor, isTrue);
    expect(find.text("Two-step sign-in is on. Next time you log in, we'll email you a code."), findsOneWidget);
    expect(find.text('A code is emailed to you at every password login'), findsOneWidget);
  });

  testWidgets('on: Cancel in the password dialog sends nothing and keeps it on', (tester) async {
    await pumpCard(tester, on: true);
    await tapSwitch(tester);
    expect(find.text('Turn off two-step sign-in?'), findsOneWidget);
    expect(find.text('Current password'), findsOneWidget);
    await run(() async {
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });
    expect(find.byType(AlertDialog), findsNothing);
    expect(securityCalls(), isEmpty);
    expect(theSwitch(tester).value, isTrue);
  });

  testWidgets('on: a wrong password shows the server text in the dialog, which stays open', (tester) async {
    await pumpCard(tester, on: true);
    await tapSwitch(tester);
    handler = (_) async => http.Response(jsonEncode({'error': 'Current password is incorrect.'}), 401);
    await run(() async {
      await tester.enterText(find.byKey(const ValueKey('2fa-password')), 'Wrong@2026');
      await tester.tap(find.byKey(const ValueKey('2fa-turn-off')));
      await tester.pumpAndSettle();
    });
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Current password is incorrect.'), findsOneWidget);
    expect(jsonDecode(securityCalls().single.body), {'loginTwoFactor': false, 'currentPassword': 'Wrong@2026'});
    expect(theSwitch(tester).value, isTrue);
    expect(auth.user!.loginTwoFactor, isTrue);
  });

  testWidgets('on: the right password closes the dialog and turns it off', (tester) async {
    await pumpCard(tester, on: true);
    await tapSwitch(tester);
    handler = (_) async => http.Response(jsonEncode(userJson()), 200);
    await run(() async {
      await tester.enterText(find.byKey(const ValueKey('2fa-password')), 'Nexus@2026');
      await tester.tap(find.byKey(const ValueKey('2fa-turn-off')));
      await tester.pumpAndSettle();
    });
    expect(find.byType(AlertDialog), findsNothing);
    expect(theSwitch(tester).value, isFalse);
    expect(auth.user!.loginTwoFactor, isFalse);
    expect(find.text('Two-step sign-in is off.'), findsOneWidget);
  });

  testWidgets('a failed turn-on (500) goes back to off with a SnackBar', (tester) async {
    await pumpCard(tester);
    handler = (_) async => http.Response(jsonEncode({'error': 'Failed to save settings.'}), 500);
    await tapSwitch(tester);
    expect(theSwitch(tester).value, isFalse);
    expect(auth.user!.loginTwoFactor, isFalse);
    expect(find.textContaining('Failed to save settings.'), findsOneWidget);
  });
}
