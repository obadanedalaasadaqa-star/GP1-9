import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/biometric_service.dart';
import 'package:nexus_app/core/google_auth_service.dart';
import 'package:nexus_app/core/secure_store.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/main.dart' show NexusApp;
import 'package:nexus_app/screens/auth_screen.dart';
import 'package:nexus_app/screens/forgot_password_screen.dart';
import 'package:nexus_app/screens/profile_edit_screens.dart';
import 'package:nexus_app/screens/profile_screen.dart';
import 'package:nexus_app/screens/verify_email_screen.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/widgets/google_sign_in_button.dart';
import 'package:nexus_app/widgets/notice_banner.dart';
import 'package:nexus_app/widgets/security_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';
import 'support/face_id_support.dart';
import 'support/fake_biometric_service.dart';
import 'support/fake_google_auth_service.dart';
import 'support/fake_secure_store.dart';

// Phase 12 UI (design.md): Continue with Google on the sign-in tabs, the link
// sheet, and the "Set a password" states for Google-only accounts (W1-W14).
final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

const _need = 'This email already has a Nexus account. Enter its password once to connect Google.';
const _wrong = "That password doesn't match. Try again, or tap Forgot password.";

void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  late AuthProvider auth;
  late FakeGoogleAuthService google;

  Future<void> run(Future<void> Function() body) => http.runWithClient(
    body,
    () => MockClient((req) {
      requests.add(req);
      return handler(req);
    }),
  );
  http.Response reply(Object body, int status) => http.Response(jsonEncode(body), status);

  final googleButton = find.byKey(const ValueKey('google-sign-in'));
  final switchLink = find.byKey(const ValueKey('auth-switch-link'));

  /// AuthScreen behind a stand-in auth gate ("SHELL" when signed in).
  Future<void> pumpAuth(
    WidgetTester tester, {
    bool available = true,
    Size size = const Size(440, 956),
    FakeViewPadding? insets,
    bool dark = false,
    bool seed = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    if (insets != null) {
      tester.view.padding = insets;
      tester.view.viewPadding = insets;
    }
    addTearDown(tester.view.reset);
    if (seed) SharedPreferences.setMockInitialValues({'nexus_keychain_ready': true, 'nexus_theme_dark': dark});
    requests.clear();
    handler = (_) async => reply(userJson(), 200);
    google = FakeGoogleAuthService(available: available);
    await run(() async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ChangeNotifierProvider(create: (_) => auth = AuthProvider(google: google)),
          ],
          child: MaterialApp(
            theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
            builder: NexusApp.appBuilder,
            home: Builder(
              builder: (context) {
                final a = context.watch<AuthProvider>();
                if (a.loading) return const SizedBox();
                return a.isLoggedIn ? const Scaffold(body: Text('SHELL')) : const AuthScreen();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    });
  }

  Future<void> tap(WidgetTester tester, Finder f) => run(() async {
    await tester.ensureVisible(f);
    await tester.tap(f);
    await tester.pumpAndSettle();
  });

  /// Taps Continue with Google with [result] as Google's answer.
  Future<void> tapGoogle(WidgetTester tester, GoogleIdResult result) {
    google.results.add(result);
    return tap(tester, googleButton);
  }

  const idToken = GoogleIdToken('google-id-token-w', 'a@nexus.test');
  NxNoticeBanner bannerWith(WidgetTester tester, String text) =>
      tester.widget<NxNoticeBanner>(find.ancestor(of: find.text(text), matching: find.byType(NxNoticeBanner)));

  group('sign-in tabs', () {
    testWidgets('W1 Sign In: Google under the lime button, no switch link, no "or"', (tester) async {
      await pumpAuth(tester);
      expect(googleButton, findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(switchLink, findsNothing);
      expect(find.text('or'), findsNothing);
      expect(find.textContaining(RegExp(r'^or$', caseSensitive: false)), findsNothing);
      final lime = tester.getRect(find.widgetWithText(ElevatedButton, 'Sign In'));
      final g = tester.getRect(googleButton);
      // 10 under the lime pill's 4 pt shadow padding: 14 from its body (the
      // design's 12 → 10 fallback, so 393x852 doesn't scroll).
      expect(g.top - lime.bottom, 14);
      expect(g.height, greaterThanOrEqualTo(54));
      expect(find.descendant(of: googleButton, matching: find.byType(Image)), findsOneWidget);
    }, variant: ios);

    testWidgets('W2 Register: the same, under "Create Account"', (tester) async {
      await pumpAuth(tester);
      await tap(tester, find.text('Register'));
      expect(googleButton, findsOneWidget);
      expect(switchLink, findsNothing);
      final create = tester.getRect(find.widgetWithText(ElevatedButton, 'Create Account'));
      expect(tester.getRect(googleButton).top, greaterThan(create.bottom));
    }, variant: ios);

    testWidgets('W3 not available: no Google button, the switch link and Phase 11 notices as today', (tester) async {
      await pumpAuth(tester, available: false);
      expect(googleButton, findsNothing);
      expect(find.text('New here? Create an account'), findsOneWidget);
      await tap(tester, find.text('Register'));
      expect(find.text('Have an account? Sign in instead'), findsOneWidget);
    }, variant: ios);

    testWidgets('W3 not available: Phase 11 notice word for word', (tester) async {
      seedFaceIdOn();
      fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.notEnrolled);
      await pumpAuth(tester, available: false, seed: false);
      expect(find.text("Face ID isn't set up on this iPhone. Sign in with your password."), findsOneWidget);
    }, variant: ios);

    testWidgets('W4 busy: spinner for the G, label kept, "Waiting for Google", nothing else takes taps', (
      tester,
    ) async {
      await pumpAuth(tester);
      final semantics = tester.ensureSemantics();
      google.hold = Completer<void>();
      google.results.add(const GoogleCancelled());
      await run(() async {
        await tester.tap(googleButton);
        await tester.pump();
      });
      expect(find.descendant(of: googleButton, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      expect(find.descendant(of: googleButton, matching: find.byType(Image)), findsNothing);
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Continue with Google')), findsOneWidget);
      final node = tester.getSemantics(find.byKey(const ValueKey('google-sign-in')));
      expect(node.label, 'Continue with Google'); // the G is excluded
      expect(node.value, 'Waiting for Google');
      // The lime button, the fields and the tab bar ignore taps meanwhile.
      await run(() async {
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'), warnIfMissed: false);
        await tester.tap(find.text('Register'), warnIfMissed: false);
        await tester.pump();
      });
      expect(find.text('FIRST NAME'), findsNothing);
      expect(requests, isEmpty);
      google.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.descendant(of: googleButton, matching: find.byType(Image)), findsOneWidget);
      semantics.dispose();
    }, variant: ios);

    testWidgets('W5 every banner case: right tone and exact text', (tester) async {
      await pumpAuth(tester);
      Future<void> serverSays(int status, Map<String, Object> body) async {
        handler = (_) async => reply(body, status);
        await tapGoogle(tester, idToken);
      }

      await tapGoogle(tester, const GoogleFailed(GoogleFailureKind.plugin));
      expect(bannerWith(tester, "Google sign-in didn't go through. Try again.").error, isTrue);
      await tapGoogle(tester, const GoogleFailed(GoogleFailureKind.network));
      expect(bannerWith(tester, "Couldn't reach Google. Check your connection and try again.").error, isTrue);

      final cases = <(int, Map<String, Object>, bool)>[
        (401, {'error': "Google sign-in didn't go through. Try again."}, true),
        (
          403,
          {
            'error': "Your Google email isn't verified yet. Verify it in your Google account, then try again.",
            'code': 'google_email_unverified',
          },
          false,
        ),
        (
          409,
          {
            'error':
                'This Nexus account is connected to a different Google account. Use that one, or sign in with your password.',
            'code': 'other_google',
          },
          false,
        ),
        (
          409,
          {
            'error':
                "Google sign-in can't be used with this email. Sign in with your email and password instead.",
            'code': 'email_taken',
          },
          false,
        ),
        (429, {'error': 'Too many sign-in attempts. Try again in a few minutes.'}, true),
        (
          503,
          {'error': "Google sign-in isn't available right now. Try again soon, or use your email and password."},
          false,
        ),
        (500, {'error': "Sign-in didn't go through. Try again."}, true),
      ];
      for (final (status, body, coral) in cases) {
        await serverSays(status, body);
        expect(bannerWith(tester, body['error']! as String).error, coral, reason: '$status');
        expect(find.byType(NxNoticeBanner), findsOneWidget); // one at a time
      }
      // A cancel after a banner: a new tap cleared it, no message.
      await tapGoogle(tester, const GoogleCancelled());
      expect(find.byType(NxNoticeBanner), findsNothing);

      // The password sign-in error is the same widget now (coral).
      handler = (_) async => reply({'error': 'Invalid email or password.'}, 401);
      await tester.enterText(find.byType(TextFormField).at(0), 'a@nexus.test');
      await tester.enterText(find.byType(TextFormField).at(1), 'nope');
      await tap(tester, find.widgetWithText(ElevatedButton, 'Sign In'));
      expect(bannerWith(tester, 'Invalid email or password.').error, isTrue);
      expect(find.byKey(const ValueKey('error-banner')), findsOneWidget);
    }, variant: ios);

    testWidgets('W6 the six Face ID notices with the Google button, compared in full', (tester) async {
      const name = 'Face ID';
      const expected = {
        BiometricNotice.sessionEnded: 'Your session ended. Sign in with your password or with Google.',
        BiometricNotice.invalidated:
            'Face ID changed on this iPhone. Sign in with your password or with Google to turn it on again.',
        BiometricNotice.lockout:
            'Face ID is locked. Sign in with your password or with Google, or unlock your iPhone and try again.',
        BiometricNotice.notAvailable:
            'Face ID is off for Nexus in iPhone Settings. Sign in with your password or with Google.',
        BiometricNotice.notEnrolled: "Face ID isn't set up on this iPhone. Sign in with your password or with Google.",
        BiometricNotice.error: "Face ID didn't work this time. Sign in with your password or with Google.",
      };
      for (final e in expected.entries) {
        expect(AuthScreen.noticeTextFor(e.key, name, google: true), e.value);
      }
      expect(
        AuthScreen.noticeTextFor(BiometricNotice.sessionEnded, name),
        'Your session ended. Sign in with your password.',
      );
      // And on screen.
      seedFaceIdOn();
      fakeBiometrics.current = const BiometricAvailability.unusable(BiometricReason.notEnrolled);
      await pumpAuth(tester, seed: false);
      expect(find.text(expected[BiometricNotice.notEnrolled]!), findsOneWidget);
    }, variant: ios);

    testWidgets('W13 Face ID locked: Google comes after the password button, never next to the pill', (tester) async {
      seedFaceIdOn();
      fakeStore.nextProtectedResult = ProtectedStatus.cancelled; // the auto-prompt is cancelled
      await pumpAuth(tester, seed: false);
      final pill = tester.getRect(find.byKey(const ValueKey('face-id-sign-in')));
      final password = tester.getRect(find.byKey(const ValueKey('password-sign-in')));
      final g = tester.getRect(googleButton);
      expect(password.top, greaterThan(pill.bottom));
      expect(g.top, greaterThan(password.bottom));
      expect(g.top - password.bottom, 10);
      expect(switchLink, findsNothing);
    }, variant: ios);

    testWidgets('W14 at 393x852 fits without scrolling, the Google button costs 6 pt; light fill white', (
      tester,
    ) async {
      // Phase 11 leaves 7 pt here (measured with the app's own fonts too), so
      // the gap is 10: -14 -44 (link) +10 +54 = +6, and the tab still fits.
      const insets = FakeViewPadding(top: 59, bottom: 34);
      await pumpAuth(tester, available: false, size: const Size(393, 852), insets: insets);
      final before = tester.getRect(switchLink).bottom;
      await tester.pumpWidget(const SizedBox()); // a fresh provider
      await pumpAuth(tester, size: const Size(393, 852), insets: insets);
      expect(tester.getRect(googleButton).bottom - before, 6);
      final page = tester
          .state<ScrollableState>(
            find.ancestor(of: find.byKey(const ValueKey('auth-sheet')), matching: find.byType(Scrollable)).first,
          )
          .position;
      expect(page.maxScrollExtent, 0);
      final fill = tester.widget<OutlinedButton>(googleButton).style!.backgroundColor!.resolve({});
      expect(fill, Colors.white);
    }, variant: ios);

    testWidgets('W14 dark: the paper pill with the neutral G', (tester) async {
      await pumpAuth(tester, dark: true);
      final fill = tester.widget<OutlinedButton>(googleButton).style!.backgroundColor!.resolve({});
      expect(fill, const Color(0xFFF1F1F1));
      final image = tester.widget<Image>(find.descendant(of: googleButton, matching: find.byType(Image)));
      expect((image.image as AssetImage).assetName, 'assets/brand/google_g_neutral.png');
    }, variant: ios);
  });

  group('link sheet', () {
    Future<void> openSheet(WidgetTester tester) async {
      await pumpAuth(tester);
      handler = (_) async => reply({'error': _need, 'code': 'password_required', 'email': 'a@nexus.test'}, 409);
      await tapGoogle(tester, idToken);
    }

    final password = find.byKey(const ValueKey('google-link-password'));
    final submit = find.byKey(const ValueKey('google-link-submit'));

    testWidgets('W7 opens on password needed; empty, wrong, 429, offline, then right', (tester) async {
      await openSheet(tester);
      expect(find.text('Connect Google to your account'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('google-link-email'))).data, 'a@nexus.test');
      expect(find.byType(NxNoticeBanner), findsNothing); // nothing on the tab

      await tap(tester, submit);
      expect(find.text('Password is required'), findsOneWidget);

      await tester.enterText(password, 'Wrong@2026');
      handler = (_) async => reply({'error': _wrong, 'code': 'password_required', 'email': 'a@nexus.test'}, 401);
      await tap(tester, submit);
      expect(bannerWith(tester, _wrong).error, isTrue);
      expect(find.text('Connect Google to your account'), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.descendant(of: password, matching: find.byType(EditableText))).controller.text,
        'Wrong@2026',
      );

      handler = (_) async => reply({'error': 'Too many login attempts. Try again in a few minutes.'}, 429);
      await tap(tester, submit);
      expect(bannerWith(tester, 'Too many login attempts. Try again in a few minutes.').error, isTrue);

      handler = (_) async => throw http.ClientException('offline');
      await tap(tester, submit);
      expect(bannerWith(tester, "Can't reach the Nexus server. Check your connection and try again.").error, isTrue);
      expect(find.text('Connect Google to your account'), findsOneWidget);

      handler = (_) async => reply({'token': 'jwt', 'user': userJson()}, 200);
      await tester.enterText(password, 'Nexus@2026');
      await tap(tester, submit);
      expect(find.text('SHELL'), findsOneWidget);
      expect(find.text('Google is connected. Next time, just tap Continue with Google.'), findsOneWidget);
      expect(jsonDecode(requests.last.body), {'idToken': 'google-id-token-w', 'password': 'Nexus@2026'});
    }, variant: ios);

    testWidgets('W7 2FA on: the sheet closes and the code screen opens', (tester) async {
      await openSheet(tester);
      await tester.enterText(password, 'Nexus@2026');
      handler = (req) async =>
          req.url.path.endsWith('/auth/google') ? reply(challengeJson, 200) : reply({'message': 'sent'}, 200);
      await tap(tester, submit);
      expect(find.text('Connect Google to your account'), findsNothing);
      expect(find.byType(VerifyEmailScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox()); // stop the resend timer
    }, variant: ios);

    testWidgets('W8 Cancel drops the token; the tab is at rest', (tester) async {
      await openSheet(tester);
      await tap(tester, find.byKey(const ValueKey('google-link-cancel')));
      expect(find.text('Connect Google to your account'), findsNothing);
      expect(find.byType(NxNoticeBanner), findsNothing);
      await run(() async {
        expect(
          await auth.continueGoogleWithPassword('x'),
          isA<Object>().having((r) => r.runtimeType.toString(), 'type', 'GoogleTokenExpired'),
        );
      });
    }, variant: ios);

    testWidgets('W8 swipe down drops the token', (tester) async {
      await openSheet(tester);
      await tester.drag(find.text('Connect Google to your account'), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(find.text('Connect Google to your account'), findsNothing);
      final before = requests.length;
      await run(() async => auth.continueGoogleWithPassword('x'));
      expect(requests.length, before);
    }, variant: ios);

    testWidgets('W8 Forgot password? opens Forgot password with the Google email', (tester) async {
      await openSheet(tester);
      await tap(tester, find.byKey(const ValueKey('google-link-forgot')));
      expect(find.byType(ForgotPasswordScreen), findsOneWidget);
      expect(tester.widget<ForgotPasswordScreen>(find.byType(ForgotPasswordScreen)).initialEmail, 'a@nexus.test');
      expect(find.text('Reset your password'), findsOneWidget);
    }, variant: ios);

    testWidgets('W8 busy blocks swipe-to-dismiss; an expired token closes it with the amber text', (tester) async {
      await openSheet(tester);
      await tester.enterText(password, 'Nexus@2026');
      final held = Completer<http.Response>();
      handler = (_) => held.future;
      await run(() async {
        await tester.tap(submit);
        await tester.pump();
        await tester.drag(find.text('Connect Google to your account'), const Offset(0, 600));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Connect Google to your account'), findsOneWidget);
        expect(find.descendant(of: submit, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
        held.complete(reply({'error': "Sign-in didn't go through. Try again."}, 500));
        await tester.pumpAndSettle();
      });
      // 500: closes, coral on the tab.
      expect(find.text('Connect Google to your account'), findsNothing);
      expect(bannerWith(tester, "Sign-in didn't go through. Try again.").error, isTrue);

      // Expired: the held token is older than 10 minutes.
      var now = DateTime(2026, 11, 19, 12);
      AuthProvider.clock = () => now;
      handler = (_) async => reply({'error': _need, 'code': 'password_required', 'email': 'a@nexus.test'}, 409);
      await tapGoogle(tester, idToken);
      now = now.add(const Duration(minutes: 11));
      await tester.enterText(password, 'Nexus@2026');
      await tap(tester, submit);
      expect(find.text('Connect Google to your account'), findsNothing);
      final amber = bannerWith(tester, 'That took a while, so Google needs to check again. Tap Continue with Google.');
      expect(amber.error, isFalse);
    }, variant: ios);
  });

  group('Google-only accounts on Profile', () {
    final googleUser = {...userJson(), 'passwordSet': false};

    Future<void> pumpSignedIn(WidgetTester tester, Widget child, {Map<String, dynamic>? user}) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'nexus_token': 't'});
      handler = (_) async => reply(user ?? googleUser, 200);
      await run(() async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => ThemeProvider()),
              ChangeNotifierProvider(create: (_) => auth = AuthProvider()),
            ],
            child: MaterialApp(
              builder: NexusApp.appBuilder,
              home: Builder(
                builder: (context) {
                  final a = context.watch<AuthProvider>();
                  if (a.loading || a.user == null) return const SizedBox();
                  return child;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      });
    }

    testWidgets('W9 "Set a password" row with its muted line; opens Forgot password as Set a password', (tester) async {
      await pumpSignedIn(tester, const ProfileScreen());
      final row = find.byKey(const ValueKey('profile-set-password'));
      expect(row, findsOneWidget);
      expect(find.text('Change password'), findsNothing);
      expect(find.text('You sign in with Google. Add a password to sign in with your email too.'), findsOneWidget);
      expect(tester.getSize(row).height, greaterThanOrEqualTo(52));
      expect(find.textContaining('Google'), findsOneWidget); // only that line: no member-card line
      await tap(tester, row);
      final screen = tester.widget<ForgotPasswordScreen>(find.byType(ForgotPasswordScreen));
      expect(screen.setPassword, isTrue);
      expect(screen.initialEmail, 'a@nexus.test');
    });

    testWidgets('W9 a password account sees "Change password" as today', (tester) async {
      await pumpSignedIn(tester, const ProfileScreen(), user: userJson());
      expect(find.text('Change password'), findsOneWidget);
      expect(find.byKey(const ValueKey('profile-set-password')), findsNothing);
    });

    testWidgets('W10 Security card: switch off and disabled, "Set a password to turn this on"', (tester) async {
      await pumpSignedIn(tester, const Scaffold(body: SingleChildScrollView(child: SecurityCard())));
      final sw = tester.widget<Switch>(find.byKey(const ValueKey('switch-2fa')));
      expect(sw.value, isFalse);
      expect(sw.onChanged, isNull);
      expect(find.text('Set a password to turn this on'), findsOneWidget);
      expect(find.text('Verify your email to turn this on'), findsNothing);
      final link = find.byKey(const ValueKey('security-set-password'));
      expect(tester.getSize(link).height, greaterThanOrEqualTo(44));
      await tap(tester, link);
      expect(tester.widget<ForgotPasswordScreen>(find.byType(ForgotPasswordScreen)).setPassword, isTrue);
    });

    testWidgets('W10 no password and unverified: only the password line', (tester) async {
      await pumpSignedIn(
        tester,
        const Scaffold(body: SingleChildScrollView(child: SecurityCard())),
        user: {...userJson(verified: false), 'passwordSet': false},
      );
      expect(find.text('Set a password to turn this on'), findsOneWidget);
      expect(find.text('Verify your email to turn this on'), findsNothing);
    });

    testWidgets('W11 Edit profile: email read-only with a lock, the set-password link, names still save', (
      tester,
    ) async {
      await pumpSignedIn(tester, const EditProfileScreen());
      final email = find.byType(TextFormField).at(2);
      expect(
        tester.widget<EditableText>(find.descendant(of: email, matching: find.byType(EditableText))).readOnly,
        isTrue,
      );
      expect(find.byTooltip("Email can't be changed yet"), findsOneWidget);
      expect(find.text('You sign in with Google. Set a password to change your email.'), findsOneWidget);
      expect(find.byKey(const ValueKey('edit-set-password')), findsOneWidget);
      expect(find.text('CURRENT PASSWORD'), findsNothing);

      handler = (req) async => reply({...googleUser, 'firstName': 'Rana', 'name': 'Rana Ali'}, 200);
      await tester.enterText(find.byType(TextFormField).at(0), 'Rana');
      await tap(tester, find.text('Save Changes'));
      final body = jsonDecode(requests.last.body) as Map<String, dynamic>;
      expect(body['firstName'], 'Rana');
      expect(body['email'], 'a@nexus.test');
      expect(body.containsKey('currentPassword'), isFalse);
      expect(find.text('Profile updated.'), findsOneWidget);
    });

    testWidgets('W12 Forgot password as "Set a password", and the default unchanged', (tester) async {
      await pumpSignedIn(tester, const ForgotPasswordScreen(initialEmail: 'a@nexus.test', setPassword: true));
      expect(find.text('Set a password'), findsOneWidget);
      expect(
        find.text("We'll email a 6-digit code to this address. Enter it on the next screen with your new password."),
        findsOneWidget,
      );
      expect(find.byTooltip('Back to Profile'), findsOneWidget);
      expect(find.text('Send code'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await pumpSignedIn(tester, const ForgotPasswordScreen(initialEmail: 'a@nexus.test'));
      expect(find.text('Reset your password'), findsOneWidget);
      expect(find.byTooltip('Back to sign in'), findsOneWidget);
    });
  });

  // F11 (screen half): the copy and tone the screen picks for each failure.
  group('F11 googleNoticeFor', () {
    test('googleNoticeFor: the design 1.6 texts and tones', () {
      expect(googleNoticeFor(const GoogleAuthFailure(GoogleFailureKind.plugin)), (
        text: "Google sign-in didn't go through. Try again.",
        error: true,
      ));
      expect(googleNoticeFor(const GoogleAuthFailure(GoogleFailureKind.network)), (
        text: "Couldn't reach Google. Check your connection and try again.",
        error: true,
      ));
      const unavailable = "Google sign-in isn't available right now. Try again soon, or use your email and password.";
      expect(googleNoticeFor(ApiException(unavailable, statusCode: 503, fromServer: true)), (
        text: unavailable,
        error: false,
      ));
      expect(googleNoticeFor(ApiException('u', statusCode: 403, fromServer: true, code: 'google_email_unverified')), (
        text: 'u',
        error: false,
      ));
      expect(googleNoticeFor(ApiException('o', statusCode: 409, fromServer: true, code: 'other_google')), (
        text: 'o',
        error: false,
      ));
      expect(googleNoticeFor(ApiException('e', statusCode: 409, fromServer: true, code: 'email_taken')), (
        text: 'e',
        error: false,
      ));
      expect(googleNoticeFor(ApiException('t', statusCode: 429, fromServer: true)), (text: 't', error: true));
      expect(googleNoticeFor(ApiException('s', statusCode: 500, fromServer: true)), (text: 's', error: true));
      expect(googleNoticeFor(ApiException('n')), (text: 'n', error: true));
      expect(googleNoticeFor(StateError('x')), (text: "Sign-in didn't go through. Try again.", error: true));
    });
  });

  // F14 (S37), screen half: the real service with a bad ID never shows the
  // button; a valid fake ID does (the provider half is in
  // google_auth_provider_test.dart).
  group('F14 the auth screen with the real service', () {
    Future<void> pumpWith(WidgetTester tester, String? id, RecordingGooglePluginApi plugin) async {
      SharedPreferences.setMockInitialValues({'nexus_keychain_ready': true});
      final service = PluginGoogleAuthService(loadClientId: () async => id, plugin: plugin);
      late AuthProvider a;
      await tester.runAsync(() async {
        a = AuthProvider(google: service);
        await settle(a);
        await service.load();
      });
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: a),
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ],
          child: const MaterialApp(home: AuthScreen()),
        ),
      );
      await tester.pump();
    }

    for (final bad in <String?>[
      '',
      null,
      'paste-client-id-here.apps.googleusercontent.com',
      r'$(GOOGLE_IOS_CLIENT_ID)',
      ' 123-abc.apps.googleusercontent.com',
    ]) {
      testWidgets('ID ${bad == null ? 'null' : "'$bad'"}: no button, no plugin call', (tester) async {
        final plugin = RecordingGooglePluginApi();
        await pumpWith(tester, bad, plugin);
        expect(googleButton, findsNothing);
        expect(plugin.calls, isEmpty);
      }, variant: ios);
    }

    testWidgets('positive control: a valid fake ID shows the button', (tester) async {
      final plugin = RecordingGooglePluginApi();
      await pumpWith(tester, '123-abc.apps.googleusercontent.com', plugin);
      expect(googleButton, findsOneWidget);
      expect(plugin.calls, ['initialize']);
    }, variant: ios);
  });
}
