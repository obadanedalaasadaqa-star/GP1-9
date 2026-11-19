import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/biometric_service.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:nexus_app/main.dart' show NexusApp;
import 'package:nexus_app/widgets/biometric_offer_sheet.dart';
import 'package:nexus_app/widgets/face_id_glyph.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';
import 'support/fake_biometric_service.dart';
import 'support/fake_secure_store.dart';

final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

void main() {
  GoogleFonts.config.allowRuntimeFetching = false;
  late AuthProvider auth;
  final user = User.fromJson(userJson());

  Future<void> run(Future<void> Function() body) => http.runWithClient(
      body, () => MockClient((_) async => http.Response(jsonEncode(userJson()), 200)));

  /// Signs in with a password, then a stand-in shell opens the offer on its
  /// first frame when the offer is set (as `_MainShell` does).
  Future<void> signInAndOpen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(440, 956);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'nexus_keychain_ready': true});
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
            if (a.loading || !a.isLoggedIn) return const Scaffold(body: Text('SIGN IN'));
            return const _Shell();
          }),
        ),
      ));
      await tester.pumpAndSettle();
      await auth.completeLogin('test-token-a', user);
      await tester.pumpAndSettle();
    });
  }

  final enable = find.byKey(const ValueKey('bio-offer-enable'));
  final later = find.byKey(const ValueKey('bio-offer-later'));

  testWidgets('T25 the offer opens after a password sign-in; the title is a header', (tester) async {
    final handle = tester.ensureSemantics();
    await signInAndOpen(tester);
    expect(find.byType(BiometricOfferSheet), findsOneWidget);
    expect(find.text('Use Face ID next time?'), findsOneWidget);
    expect(find.byType(FaceIdGlyph), findsOneWidget);
    expect(
        find.text('Open Nexus with a glance instead of your password. Face ID unlocks the sign-in saved on '
            'this iPhone. Nexus never sees your face.'),
        findsOneWidget);
    expect(tester.getSemantics(find.text('Use Face ID next time?')), matchesSemantics(label: 'Use Face ID next time?', isHeader: true));
    handle.dispose();
  }, variant: ios);

  testWidgets('T26 "Use Face ID" succeeds: on, the sheet closes, the snackbar', (tester) async {
    await signInAndOpen(tester);
    await run(() async {
      await tester.tap(enable);
      await tester.pumpAndSettle();
    });
    expect(auth.biometricsOn, isTrue);
    expect(fakeStore.protected, 'test-token-a');
    expect(find.byType(BiometricOfferSheet), findsNothing);
    expect(find.text('Face ID is on. Next time, just look at your iPhone.'), findsOneWidget);
  }, variant: ios);

  testWidgets('T27 cancel stays open with the line; lockout has its own line; busy ignores taps and drags',
      (tester) async {
    await signInAndOpen(tester);
    fakeBiometrics.nextConfirm = BioOutcome.cancelled;
    await tester.tap(enable);
    await tester.pumpAndSettle();
    expect(auth.biometricsOn, isFalse);
    expect(find.byType(BiometricOfferSheet), findsOneWidget);
    expect(find.text("Face ID didn't go through. Try again, or choose Not now."), findsOneWidget);

    fakeBiometrics.nextConfirm = BioOutcome.lockout;
    await tester.tap(enable);
    await tester.pumpAndSettle();
    expect(find.text('Face ID is locked. Unlock your iPhone, then turn it on in Profile.'), findsOneWidget);

    // Busy: the prompt is up.
    fakeBiometrics
      ..nextConfirm = BioOutcome.cancelled
      ..holdConfirm = Completer<void>();
    await tester.tap(enable);
    await tester.pump();
    expect(find.descendant(of: enable, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    await tester.tap(enable);
    await tester.tap(later);
    await tester.pump();
    expect(fakeBiometrics.confirmCount, 3);
    expect((await SharedPreferences.getInstance()).getString('nexus_bio_declined'), isNull);
    await tester.drag(find.byType(BiometricOfferSheet), const Offset(0, 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(BiometricOfferSheet), findsOneWidget);
    expect(tester.getTopLeft(find.byType(BiometricOfferSheet)).dy, lessThan(956 - 200)); // not dragged down

    fakeBiometrics.holdConfirm!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  }, variant: ios);

  testWidgets('T28 "Not now" sets the declined flag; the next sign-in by the same user has no offer',
      (tester) async {
    await signInAndOpen(tester);
    await tester.tap(later);
    await tester.pumpAndSettle();
    expect(find.byType(BiometricOfferSheet), findsNothing);
    expect((await SharedPreferences.getInstance()).getString('nexus_bio_declined'), 'u1');
    await run(() async {
      await auth.logout();
      await tester.pumpAndSettle();
      await auth.completeLogin('test-token-b', user);
      await tester.pumpAndSettle();
    });
    expect(find.byType(BiometricOfferSheet), findsNothing);
  }, variant: ios);

  testWidgets('swiping the sheet away is "Not now" this time only', (tester) async {
    await signInAndOpen(tester);
    await tester.drag(find.byType(BiometricOfferSheet), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.byType(BiometricOfferSheet), findsNothing);
    expect((await SharedPreferences.getInstance()).getString('nexus_bio_declined'), isNull);
  }, variant: ios);
}

class _Shell extends StatefulWidget {
  const _Shell();
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.read<AuthProvider>().consumeBiometricOffer()) BiometricOfferSheet.show(context);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('SHELL'));
}
