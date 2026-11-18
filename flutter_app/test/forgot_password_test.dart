import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:nexus_app/screens/forgot_password_screen.dart';
import 'package:nexus_app/screens/reset_password_screen.dart';

import 'support/reset_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  final h = ResetHarness();
  Finder emailField() => find.widgetWithText(TextFormField, 'you@example.com');
  final sendCode = find.widgetWithText(ElevatedButton, 'Send code');

  /// Sign-in form → "Forgot password?" → step 1.
  Future<void> openStep1(WidgetTester tester, {String typed = ''}) async {
    await h.pump(tester);
    if (typed.isNotEmpty) await tester.enterText(emailField(), typed);
    await h.tap(tester, find.text('Forgot password?'));
    expect(find.byType(ForgotPasswordScreen), findsOneWidget);
  }

  /// The email field of step 1 (the sign-in one is under the route).
  Finder step1Email() => find.descendant(
      of: find.byType(ForgotPasswordScreen), matching: find.byType(TextFormField));

  testWidgets('F1 "Forgot password?" is on Sign In, not on Register', (tester) async {
    await h.pump(tester);
    expect(find.text('Forgot password?'), findsOneWidget);
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();
    expect(find.text('Forgot password?'), findsNothing);
  });

  testWidgets('F2 the link opens step 1 with the typed email prefilled', (tester) async {
    await openStep1(tester, typed: '  sara@nexus.test ');
    expect(find.text('Reset your password'), findsOneWidget);
    expect(find.text("Enter the email you signed up with. We'll send you a 6-digit code."), findsOneWidget);
    expect(tester.widget<TextFormField>(step1Email()).controller!.text, 'sara@nexus.test');
    expect(find.byTooltip('Back to sign in'), findsOneWidget);
  });

  testWidgets('F3 empty and no-@ emails show the field errors and send nothing', (tester) async {
    await openStep1(tester);
    await h.tap(tester, sendCode);
    expect(find.text('Email is required'), findsOneWidget);
    await tester.enterText(step1Email(), 'sara.nexus.test');
    await h.tap(tester, sendCode);
    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(h.count('/auth/forgot-password'), 0);
  });

  testWidgets('F4 Send code makes one request and opens step 2 with the neutral intro', (tester) async {
    await openStep1(tester, typed: 'sara@nexus.test');
    h.handler = (_) async => http.Response(forgotOk, 200);
    await h.tap(tester, sendCode);
    expect(h.count('/auth/forgot-password'), 1);
    expect(jsonDecode(h.requests.last.body), {'email': 'sara@nexus.test'});
    expect(find.byType(ResetPasswordScreen), findsOneWidget);
    expect(find.text('Check your email'), findsOneWidget);
    expect(find.text('If an account uses sara@nexus.test, we sent it a 6-digit code. It works for 10 minutes.',
        findRichText: true), findsOneWidget);
    expect(find.textContaining('We sent a code to', findRichText: true), findsNothing);

    // Back returns to step 1 with the email kept.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(ForgotPasswordScreen), findsOneWidget);
    expect(tester.widget<TextFormField>(step1Email()).controller!.text, 'sara@nexus.test');
  });

  testWidgets('F5 a 429 shows the server text in the banner and stays on step 1', (tester) async {
    await openStep1(tester, typed: 'sara@nexus.test');
    h.handler = (_) async =>
        http.Response(jsonEncode({'error': 'Too many reset requests. Try again later.'}), 429);
    await h.tap(tester, sendCode);
    expect(find.text('Too many reset requests. Try again later.'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byType(ResetPasswordScreen), findsNothing);
  });

  testWidgets('F6 Send code closes the keyboard first', (tester) async {
    await openStep1(tester, typed: 'sara@nexus.test');
    await tester.tap(step1Email());
    await tester.pump();
    bool focused() => tester.widget<EditableText>(
        find.descendant(of: step1Email(), matching: find.byType(EditableText))).focusNode.hasFocus;
    expect(focused(), isTrue);
    h.handler = (_) async => http.Response(
        jsonEncode({'error': 'Too many reset requests. Try again later.'}), 429);
    await h.tap(tester, sendCode);
    expect(focused(), isFalse);
  });

  testWidgets('F7 no connection: the readable banner, and the button works again', (tester) async {
    await openStep1(tester, typed: 'sara@nexus.test');
    h.handler = (_) async => throw http.ClientException('Connection refused');
    await h.tap(tester, sendCode);
    expect(find.text("Can't reach the Nexus server. Check your connection and try again."), findsOneWidget);
    expect(tester.widget<ElevatedButton>(sendCode).onPressed, isNotNull);
    expect(find.byType(ResetPasswordScreen), findsNothing);
  });

  testWidgets('step 1 in dark mode builds on the ink ground', (tester) async {
    await h.pump(tester, dark: true);
    await h.tap(tester, find.text('Forgot password?'));
    expect(find.text('Reset your password'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
