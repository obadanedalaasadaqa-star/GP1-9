import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/biometric_service.dart';
import 'package:nexus_app/core/design.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/main.dart' show NexusApp;
import 'package:nexus_app/screens/verify_email_screen.dart';
import 'package:nexus_app/widgets/face_id_glyph.dart';
import 'package:nexus_app/widgets/security_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';
import 'support/fake_biometric_service.dart';
import 'support/fake_secure_store.dart';

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
          builder: NexusApp.appBuilder,
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

  testWidgets('T16 a tap on the dialog title closes the keyboard; the dialog stays and nothing is sent',
      (tester) async {
    await pumpCard(tester, on: true);
    await tapSwitch(tester);
    final pw = find.descendant(of: find.byKey(const ValueKey('2fa-password')), matching: find.byType(EditableText));
    await run(() async {
      await tester.enterText(find.byKey(const ValueKey('2fa-password')), 'Nexus@2026');
      await tester.pump();
    });
    expect(tester.widget<EditableText>(pw).focusNode.hasFocus, isTrue);
    await run(() async {
      await tester.tap(find.text('Turn off two-step sign-in?'));
      await tester.pumpAndSettle();
    });
    expect(tester.widget<EditableText>(pw).focusNode.hasFocus, isFalse);
    expect(tester.widget<EditableText>(pw).obscureText, isTrue);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(securityCalls(), isEmpty);
    expect(theSwitch(tester).value, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  // ── Face ID row (GP2 phase 11) ────────────────────────────────────────────

  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);
  final bioKey = find.byKey(const ValueKey('switch-face-id'));
  Switch bioSwitch(WidgetTester tester) => tester.widget<Switch>(bioKey);

  Future<void> tapBio(WidgetTester tester) => run(() async {
        await tester.tap(bioKey);
        await tester.pumpAndSettle();
      });

  Future<void> pumpOn(WidgetTester tester) async {
    await pumpCard(tester);
    await run(() async {
      expect(await auth.enableBiometrics(), BioOutcome.success);
      await tester.pumpAndSettle();
    });
    fakeBiometrics.confirmCount = 0;
  }

  testWidgets('T29 switching on asks Face ID and ends on, with the snackbar', (tester) async {
    await pumpCard(tester);
    expect(find.text('Face ID'), findsOneWidget);
    expect(find.text('Open Nexus with Face ID instead of your password'), findsOneWidget);
    expect(bioSwitch(tester).value, isFalse);
    await tapBio(tester);
    expect(fakeBiometrics.confirmCount, 1);
    expect(bioSwitch(tester).value, isTrue);
    expect(auth.biometricsOn, isTrue);
    expect(find.text('Nexus opens with Face ID on this iPhone'), findsOneWidget);
    expect(find.text('Face ID is on. Next time, just look at your iPhone.'), findsOneWidget);
  }, variant: ios);

  testWidgets('T29 while the prompt is up the switch shows on and is disabled', (tester) async {
    await pumpCard(tester);
    fakeBiometrics.holdConfirm = Completer<void>();
    await run(() async {
      await tester.tap(bioKey);
      await tester.pump();
    });
    expect(bioSwitch(tester).value, isTrue);
    expect(bioSwitch(tester).onChanged, isNull);
    fakeBiometrics.holdConfirm!.complete();
    await run(() => tester.pumpAndSettle());
  }, variant: ios);

  testWidgets('T30 turning on: cancel goes back off; lockout has its own line', (tester) async {
    await pumpCard(tester);
    fakeBiometrics.nextConfirm = BioOutcome.cancelled;
    await tapBio(tester);
    expect(bioSwitch(tester).value, isFalse);
    expect(find.text("Face ID didn't go through, so it's still off."), findsOneWidget);
    ScaffoldMessenger.of(tester.element(bioKey)).removeCurrentSnackBar();
    await tester.pumpAndSettle();

    fakeBiometrics.nextConfirm = BioOutcome.lockout;
    await tapBio(tester);
    expect(bioSwitch(tester).value, isFalse);
    expect(find.text("Face ID is locked, so it's still off. Unlock your iPhone, then try again."), findsOneWidget);
  }, variant: ios);

  testWidgets('T31 (S19) switching off with a match: the token goes back to the plain item', (tester) async {
    await pumpOn(tester);
    await tapBio(tester);
    expect(fakeBiometrics.confirmCount, 1);
    expect(bioSwitch(tester).value, isFalse);
    expect(fakeStore.plain, 't');
    expect(fakeStore.protected, isNull);
    expect(find.text('Face ID is off.'), findsOneWidget);
  }, variant: ios);

  testWidgets('X18 (S19) switching off: cancel and lockout leave it on and protected', (tester) async {
    await pumpOn(tester);
    fakeBiometrics.nextConfirm = BioOutcome.cancelled;
    await tapBio(tester);
    expect(bioSwitch(tester).value, isTrue);
    expect(fakeStore.protected, 't');
    expect(fakeStore.plain, isNull);
    expect(find.text("Face ID didn't go through, so it's still on."), findsOneWidget);
    ScaffoldMessenger.of(tester.element(bioKey)).removeCurrentSnackBar();
    await tester.pumpAndSettle();

    fakeBiometrics.nextConfirm = BioOutcome.lockout;
    await tapBio(tester);
    expect(bioSwitch(tester).value, isTrue);
    expect(fakeStore.protected, 't');
    expect(find.text("Face ID is locked, so it's still on. Unlock your iPhone, then try again."), findsOneWidget);
  }, variant: ios);

  for (final c in [
    (BiometricReason.notEnrolled, 'Set up Face ID in iPhone Settings to use this'),
    (BiometricReason.noPasscode, 'Set up Face ID in iPhone Settings to use this'),
    (BiometricReason.turnedOffForApp, 'Allow Face ID for Nexus in iPhone Settings to use this'),
    (BiometricReason.noHardware, 'Not available on this iPhone'),
    (BiometricReason.lockout, 'Face ID is locked. Unlock your iPhone, then try again'),
    (BiometricReason.unknown, "Couldn't check Face ID just now. Reopen Nexus to try again"),
  ]) {
    testWidgets('T32 off and not usable (${c.$1.name}): off, disabled, with the reason', (tester) async {
      fakeBiometrics.current = BiometricAvailability.unusable(c.$1);
      await pumpCard(tester);
      expect(bioSwitch(tester).value, isFalse);
      expect(bioSwitch(tester).onChanged, isNull);
      expect(find.text(c.$2), findsOneWidget);
      expect(theSwitch(tester).onChanged, isNotNull); // two-step unchanged
    }, variant: ios);
  }

  for (final c in [
    (BiometricReason.lockout, 'Face ID is locked. Unlock your iPhone, then try again'),
    (BiometricReason.turnedOffForApp, 'Allow Face ID for Nexus in iPhone Settings to use this'),
  ]) {
    testWidgets('T32 on, then ${c.$1.name} while open: on and disabled (the switch never moves)',
        (tester) async {
      await pumpOn(tester);
      fakeBiometrics.current = BiometricAvailability.unusable(c.$1);
      // A resume refreshes availability (AppLock); Profile does the same on build.
      await run(() async {
        await auth.refreshBiometricAvailability();
        await tester.pumpAndSettle();
      });
      expect(bioSwitch(tester).value, isTrue);
      expect(bioSwitch(tester).value, auth.biometricsOn);
      expect(bioSwitch(tester).onChanged, isNull);
      expect(find.text(c.$2), findsOneWidget);
    }, variant: ios);
  }

  testWidgets('T32 the row has no glyph and is one merged semantics node', (tester) async {
    await pumpCard(tester);
    expect(find.descendant(of: find.byType(SecurityCard), matching: find.byType(FaceIdGlyph)), findsNothing);
    expect(find.ancestor(of: bioKey, matching: find.byType(MergeSemantics)), findsOneWidget);
    expect(find.byType(NxRowDivider), findsOneWidget);
  }, variant: ios);

  testWidgets('X19 (S21) Android: no Face ID row', (tester) async {
    await pumpCard(tester);
    expect(bioKey, findsNothing);
    expect(find.text('Face ID'), findsNothing);
    expect(find.byKey(const ValueKey('switch-2fa')), findsOneWidget);
  });
}
