import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/biometric_service.dart';
import 'package:nexus_app/core/constants.dart';
import 'package:nexus_app/core/secure_store.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/main.dart' show NexusApp;
import 'package:nexus_app/screens/auth_screen.dart';
import 'package:nexus_app/widgets/face_id_glyph.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';
import 'support/face_id_support.dart';
import 'support/fake_biometric_service.dart';
import 'support/fake_secure_store.dart';

final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  late AuthProvider auth;

  Future<void> run(Future<void> Function() body) => http.runWithClient(body, () => MockClient((req) {
        requests.add(req);
        return handler(req);
      }));

  /// AuthScreen behind a stand-in for the auth gate (signed in shows "SHELL").
  Future<void> pumpAuth(WidgetTester tester,
      {Size size = const Size(440, 956), bool settle = true, Future<http.Response> Function(http.Request)? reply}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    requests.clear();
    handler = reply ?? (_) async => http.Response(jsonEncode(userJson()), 200);
    await run(() async {
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => auth = AuthProvider()),
        ],
        child: MaterialApp(
          builder: NexusApp.appBuilder,
          home: Builder(builder: (context) {
            final a = context.watch<AuthProvider>();
            if (a.loading) return const SizedBox();
            return a.isLoggedIn ? const Scaffold(body: Text('SHELL')) : const AuthScreen();
          }),
        ),
      ));
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
      }
    });
  }

  Future<void> tap(WidgetTester tester, Finder f) => run(() async {
        await tester.ensureVisible(f);
        await tester.tap(f);
        await tester.pumpAndSettle();
      });

  final pill = find.byKey(const ValueKey('face-id-sign-in'));
  final outline = find.byKey(const ValueKey('password-sign-in'));
  final newHere = find.text('New here? Create an account');
  final limeSignIn = find.widgetWithText(ElevatedButton, 'Sign In');
  final banner = find.byKey(const ValueKey('notice-banner'));
  final forgotRow = find.byKey(const ValueKey('forgot-password-row'));

  void expectPillLayout() {
    expect(pill, findsOneWidget);
    expect(find.descendant(of: pill, matching: find.byType(FaceIdGlyph)), findsOneWidget);
    expect(find.text('Sign in with Face ID'), findsOneWidget);
    expect(outline, findsOneWidget);
    expect(find.text('Sign in with password'), findsOneWidget);
    expect(newHere, findsNothing);
    expect(limeSignIn, findsNothing);
  }

  void expectPlainLayout() {
    expect(pill, findsNothing);
    expect(outline, findsNothing);
    expect(limeSignIn, findsOneWidget);
    expect(newHere, findsOneWidget);
  }

  Future<void> fillAndSubmit(WidgetTester tester, Finder button) async {
    await tester.enterText(find.byType(TextFormField).at(0), 'a@nexus.test');
    await tester.enterText(find.byType(TextFormField).at(1), 'Nexus@2026');
    await tap(tester, button);
  }

  group('T21 the pill and the password button go together', () {
    testWidgets('locked: pill, outline password button, no "New here?"; Register has no pill', (tester) async {
      seedFaceIdOn();
      fakeStore.nextProtectedResult = ProtectedStatus.cancelled; // the auto-prompt is cancelled
      await pumpAuth(tester);
      expectPillLayout();

      await tap(tester, find.text('Register'));
      expect(pill, findsNothing);
      expect(find.text('FIRST NAME'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Create Account'), findsOneWidget);
      expect(find.text('Have an account? Sign in instead'), findsOneWidget);

      await tap(tester, find.text('Sign In').first);
      expectPillLayout();
    }, variant: ios);

    testWidgets('not locked: the tab is as before', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpAuth(tester);
      expectPlainLayout();
      expect(banner, findsNothing);
    }, variant: ios);

    testWidgets('session ended (401 after unlock): notice, pill hidden, lime Sign In and the link', (tester) async {
      seedFaceIdOn();
      await pumpAuth(tester,
          reply: (_) async => http.Response(jsonEncode({'error': 'Invalid or expired token.'}), 401));
      expect(find.text('Your session ended. Sign in with your password.'), findsOneWidget);
      expectPlainLayout();
    }, variant: ios);

    testWidgets('faces changed: notice, pill hidden', (tester) async {
      seedFaceIdOn();
      fakeStore.nextProtectedResult = ProtectedStatus.invalidated;
      await pumpAuth(tester);
      expect(find.text('Face ID changed on this iPhone. Sign in with your password to turn it on again.'),
          findsOneWidget);
      expectPlainLayout();
    }, variant: ios);

    testWidgets('turned off for Nexus: notice, pill hidden', (tester) async {
      seedFaceIdOn();
      fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.turnedOffForApp);
      // Kept at cold start (-6 can be brief); the auto-prompt's read fails.
      fakeStore.nextProtectedResult = ProtectedStatus.failed;
      await pumpAuth(tester);
      expect(find.text('Face ID is off for Nexus in iPhone Settings. Sign in with your password.'), findsOneWidget);
      expectPlainLayout();
    }, variant: ios);

    testWidgets('not set up: notice, pill hidden', (tester) async {
      seedFaceIdOn();
      fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.notEnrolled);
      await pumpAuth(tester);
      expect(find.text("Face ID isn't set up on this iPhone. Sign in with your password."), findsOneWidget);
      expectPlainLayout();
    }, variant: ios);

    testWidgets('Touch ID phones say Touch ID', (tester) async {
      seedFaceIdOn();
      fakeBiometrics.current = const BiometricAvailability.usable(BiometricKind.fingerprint);
      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      await pumpAuth(tester);
      expect(find.text('Sign in with Touch ID'), findsOneWidget);
      expect(find.descendant(of: pill, matching: find.byIcon(Icons.fingerprint)), findsOneWidget);
    }, variant: ios);
  });

  group('T22 the prompt', () {
    testWidgets('auto-prompt once; rebuilds and tab switches never prompt again; a tap does', (tester) async {
      seedFaceIdOn();
      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      await pumpAuth(tester);
      expect(fakeStore.readProtectedCount, 1);
      await tap(tester, find.text('Register'));
      await tap(tester, find.text('Sign In').first);
      await tester.pump();
      expect(fakeStore.readProtectedCount, 1);

      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      await tap(tester, pill);
      expect(fakeStore.readProtectedCount, 2);
    }, variant: ios);

    testWidgets('a lockout cold start does not auto-prompt; the pill is the retry', (tester) async {
      seedFaceIdOn();
      fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.lockout);
      await pumpAuth(tester);
      expect(fakeStore.readProtectedCount, 0);
      expect(find.text('Face ID is locked. Sign in with your password, or unlock your iPhone and try again.'),
          findsOneWidget);
      expectPillLayout();
      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      await tap(tester, pill);
      expect(fakeStore.readProtectedCount, 1);
    }, variant: ios);

    testWidgets('busy: spinner, taps ignored, password disabled, "Waiting for Face ID"', (tester) async {
      final handle = tester.ensureSemantics();
      seedFaceIdOn();
      fakeStore.holdProtected = Completer<void>();
      await pumpAuth(tester, settle: false);
      expect(auth.unlocking, isTrue);
      expect(find.descendant(of: pill, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      expect(find.text('Sign in with Face ID'), findsOneWidget); // the label stays
      expect(tester.widget<OutlinedButton>(outline).onPressed, isNull);
      expect(tester.widget<ElevatedButton>(pill).onPressed, isNotNull); // keeps its look
      expect(tester.getSemantics(pill).value, 'Waiting for Face ID');
      expect(tester.getSemantics(pill).label, contains('Sign in with Face ID'));
      await tester.tap(pill);
      await tester.pump();
      expect(fakeStore.readProtectedCount, 1); // ignored

      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      fakeStore.holdProtected!.complete();
      await run(() => tester.pumpAndSettle());
      expect(auth.unlocking, isFalse);
      expect(tester.widget<OutlinedButton>(outline).onPressed, isNotNull);
      handle.dispose();
    }, variant: ios);

    testWidgets('during a password sign-in the pill is disabled', (tester) async {
      seedFaceIdOn();
      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      await pumpAuth(tester);
      final reply = Completer<http.Response>();
      handler = (_) => reply.future;
      await tester.enterText(find.byType(TextFormField).at(0), 'a@nexus.test');
      await tester.enterText(find.byType(TextFormField).at(1), 'Nexus@2026');
      await run(() async {
        await tester.tap(outline);
        await tester.pump();
      });
      expect(tester.widget<ElevatedButton>(pill).onPressed, isNull);
      reply.complete(http.Response(jsonEncode({'token': 'test-token-b', 'user': userJson()}), 200));
      await run(() => tester.pumpAndSettle());
      expect(find.text('SHELL'), findsOneWidget);
    }, variant: ios);
  });

  testWidgets('T23 after a cancelled Face ID the email and password sign in', (tester) async {
    seedFaceIdOn();
    fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
    await pumpAuth(tester);
    handler = (_) async => http.Response(jsonEncode({'token': 'test-token-b', 'user': userJson()}), 200);
    await fillAndSubmit(tester, outline);
    expect(find.text('SHELL'), findsOneWidget);
    expect(requests.last.url.path, endsWith('/auth/login'));
  }, variant: ios);

  group('T24 the banner spot', () {
    testWidgets('amber notice between "Forgot password?" and the button, 12 above the button', (tester) async {
      seedFaceIdOn();
      fakeStore.nextProtectedResult = ProtectedStatus.error;
      await pumpAuth(tester);
      expect(find.text("Face ID didn't work this time. Sign in with your password."), findsOneWidget);
      final box = tester.widget<Container>(banner).decoration! as BoxDecoration;
      expect(box.color, AppColors.amber);
      expect(find.descendant(of: banner, matching: find.byIcon(Icons.info_outline)), findsOneWidget);
      expect(tester.getTopLeft(banner).dy, greaterThan(tester.getBottomLeft(forgotRow).dy));
      expect(tester.getTopLeft(outline).dy - tester.getBottomLeft(banner).dy, 12);
      expectPillLayout(); // error keeps the pill
    }, variant: ios);

    testWidgets('a wrong password replaces the notice with the coral banner, never both', (tester) async {
      seedFaceIdOn();
      fakeStore.nextProtectedResult = ProtectedStatus.error;
      await pumpAuth(tester);
      expect(banner, findsOneWidget);
      handler = (_) async => http.Response(jsonEncode({'error': 'Invalid email or password.'}), 401);
      await fillAndSubmit(tester, outline);
      expect(banner, findsNothing);
      expect(find.text('Invalid email or password.'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      final coral = find.ancestor(of: find.byIcon(Icons.error_outline), matching: find.byType(Container)).first;
      expect(tester.getTopLeft(outline).dy - tester.getBottomLeft(coral).dy, 12);
    }, variant: ios);

    testWidgets('editing a field clears the notice', (tester) async {
      seedFaceIdOn();
      fakeStore.nextProtectedResult = ProtectedStatus.error;
      await pumpAuth(tester);
      await tester.enterText(find.byType(TextFormField).at(0), 'a');
      await tester.pump();
      expect(banner, findsNothing);
    }, variant: ios);

    testWidgets('no banner: no gap between the forgot row and the button (height unchanged)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpAuth(tester);
      final button = find.ancestor(of: limeSignIn, matching: find.byType(Padding)).first;
      expect(tester.getTopLeft(button).dy - tester.getBottomLeft(forgotRow).dy, 0);
    }, variant: ios);
  });

  testWidgets('X19 (S21) Android: no pill and no Face ID notice, even with the flags set', (tester) async {
    seedFaceIdOn();
    await pumpAuth(tester);
    expect(pill, findsNothing);
    expect(banner, findsNothing);
    expectPlainLayout();
    expect(fakeStore.readProtectedCount, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('the locked Sign In tab fits 393x852 without scrolling (design 1.3)', (tester) async {
    seedFaceIdOn();
    fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
    await pumpAuth(tester, size: const Size(393, 852));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scroll.position.maxScrollExtent, 0);
  }, variant: ios);
}

