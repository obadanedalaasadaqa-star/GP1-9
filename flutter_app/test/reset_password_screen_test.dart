import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:nexus_app/core/constants.dart';
import 'package:nexus_app/screens/forgot_password_screen.dart';
import 'package:nexus_app/screens/reset_password_screen.dart';
import 'package:nexus_app/screens/verify_email_screen.dart';
import 'package:nexus_app/widgets/code_boxes.dart';
import 'package:nexus_app/widgets/password_meter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';
import 'support/reset_harness.dart';

const _email = 'sara@nexus.test';
const _strong = 'Nexus@2027!';
const _wrong = 'That code is wrong or has expired. Check it, or send a new one.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  final h = ResetHarness();
  final setPassword = find.widgetWithText(ElevatedButton, 'Set new password');
  Finder codeField() => find.descendant(of: find.byType(CodeBoxes), matching: find.byType(TextField));
  Finder passwordField() => find.widgetWithText(TextFormField, 'Choose a strong password');
  TextField passwordInner(WidgetTester tester) =>
      tester.widget<TextField>(find.descendant(of: passwordField(), matching: find.byType(TextField)));
  CodeBoxes boxes(WidgetTester tester) => tester.widget<CodeBoxes>(find.byType(CodeBoxes));
  String code(WidgetTester tester) => boxes(tester).controller.text;

  /// Sign in → "Forgot password?" → Send code → step 2.
  Future<void> openStep2(WidgetTester tester, {bool dark = false}) async {
    await h.pump(tester, dark: dark);
    await tester.enterText(find.widgetWithText(TextFormField, 'you@example.com'), _email);
    await h.tap(tester, find.text('Forgot password?'));
    h.handler = (_) async => http.Response(forgotOk, 200);
    await h.tap(tester, find.widgetWithText(ElevatedButton, 'Send code'));
    expect(find.byType(ResetPasswordScreen), findsOneWidget);
    h.requests.clear();
  }

  /// Stop the resend timer before the test ends.
  Future<void> done(WidgetTester tester) => tester.pumpWidget(const SizedBox());

  testWidgets('P1 code boxes, a private password field with the eye, and the meter once you type',
      (tester) async {
    await openStep2(tester);
    expect(find.byType(CodeBoxes), findsOneWidget);
    expect(boxes(tester).focusNode.hasFocus, isTrue); // focused on open
    final pw = passwordInner(tester);
    expect(pw.obscureText, isTrue);
    expect(pw.autocorrect, isFalse);
    expect(pw.enableSuggestions, isFalse);
    expect(pw.autofillHints, [AutofillHints.newPassword]);
    expect(find.byTooltip('Show password'), findsOneWidget);
    expect(find.text('NEW PASSWORD'), findsOneWidget);
    expect(find.text('Weak'), findsNothing);
    await tester.enterText(passwordField(), 'abc');
    await tester.pump();
    expect(find.byType(PasswordMeter), findsOneWidget);
    expect(find.text('Weak'), findsOneWidget);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(passwordInner(tester).obscureText, isFalse);
    await done(tester);
  });

  testWidgets('P2 a short code or a weak password sends nothing', (tester) async {
    await openStep2(tester);
    await tester.enterText(codeField(), '1234');
    await tester.enterText(passwordField(), _strong);
    await h.tap(tester, setPassword);
    expect(find.text('Enter the 6-digit code.'), findsOneWidget);
    expect(boxes(tester).hasError, isTrue);

    await tester.enterText(codeField(), '123456');
    await tester.enterText(passwordField(), 'weak');
    await h.tap(tester, setPassword);
    expect(find.text('Password does not meet all the requirements'), findsOneWidget);
    expect(h.count('/auth/reset-password'), 0);
    await done(tester);
  });

  testWidgets('P3 the 6th digit moves to the empty password field and does not submit', (tester) async {
    await openStep2(tester);
    await tester.enterText(codeField(), '123456');
    await tester.pump();
    expect(passwordInner(tester).focusNode!.hasFocus, isTrue);
    expect(h.requests, isEmpty);
    await done(tester);
  });

  testWidgets('P4 success: token saved, the shell shows, reset screens gone, "Password updated ✓"',
      (tester) async {
    await openStep2(tester);
    h.handler = (_) async => http.Response(jsonEncode({'token': 'jwt-reset', 'user': userJson(email: _email)}), 200);
    await tester.enterText(codeField(), '123456');
    await tester.enterText(passwordField(), _strong);
    await h.tap(tester, setPassword);
    expect(h.count('/auth/reset-password'), 1);
    expect(jsonDecode(h.requests.last.body), {'email': _email, 'code': '123456', 'newPassword': _strong});
    expect((await SharedPreferences.getInstance()).getString('nexus_token'), 'jwt-reset');
    expect(find.text('SHELL'), findsOneWidget);
    expect(find.byType(ResetPasswordScreen), findsNothing);
    expect(find.byType(ForgotPasswordScreen), findsNothing);
    expect(find.text('Password updated ✓'), findsOneWidget);
    final bar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(bar.backgroundColor, AppColors.teal);
  });

  testWidgets('P5 a 2FA account goes to "Confirm it\'s you", nothing saved, reset screens gone',
      (tester) async {
    await openStep2(tester);
    h.handler = (req) async => req.url.path.endsWith('/auth/reset-password')
        ? http.Response(jsonEncode(challengeJson), 200)
        : http.Response(jsonEncode({'message': 'Code sent.'}), 200);
    await tester.enterText(codeField(), '123456');
    await tester.enterText(passwordField(), _strong);
    await h.tap(tester, setPassword);
    expect(find.byType(VerifyEmailScreen), findsOneWidget);
    expect(find.text("Confirm it's you"), findsOneWidget);
    expect(h.count('/auth/login/send-code'), 1); // it asks for a sign-in code on open
    expect((await SharedPreferences.getInstance()).getString('nexus_token'), isNull);
    expect(find.byType(ResetPasswordScreen), findsNothing);
    expect(find.byType(ForgotPasswordScreen), findsNothing);
    expect(find.text('SHELL'), findsNothing);
    await done(tester);
  });

  testWidgets('P6 a 400: server text in the banner, code cleared and red, password kept', (tester) async {
    await openStep2(tester);
    h.handler = (_) async => http.Response(jsonEncode({'error': _wrong}), 400);
    await tester.enterText(codeField(), '123456');
    await tester.enterText(passwordField(), _strong);
    await h.tap(tester, setPassword);
    expect(find.text(_wrong), findsOneWidget);
    expect(code(tester), isEmpty);
    expect(boxes(tester).hasError, isTrue);
    expect(boxes(tester).focusNode.hasFocus, isTrue);
    expect(passwordInner(tester).controller!.text, _strong);

    // The red state clears on the next keystroke.
    await tester.enterText(codeField(), '1');
    await tester.pump();
    expect(boxes(tester).hasError, isFalse);
    await done(tester);
  });

  testWidgets('P7 the resend countdown, "Sending…", the info line and a new countdown', (tester) async {
    await openStep2(tester);
    expect(find.text('Resend code in 60s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 60));
    expect(find.text('Resend code'), findsOneWidget);

    final reply = Completer<http.Response>();
    h.handler = (_) => reply.future;
    await h.run(() async {
      await tester.tap(find.text('Resend code'));
      await tester.pump();
      expect(find.text('Sending…'), findsOneWidget);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Sending…')).onPressed, isNull);
      reply.complete(http.Response(forgotOk, 200));
      await tester.pumpAndSettle();
    });
    expect(h.count('/auth/forgot-password'), 1);
    expect(find.text('If an account uses that email, a new code is on its way.'), findsOneWidget);
    expect(find.text('Resend code in 60s'), findsOneWidget);
    await done(tester);
  });

  testWidgets('P8 a 429 on Set new password: banner, code and password kept', (tester) async {
    await openStep2(tester);
    h.handler = (_) async =>
        http.Response(jsonEncode({'error': 'Too many attempts. Try again later.'}), 429);
    await tester.enterText(codeField(), '123456');
    await tester.enterText(passwordField(), _strong);
    await h.tap(tester, setPassword);
    expect(find.text('Too many attempts. Try again later.'), findsOneWidget);
    expect(code(tester), '123456');
    expect(passwordInner(tester).controller!.text, _strong);
    expect(boxes(tester).hasError, isFalse);
    await done(tester);
  });

  testWidgets('P9 a tap outside and a drag close the keyboard', (tester) async {
    await openStep2(tester);
    expect(boxes(tester).focusNode.hasFocus, isTrue);
    await tester.tap(find.text('Check your email'));
    await tester.pump();
    expect(boxes(tester).focusNode.hasFocus, isFalse);

    // Keyboard up (as on the phone), so the page can scroll.
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    await tester.tap(passwordField());
    await tester.pumpAndSettle();
    expect(passwordInner(tester).focusNode!.hasFocus, isTrue);
    await tester.drag(find.byType(CodeBoxes), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(passwordInner(tester).focusNode!.hasFocus, isFalse);
    await done(tester);
  });

  testWidgets('step 2 in dark mode builds with no errors', (tester) async {
    await openStep2(tester, dark: true);
    await tester.enterText(passwordField(), 'abc');
    await tester.pump();
    expect(find.text('Weak'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await done(tester);
  });
}
