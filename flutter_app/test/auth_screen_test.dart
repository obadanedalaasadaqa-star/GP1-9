import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/constants.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/main.dart' show NexusApp;
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

  const shot = ValueKey('shot');

  /// AuthScreen behind a stand-in for the app's auth gate: logged in shows
  /// "SHELL" (like _Root swapping in the main shell). The app's builder is on,
  /// so a tap outside closes the keyboard as in the app. [padding] /
  /// [viewPadding] / [viewInsets] fake the iPhone's safe areas and keyboard.
  Future<void> pumpAuth(
    WidgetTester tester, {
    Size size = const Size(800, 1200), // wide: the test font is wider than DM Sans
    FakeViewPadding? padding,
    FakeViewPadding? viewPadding,
    FakeViewPadding? viewInsets,
    bool dark = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    if (padding != null) tester.view.padding = padding;
    if (viewPadding != null) tester.view.viewPadding = viewPadding;
    if (viewInsets != null) tester.view.viewInsets = viewInsets;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    handler = (_) async => http.Response('{}', 200);
    await run(() async {
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
        ],
        child: RepaintBoundary(
          key: shot,
          child: MaterialApp(
            theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
            builder: NexusApp.appBuilder,
            home: Builder(builder: (context) {
              final auth = context.watch<AuthProvider>();
              if (auth.loading) return const SizedBox();
              return auth.isLoggedIn ? const Scaffold(body: Text('SHELL')) : const AuthScreen();
            }),
          ),
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

  // ── Phase 9: keyboard polish ──────────────────────────────────────────────

  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);
  const sheetKey = ValueKey('auth-sheet');
  const heroKey = ValueKey('auth-hero');

  // The 440x956 demo phone: keyboard down, and keyboard up as iOS reports it.
  const top = 62.0;
  const down = (padding: FakeViewPadding(top: top, bottom: 34), insets: FakeViewPadding.zero);
  const up = (padding: FakeViewPadding(top: top), insets: FakeViewPadding(bottom: 336));
  const safe = FakeViewPadding(top: top, bottom: 34);

  Future<void> pumpPhone(WidgetTester tester, {bool keyboard = true, bool dark = false}) => pumpAuth(tester,
      size: const Size(440, 956),
      padding: keyboard ? up.padding : down.padding,
      viewPadding: safe,
      viewInsets: keyboard ? up.insets : down.insets,
      dark: dark);

  ScrollPosition page(WidgetTester tester) => tester
      .state<ScrollableState>(find.ancestor(of: find.byKey(sheetKey), matching: find.byType(Scrollable)).first)
      .position;

  EditableText editable(WidgetTester tester, String hint) =>
      tester.widget<EditableText>(find.descendant(of: field(hint), matching: find.byType(EditableText)));
  bool anyFocused(WidgetTester tester) =>
      tester.widgetList<EditableText>(find.byType(EditableText)).any((e) => e.focusNode.hasFocus);
  int calls(String path) => requests.where((r) => r.url.path.endsWith(path)).length;

  /// The colour of the pixel at [p] (logical = physical, dpr 1).
  Future<Color> pixel(WidgetTester tester, Offset p) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shot));
    late Color c;
    await tester.runAsync(() async {
      final img = await boundary.toImage();
      final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final i = (p.dy.round() * img.width + p.dx.round()) * 4;
      c = Color.fromARGB(data.getUint8(i + 3), data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
      img.dispose();
    });
    return c;
  }

  /// Both pixels just inside the sheet's rounded top corners are hero colour.
  Future<void> expectHeroCorners(WidgetTester tester, {required bool dark}) async {
    final r = tester.getRect(find.byKey(sheetKey));
    expect(r.top, greaterThan(top), reason: 'corners must be below the status strip to mean anything');
    final hero = (dark ? AppColors.ink : AppColors.cobalt).toARGB32();
    expect((await pixel(tester, r.topLeft + const Offset(3, 3))).toARGB32(), hero);
    expect((await pixel(tester, r.topRight + const Offset(-4, 3))).toARGB32(), hero);
  }

  /// Drags the page by [dy], starting on a part of the page above the keyboard.
  Future<void> dragPage(WidgetTester tester, double dy) async {
    await tester.dragFrom(const Offset(8, 500), Offset(0, dy));
    await tester.pumpAndSettle();
  }

  /// A tap on the visible part of the hero, left of the wordmark.
  Future<void> tapHero(WidgetTester tester) async {
    final r = tester.getRect(find.byKey(heroKey));
    final from = r.top < top ? top : r.top;
    await tester.tapAt(Offset(r.left + 10, (from + r.bottom) / 2));
    await tester.pumpAndSettle();
  }

  group('sheet corners (T7-T9)', () {
    for (final dark in [false, true]) {
      final mode = dark ? 'dark' : 'light';

      testWidgets('T7 keyboard up: hero colour behind both corners ($mode)', (tester) async {
        await pumpPhone(tester, dark: dark);
        await expectHeroCorners(tester, dark: dark);
      }, variant: ios);

      testWidgets('T8 keyboard up, scrolled by focus and by a drag: still hero colour ($mode)', (tester) async {
        await pumpPhone(tester, dark: dark);
        await tester.tap(field('••••••••'));
        await tester.pumpAndSettle();
        expect(page(tester).pixels, greaterThan(0));
        await expectHeroCorners(tester, dark: dark);

        // Back to the top, then a 150 pt drag up.
        await dragPage(tester, 400);
        await dragPage(tester, -150);
        expect(page(tester).pixels, greaterThan(0));
        await expectHeroCorners(tester, dark: dark);
      }, variant: ios);

      testWidgets('T9 keyboard down: hero colour behind both corners ($mode)', (tester) async {
        await pumpPhone(tester, keyboard: false, dark: dark);
        await expectHeroCorners(tester, dark: dark);
      }, variant: ios);
    }
  });

  group('tap outside (T10)', () {
    testWidgets('T10a masking is only changed by the eye; closing the keyboard sends nothing', (tester) async {
      await pumpAuth(tester);
      await tester.enterText(field('you@example.com'), 't@nexus.test');
      await tester.enterText(field('••••••••'), 'Nexus@2026');
      await tester.pump();
      expect(editable(tester, '••••••••').obscureText, isTrue);
      expect(editable(tester, '••••••••').focusNode.hasFocus, isTrue);

      await tapHero(tester);
      expect(anyFocused(tester), isFalse);
      expect(editable(tester, '••••••••').obscureText, isTrue);

      await tester.tap(field('••••••••'));
      await tester.pump();
      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(editable(tester, '••••••••').obscureText, isFalse);
      expect(editable(tester, '••••••••').focusNode.hasFocus, isTrue);

      await tapHero(tester); // Q4: a shown password stays shown
      expect(anyFocused(tester), isFalse);
      expect(editable(tester, '••••••••').obscureText, isFalse);

      await tester.tap(field('••••••••'));
      await tester.pump();
      await tester.tap(find.byTooltip('Hide password'));
      await tester.pump();
      expect(editable(tester, '••••••••').obscureText, isTrue);

      // A drag needs something to scroll, as on the phone with the keyboard up.
      tester.view.viewInsets = const FakeViewPadding(bottom: 336);
      await tester.pumpAndSettle();
      expect(editable(tester, '••••••••').focusNode.hasFocus, isTrue);
      await dragPage(tester, -100);
      expect(anyFocused(tester), isFalse);
      expect(editable(tester, '••••••••').obscureText, isTrue);

      expect(calls('/auth/login'), 0);
      expect(requests, isEmpty);
    }, variant: ios);

    testWidgets('T10b a tap on the hero closes the email keyboard', (tester) async {
      await pumpAuth(tester);
      await tester.tap(field('you@example.com'));
      await tester.pump();
      expect(editable(tester, 'you@example.com').focusNode.hasFocus, isTrue);
      await tapHero(tester);
      expect(anyFocused(tester), isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    }, variant: ios);

    testWidgets('T10c Sign In and Create Account close the keyboard and send exactly one request',
        (tester) async {
      await pumpAuth(tester);
      handler = (_) async => http.Response(jsonEncode({'error': 'Invalid email or password.'}), 401);
      await run(() async {
        await tester.enterText(field('you@example.com'), 't@nexus.test');
        await tester.enterText(field('••••••••'), 'Nexus@2026');
        await tester.pump();
        expect(editable(tester, '••••••••').focusNode.hasFocus, isTrue);
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pump();
        expect(anyFocused(tester), isFalse);
        await tester.pumpAndSettle();
      });
      expect(find.text('Invalid email or password.'), findsOneWidget);
      expect(calls('/auth/login'), 1);

      await tester.tap(find.text('Register'));
      await tester.pumpAndSettle();
      handler = (_) async => http.Response(jsonEncode({'error': 'Email already registered.'}), 409);
      await run(() async {
        await tester.enterText(field('First'), 'Test');
        await tester.enterText(field('Last'), 'User');
        await tester.enterText(field('you@example.com'), 't@nexus.test');
        await tester.enterText(field('••••••••'), 'Nexus@2026');
        await tester.pump();
        expect(editable(tester, '••••••••').focusNode.hasFocus, isTrue);
        await tester.tap(find.widgetWithText(ElevatedButton, 'Create Account'));
        await tester.pump();
        expect(anyFocused(tester), isFalse);
        await tester.pumpAndSettle();
      });
      expect(find.text('Email already registered.'), findsOneWidget);
      expect(calls('/auth/register'), 1);
      expect(calls('/auth/login'), 1);
    }, variant: ios);
  });

  // Q1 = no: the hero is 300 + top inset on every phone. The 440x956 demo
  // phone fits without scrolling; short phones scroll.
  group('fit (T11)', () {
    Future<void> pumpSize(WidgetTester tester, Size size, FakeViewPadding insets) =>
        pumpAuth(tester, size: size, padding: insets, viewPadding: insets, viewInsets: FakeViewPadding.zero);

    testWidgets('T11a 440x956: fits, slip shown, hero 362', (tester) async {
      await pumpPhone(tester, keyboard: false);
      expect(page(tester).maxScrollExtent, 0);
      expect(find.byKey(const ValueKey('auth-hero-slip')), findsOneWidget);
      expect(tester.getSize(find.byKey(heroKey)).height, 362);
      expect(tester.getRect(find.byKey(sheetKey)).bottom, 956);
    }, variant: ios);

    testWidgets('T11b iPhone SE 375x667: full hero and slip, the page scrolls', (tester) async {
      await pumpSize(tester, const Size(375, 667), const FakeViewPadding(top: 20));
      expect(find.byKey(const ValueKey('auth-hero-slip')), findsOneWidget);
      expect(tester.getSize(find.byKey(heroKey)).height, 320);
      expect(page(tester).maxScrollExtent, greaterThan(0));
    }, variant: ios);

    testWidgets('T11c 13 mini 375x812: hero 350 with the keyboard down and up (no jump)', (tester) async {
      await pumpAuth(tester,
          size: const Size(375, 812),
          padding: const FakeViewPadding(top: 50, bottom: 34),
          viewPadding: const FakeViewPadding(top: 50, bottom: 34));
      expect(tester.getSize(find.byKey(heroKey)).height, 350);
      tester.view.padding = const FakeViewPadding(top: 50);
      tester.view.viewInsets = const FakeViewPadding(bottom: 336);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(heroKey)).height, 350);
    }, variant: ios);

    testWidgets('T11d 393x852: fits, regular hero 359', (tester) async {
      await pumpSize(tester, const Size(393, 852), const FakeViewPadding(top: 59, bottom: 34));
      expect(page(tester).maxScrollExtent, 0);
      expect(tester.getSize(find.byKey(heroKey)).height, 359);
    }, variant: ios);

    testWidgets('T11e 440x956: after the keyboard comes and goes, the page is back at the top', (tester) async {
      await pumpPhone(tester, keyboard: false);
      tester.view.padding = up.padding;
      tester.view.viewInsets = up.insets;
      await tester.pumpAndSettle();
      await tester.tap(field('••••••••'));
      await tester.pumpAndSettle();
      await tapHero(tester);
      tester.view.padding = down.padding;
      tester.view.viewInsets = down.insets;
      await tester.pumpAndSettle();
      expect(page(tester).pixels, 0);
    }, variant: ios);
  });

  testWidgets('T12 a drag on the page closes the keyboard', (tester) async {
    await pumpPhone(tester);
    await tester.tap(field('you@example.com'));
    await tester.pump();
    expect(editable(tester, 'you@example.com').focusNode.hasFocus, isTrue);
    await dragPage(tester, -100);
    expect(anyFocused(tester), isFalse);
  }, variant: ios);
}
