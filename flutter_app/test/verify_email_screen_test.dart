import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/login_challenge.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/main.dart' show NexusApp;
import 'package:nexus_app/screens/verify_email_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';

const _challenge = LoginChallenge(challengeToken: 'challenge-1', email: 'sara@nexus.test');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  setUp(requests.clear);
  Future<void> run(Future<void> Function() body) => http.runWithClient(body, () => MockClient((req) {
        requests.add(req);
        return handler(req);
      }));
  List<String> paths() => requests.map((r) => r.url.path).toList();

  late AuthProvider auth;

  /// A home page with an "open" button that pushes the code screen.
  /// [loggedIn]: start with a saved session (email mode) or none (login mode).
  Future<void> pumpHome(WidgetTester tester, {required bool loggedIn, LoginChallenge? login}) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(loggedIn ? {'nexus_token': 't'} : {});
    await run(() async {
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => auth = AuthProvider()),
        ],
        child: MaterialApp(
          builder: NexusApp.appBuilder,
          home: Scaffold(
            body: Builder(builder: (context) => Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(context.watch<AuthProvider>().isLoggedIn ? 'HOME logged in' : 'HOME logged out'),
                TextButton(
                  onPressed: () => login == null
                      ? VerifyEmailScreen.open(context)
                      : VerifyEmailScreen.openLogin(context, login),
                  child: const Text('open'),
                ),
              ]),
            )),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    });
  }

  Future<void> open(WidgetTester tester) => run(() async {
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      });

  Future<void> typeCode(WidgetTester tester, String code) => run(() async {
        await tester.enterText(find.byType(TextField), code);
        await tester.pumpAndSettle();
      });

  // Ends the cooldown timer so no timer is left pending.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('email mode: texts, "Verify later", and a code is requested on open', (tester) async {
    handler = (req) async => req.url.path.endsWith('/user/me')
        ? http.Response(jsonEncode(userJson(verified: false)), 200)
        : http.Response(jsonEncode({'message': 'Code sent.'}), 200);
    await pumpHome(tester, loggedIn: true);
    await open(tester);
    expect(find.text('Check your email'), findsOneWidget);
    expect(find.text('Verify Email'), findsOneWidget);
    expect(find.text('Verify later'), findsOneWidget);
    expect(find.text('Later'), findsNothing);
    expect(find.textContaining('a@nexus.test', findRichText: true), findsOneWidget);
    expect(paths(), contains(endsWith('/user/email/send-code')));
    await finish(tester);
  });

  testWidgets('Q1: "Verify later" pops and the user stays logged in, unverified', (tester) async {
    handler = (req) async => req.url.path.endsWith('/user/me')
        ? http.Response(jsonEncode(userJson(verified: false)), 200)
        : http.Response(jsonEncode({'message': 'Code sent.'}), 200);
    await pumpHome(tester, loggedIn: true);
    await open(tester);
    await run(() async {
      await tester.tap(find.text('Verify later'));
      await tester.pumpAndSettle();
    });
    expect(find.byType(VerifyEmailScreen), findsNothing);
    expect(find.text('HOME logged in'), findsOneWidget);
    expect(auth.isLoggedIn, isTrue);
    expect(auth.user!.emailVerified, isFalse);
  });

  testWidgets('login mode: texts, the typed email, and /auth/login/send-code on open', (tester) async {
    handler = (_) async => http.Response(jsonEncode({'message': 'Code sent.'}), 200);
    await pumpHome(tester, loggedIn: false, login: _challenge);
    await open(tester);
    expect(find.text("Confirm it's you"), findsOneWidget);
    expect(find.textContaining('sign-in code to\nsara@nexus.test', findRichText: true), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    final send = requests.singleWhere((r) => r.url.path.endsWith('/auth/login/send-code'));
    expect(jsonDecode(send.body), {'challengeToken': 'challenge-1'});
    expect(send.headers.containsKey('Authorization'), isFalse);
    expect(paths().where((p) => p.endsWith('/user/email/send-code')), isEmpty);
    await finish(tester);
  });

  testWidgets('login mode: 6 digits verify, log in and pop', (tester) async {
    handler = (req) async => req.url.path.endsWith('/auth/login/verify')
        ? http.Response(jsonEncode({'token': 'jwt-2', 'user': userJson(twoFactor: true)}), 200)
        : http.Response(jsonEncode({'message': 'Code sent.'}), 200);
    await pumpHome(tester, loggedIn: false, login: _challenge);
    await open(tester);
    await typeCode(tester, '123456');
    final verify = requests.singleWhere((r) => r.url.path.endsWith('/auth/login/verify'));
    expect(jsonDecode(verify.body), {'challengeToken': 'challenge-1', 'code': '123456'});
    expect(find.byType(VerifyEmailScreen), findsNothing);
    expect(find.text('HOME logged in'), findsOneWidget);
    expect(auth.user!.loginTwoFactor, isTrue);
    expect(await ApiClient.getToken(), 'jwt-2');
    expect(find.text('Email verified ✓'), findsNothing);
  });

  testWidgets('login mode: a 400 shows the error and clears the boxes', (tester) async {
    handler = (req) async => req.url.path.endsWith('/auth/login/verify')
        ? http.Response(jsonEncode({'error': 'Incorrect code. 4 attempts left.'}), 400)
        : http.Response(jsonEncode({'message': 'Code sent.'}), 200);
    await pumpHome(tester, loggedIn: false, login: _challenge);
    await open(tester);
    await typeCode(tester, '111111');
    expect(find.text('Incorrect code. 4 attempts left.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(find.text('Sign in'), findsOneWidget);
    expect(auth.isLoggedIn, isFalse);
    await finish(tester);
  });

  testWidgets('login mode: a 401 shows "Back to login", which pops', (tester) async {
    handler = (req) async => req.url.path.endsWith('/auth/login/verify')
        ? http.Response(jsonEncode({'error': 'Your sign-in expired. Please log in again.'}), 401)
        : http.Response(jsonEncode({'message': 'Code sent.'}), 200);
    await pumpHome(tester, loggedIn: false, login: _challenge);
    await open(tester);
    await typeCode(tester, '123456');
    expect(find.text('Your sign-in expired. Please log in again.'), findsOneWidget);
    expect(find.text('Back to login'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
    await run(() async {
      await tester.tap(find.text('Back to login'));
      await tester.pumpAndSettle();
    });
    expect(find.byType(VerifyEmailScreen), findsNothing);
    expect(find.text('HOME logged out'), findsOneWidget);
  });

  testWidgets('login mode: a 429 "Please wait 42s" starts the cooldown', (tester) async {
    handler = (_) async => http.Response(
        jsonEncode({'error': 'Please wait 42s before requesting a new code.', 'waitSeconds': 42}), 429);
    await pumpHome(tester, loggedIn: false, login: _challenge);
    await open(tester);
    expect(find.text('Resend code in 42s'), findsOneWidget);
    expect(find.textContaining('Please wait'), findsNothing);
    await finish(tester);
  });

  testWidgets('login mode: Cancel pops without logging in', (tester) async {
    handler = (_) async => http.Response(jsonEncode({'message': 'Code sent.'}), 200);
    await pumpHome(tester, loggedIn: false, login: _challenge);
    await open(tester);
    await run(() async {
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });
    expect(find.byType(VerifyEmailScreen), findsNothing);
    expect(auth.isLoggedIn, isFalse);
  });

  // T14: closing the number pad never sends a partial code (no attempt used).
  group('T14 tap outside keeps the partial code', () {
    final ios = TargetPlatformVariant.only(TargetPlatform.iOS);
    EditableText code(WidgetTester tester) =>
        tester.widget<EditableText>(find.descendant(of: find.byType(TextField), matching: find.byType(EditableText)));

    Future<void> partialThenFinish(WidgetTester tester, {required String title, required String verifyPath}) async {
      expect(code(tester).focusNode.hasFocus, isTrue); // focused on open
      await run(() async {
        await tester.enterText(find.byType(TextField), '123');
        await tester.pump();
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
      });
      expect(code(tester).focusNode.hasFocus, isFalse);
      expect(code(tester).controller.text, '123');
      expect(paths().where((p) => p.endsWith(verifyPath)), isEmpty);

      // Tap the six boxes (their GestureDetector wraps the hidden field).
      await tester.tap(find.ancestor(of: find.byType(TextField), matching: find.byType(GestureDetector)).first);
      await tester.pump();
      expect(code(tester).focusNode.hasFocus, isTrue);
      await run(() async {
        tester.testTextInput.updateEditingValue(const TextEditingValue(
            text: '123456', selection: TextSelection.collapsed(offset: 6)));
        await tester.pumpAndSettle();
      });
      final verify = requests.where((r) => r.url.path.endsWith(verifyPath)).toList();
      expect(verify, hasLength(1));
      expect(jsonDecode(verify.single.body)['code'], '123456');
    }

    testWidgets('email mode: "Check your email"', (tester) async {
      handler = (req) async => req.url.path.endsWith('/user/me')
          ? http.Response(jsonEncode(userJson(verified: false)), 200)
          : http.Response(jsonEncode({'message': 'ok', 'user': userJson()}), 200);
      await pumpHome(tester, loggedIn: true);
      await open(tester);
      await partialThenFinish(tester, title: 'Check your email', verifyPath: '/user/email/verify');
      await finish(tester);
    }, variant: ios);

    testWidgets('sign-in mode: "Confirm it\'s you"', (tester) async {
      handler = (req) async => req.url.path.endsWith('/auth/login/verify')
          ? http.Response(jsonEncode({'error': 'Incorrect code. 4 attempts left.'}), 400)
          : http.Response(jsonEncode({'message': 'Code sent.'}), 200);
      await pumpHome(tester, loggedIn: false, login: _challenge);
      await open(tester);
      await partialThenFinish(tester, title: "Confirm it's you", verifyPath: '/auth/login/verify');
      await finish(tester);
    }, variant: ios);
  });
}
