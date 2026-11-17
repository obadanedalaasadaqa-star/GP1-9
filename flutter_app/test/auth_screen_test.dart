import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/screens/auth_screen.dart';
import 'package:nexus_app/screens/verify_email_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';

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

  Finder field(String hint) => find.widgetWithText(TextFormField, hint);
  String textOf(WidgetTester tester, String hint) =>
      tester.widget<TextFormField>(field(hint)).controller!.text;

  /// AuthScreen behind a stand-in for the app's auth gate: logged in shows
  /// "SHELL" (like _Root swapping in the main shell).
  Future<void> pumpAuth(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1200); // wide: the test font is wider than DM Sans
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    handler = (_) async => http.Response('{}', 200);
    await run(() async {
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
        ],
        child: MaterialApp(
          home: Builder(builder: (context) {
            final auth = context.watch<AuthProvider>();
            if (auth.loading) return const SizedBox();
            return auth.isLoggedIn ? const Scaffold(body: Text('SHELL')) : const AuthScreen();
          }),
        ),
      ));
      await tester.pumpAndSettle();
    });
  }

  Future<void> signIn(WidgetTester tester) => run(() async {
        await tester.enterText(field('you@example.com'), 'sara@nexus.test');
        await tester.enterText(field('••••••••'), 'Nexus@2026');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pumpAndSettle();
      });

  group('two-step sign-in', () {
    testWidgets('a challenge pushes the code screen for the typed email', (tester) async {
      await pumpAuth(tester);
      handler = (req) async => req.url.path.endsWith('/auth/login')
          ? http.Response(jsonEncode(challengeJson), 200)
          : http.Response(jsonEncode({'message': 'Code sent.'}), 200);
      await signIn(tester);
      expect(find.byType(VerifyEmailScreen), findsOneWidget);
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(find.textContaining('sara@nexus.test', findRichText: true), findsOneWidget);
      expect(requests.map((r) => r.url.path), contains(endsWith('/auth/login/send-code')));
      expect(find.text('SHELL'), findsNothing);
      await tester.pumpWidget(const SizedBox()); // stop the resend timer
    });

    testWidgets('Cancel returns to the form with the email and password still filled', (tester) async {
      await pumpAuth(tester);
      handler = (req) async => req.url.path.endsWith('/auth/login')
          ? http.Response(jsonEncode(challengeJson), 200)
          : http.Response(jsonEncode({'message': 'Code sent.'}), 200);
      await signIn(tester);
      await run(() async {
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      });
      expect(find.byType(VerifyEmailScreen), findsNothing);
      expect(find.byType(AuthScreen), findsOneWidget);
      expect(textOf(tester, 'you@example.com'), 'sara@nexus.test');
      expect(textOf(tester, '••••••••'), 'Nexus@2026');
      // The button is usable again (not stuck on the spinner).
      expect(find.widgetWithText(ElevatedButton, 'Sign In'), findsOneWidget);
    });

    testWidgets('Cancel during a slow verify: the late success shows the shell, no empty navigator',
        (tester) async {
      await pumpAuth(tester);
      handler = (req) async {
        final path = req.url.path;
        if (path.endsWith('/auth/login')) return http.Response(jsonEncode(challengeJson), 200);
        if (path.endsWith('/auth/login/verify')) {
          // Render waking up: the answer comes long after the tap (under the 15 s client timeout).
          await Future<void>.delayed(const Duration(seconds: 10));
          return http.Response(jsonEncode({'token': 'jwt', 'user': userJson()}), 200);
        }
        return http.Response(jsonEncode({'message': 'Code sent.'}), 200);
      };
      await signIn(tester);
      await run(() async {
        await tester.enterText(find.byType(TextField).first, '123456'); // 6 digits sends it
        await tester.pump();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      });
      expect(find.byType(VerifyEmailScreen), findsNothing);
      expect(find.byType(AuthScreen), findsOneWidget);

      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('SHELL'), findsOneWidget);
      expect(requests.map((r) => r.url.path), contains(endsWith('/auth/login/verify')));
    });

    testWidgets('a session answer logs straight in (2FA off, or an older backend)', (tester) async {
      await pumpAuth(tester);
      handler = (_) async => http.Response(jsonEncode({'token': 'jwt', 'user': userJson()}), 200);
      await signIn(tester);
      expect(find.text('SHELL'), findsOneWidget);
      expect(find.byType(VerifyEmailScreen), findsNothing);
      expect(requests.where((r) => r.url.path.contains('/auth/login/')), isEmpty);
    });

    testWidgets('a wrong password shows the server error on the form', (tester) async {
      await pumpAuth(tester);
      handler = (_) async => http.Response(jsonEncode({'error': 'Invalid email or password.'}), 401);
      await signIn(tester);
      expect(find.text('Invalid email or password.'), findsOneWidget);
      expect(find.byType(VerifyEmailScreen), findsNothing);
    });
  });

  group('form', () {
    Future<void> openRegister(WidgetTester tester) async {
      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();
    }

    testWidgets('register: empty names are required, and nothing is sent', (tester) async {
      await pumpAuth(tester);
      await openRegister(tester);
      await run(() async {
        await tester.enterText(field('you@example.com'), 'sara@nexus.test');
        await tester.enterText(field('••••••••'), 'Nexus@2026');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Create Account'));
        await tester.pumpAndSettle();
      });
      expect(find.text('Required'), findsNWidgets(2));
      expect(requests, isEmpty);
    });

    testWidgets('register: the password meter shows the strength', (tester) async {
      await pumpAuth(tester);
      await openRegister(tester);
      await tester.enterText(field('••••••••'), 'abc');
      await tester.pump();
      expect(find.text('Weak'), findsOneWidget);
      await tester.enterText(field('••••••••'), 'Nexus@2026!Long');
      await tester.pump();
      expect(find.text('Strong'), findsOneWidget);
    });

    testWidgets('switching between Sign In and Register clears the error', (tester) async {
      await pumpAuth(tester);
      handler = (_) async => http.Response(jsonEncode({'error': 'Invalid email or password.'}), 401);
      await signIn(tester);
      expect(find.text('Invalid email or password.'), findsOneWidget);
      await openRegister(tester);
      expect(find.text('Invalid email or password.'), findsNothing);
    });

    // Older accounts may have an address the strict check rejects; sign-in
    // must still accept it. New addresses (register) must be valid.
    testWidgets('sign-in with a@b: no email error, the form is sent', (tester) async {
      await pumpAuth(tester);
      handler = (_) async => http.Response(jsonEncode({'token': 'jwt', 'user': userJson(email: 'a@b')}), 200);
      await run(() async {
        await tester.enterText(field('you@example.com'), 'a@b');
        await tester.enterText(field('••••••••'), 'Nexus@2026');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pumpAndSettle();
      });
      expect(find.text('Enter a valid email'), findsNothing);
      expect(requests.map((r) => r.url.path), contains(endsWith('/auth/login')));
      expect(find.text('SHELL'), findsOneWidget);
    });

    testWidgets('register with a@b: "Enter a valid email", nothing is sent', (tester) async {
      await pumpAuth(tester);
      await openRegister(tester);
      await run(() async {
        await tester.enterText(field('First'), 'Sara');
        await tester.enterText(field('Last'), 'Ali');
        await tester.enterText(field('you@example.com'), 'a@b');
        await tester.enterText(field('••••••••'), 'Nexus@2026');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Create Account'));
        await tester.pumpAndSettle();
      });
      expect(find.text('Enter a valid email'), findsOneWidget);
      expect(requests, isEmpty);
    });

    testWidgets('register with a 51-character first name: the length error, nothing is sent', (tester) async {
      await pumpAuth(tester);
      await openRegister(tester);
      await run(() async {
        await tester.enterText(field('First'), 'S' * 51);
        await tester.enterText(field('Last'), 'Ali');
        await tester.enterText(field('you@example.com'), 'sara@nexus.test');
        await tester.enterText(field('••••••••'), 'Nexus@2026');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Create Account'));
        await tester.pumpAndSettle();
      });
      expect(find.text('First name: at most 50 characters'), findsOneWidget);
      expect(requests, isEmpty);
    });
  });
}
