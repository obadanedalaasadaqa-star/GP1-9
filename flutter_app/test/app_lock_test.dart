import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/app_lock.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/constants.dart';
import 'package:nexus_app/core/design.dart';
import 'package:nexus_app/core/realtime_service.dart';
import 'package:nexus_app/core/receipt_model.dart';
import 'package:nexus_app/core/secure_store.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/core/token_store.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:nexus_app/main.dart' show buildNexusRoot;
import 'package:nexus_app/screens/auth_screen.dart';
import 'package:nexus_app/screens/receipt_detail_screen.dart';
import 'package:nexus_app/widgets/app_lock_overlay.dart';
import 'package:nexus_app/widgets/biometric_offer_sheet.dart';
import 'package:nexus_app/widgets/bottom_nav.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'realtime_service_test.dart' show FakeSocket;
import 'support/auth_fixtures.dart';
import 'support/face_id_support.dart';
import 'support/fake_secure_store.dart';

final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

/// An iOS widget test on the whole app. Test fonts draw every letter as a
/// full square, so the nav labels overflow by a few pixels: ignored here.
void testApp(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      original?.call(details);
    };
    try {
      await body(tester);
    } finally {
      FlutterError.onError = original;
    }
  }, variant: ios);
}

/// A stopwatch the test moves by hand (the monotonic clock, S24).
class FakeStopwatch implements Stopwatch {
  static Duration now = Duration.zero;
  Duration? _startedAt;
  Duration _stoppedElapsed = Duration.zero;

  @override
  void start() => _startedAt ??= now;
  @override
  void stop() {
    if (_startedAt != null) _stoppedElapsed = now - _startedAt!;
    _startedAt = null;
  }

  @override
  Duration get elapsed => _startedAt == null ? _stoppedElapsed : now - _startedAt!;
  @override
  int get elapsedMicroseconds => elapsed.inMicroseconds;
  @override
  int get elapsedMilliseconds => elapsed.inMilliseconds;
  @override
  int get elapsedTicks => elapsed.inMicroseconds;
  @override
  int get frequency => 1000000;
  @override
  bool get isRunning => _startedAt != null;
  @override
  void reset() => _stoppedElapsed = Duration.zero;
}

final _receipt = Receipt(
  id: 'r1',
  storeName: 'Carrefour Mecca',
  category: 'Supermarket',
  totalAmount: 12.5,
  items: const ['Milk x2'],
  date: DateTime(2026, 11, 8),
);

void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  late DateTime wall;
  late List<FakeSocket> sockets;
  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];
  late AuthProvider auth;
  late AppLock appLock;
  Completer<http.Response>? holdMe;

  setUp(() {
    wall = DateTime(2026, 11, 19, 12);
    FakeStopwatch.now = Duration.zero;
    sockets = [];
    requests.clear();
    holdMe = null;
    RealtimeService.debugSocketFactory = (url, token) {
      final s = FakeSocket(url, token);
      sockets.add(s);
      return s;
    };
    handler = (req) async {
      if (req.url.path.endsWith('/user/me')) {
        final hold = holdMe;
        if (hold != null) return hold.future;
        return http.Response(jsonEncode(userJson()), 200);
      }
      return http.Response(jsonEncode({'error': 'Not in this test.'}), 503);
    };
  });
  tearDown(() => RealtimeService.debugSocketFactory = null);

  Future<T> run<T>(Future<T> Function() body) => http.runWithClient(body, () => MockClient((req) {
        requests.add(req);
        return handler(req);
      }));

  Future<void> frames(WidgetTester tester, [int n = 10]) => run(() async {
        for (var i = 0; i < n; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      });

  void life(WidgetTester tester, AppLifecycleState s) => tester.binding.handleAppLifecycleStateChanged(s);

  /// The states iOS delivers when the app goes to the background (or the
  /// side button locks the phone), and when it comes back.
  void background(WidgetTester tester) {
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      life(tester, s);
    }
  }

  void foreground(WidgetTester tester) {
    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      life(tester, s);
    }
  }

  /// The real app, exactly as main() builds it: one AuthProvider, handed to
  /// AppLock (registered on the binding) and to buildNexusRoot. Face ID is on
  /// and the cold start unlocks through the sign-in tab's auto-prompt.
  Future<void> openApp(WidgetTester tester, {bool faceId = true}) async {
    tester.view.physicalSize = const Size(440, 956);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (faceId) {
      seedFaceIdOn();
    } else {
      seedPlain();
    }
    if (tester.binding.lifecycleState != AppLifecycleState.resumed) life(tester, AppLifecycleState.resumed);
    await run(() async {
      auth = AuthProvider();
      appLock = AppLock(auth: auth, now: () => wall, newStopwatch: FakeStopwatch.new);
      tester.binding.addObserver(appLock);
      addTearDown(() => tester.binding.removeObserver(appLock));
      await tester.pumpWidget(buildNexusRoot(auth: auth, theme: ThemeProvider(), appLock: appLock));
      await tester.pump(const Duration(seconds: 4)); // the splash
    });
    await frames(tester, 20);
    expect(auth.isLoggedIn, isTrue);
    expect(auth.biometricsOn, faceId);
  }

  /// Background for [away], then come back (through the lifecycle only).
  Future<void> away(WidgetTester tester, Duration away, {Duration? monotonic}) async {
    background(tester);
    wall = wall.add(away);
    FakeStopwatch.now += monotonic ?? away;
    foreground(tester);
    await frames(tester, 6);
  }

  /// Every label in the live semantics tree.
  List<String> semanticsLabels(WidgetTester tester) {
    final labels = <String>[];
    bool visit(SemanticsNode n) {
      if (n.label.isNotEmpty) labels.add(n.label);
      n.visitChildren(visit);
      return true;
    }

    visit(tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
    return labels;
  }

  final overlay = find.byType(AppLockOverlay);
  final unlockButton = find.byKey(const ValueKey('app-lock-unlock'));
  final passwordLink = find.byKey(const ValueKey('app-lock-password'));
  NavigatorState navigator(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator).first);

  group('the re-lock timing', () {
    testApp('T33 under 5 minutes away (both clocks) does not lock', (tester) async {
      await openApp(tester);
      await away(tester, const Duration(minutes: 4, seconds: 59));
      expect(auth.appLocked, isFalse);
      expect(overlay, findsNothing);
    });

    testApp('T33b / X16 (S18) a clock moved back before the pause locks', (tester) async {
      await openApp(tester);
      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      await away(tester, const Duration(hours: -1), monotonic: const Duration(seconds: 5));
      expect(auth.appLocked, isTrue);
    });

    testApp('T33c inactive -> resumed with no pause never locks, even after 10 minutes', (tester) async {
      await openApp(tester);
      life(tester, AppLifecycleState.inactive);
      wall = wall.add(const Duration(minutes: 10));
      FakeStopwatch.now += const Duration(minutes: 10);
      life(tester, AppLifecycleState.resumed);
      await frames(tester, 4);
      expect(auth.appLocked, isFalse);
    });

    testApp('T34 5 minutes or more with Face ID on: the overlay, and the token leaves memory', (tester) async {
      await openApp(tester);
      fakeStore.nextProtectedResult = ProtectedStatus.cancelled; // the overlay's auto-prompt
      await away(tester, const Duration(minutes: 5));
      expect(auth.appLocked, isTrue);
      expect(overlay, findsOneWidget);
      expect(await TokenStore.getToken(), isNull);
      expect(TokenStore.isLocked, isTrue);
      expect(find.text('Nexus is locked'), findsOneWidget);
      expect(find.text('Unlock to see your receipts.'), findsOneWidget);
    });

    testApp('T35 Face ID off: never locks', (tester) async {
      await openApp(tester, faceId: false);
      await away(tester, const Duration(hours: 2));
      expect(auth.appLocked, isFalse);
      expect(overlay, findsNothing);
    });

    for (final c in [
      (const Duration(minutes: 4), const Duration(minutes: 10), true),
      (const Duration(minutes: 10), const Duration(minutes: 4), true),
      (const Duration(minutes: 4), const Duration(minutes: 4), false),
    ]) {
      testApp('X22 (S24) wall ${c.$1.inMinutes} min / stopwatch ${c.$2.inMinutes} min -> locked: ${c.$3}',
          (tester) async {
        await openApp(tester);
        fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
        await away(tester, c.$1, monotonic: c.$2);
        expect(auth.appLocked, c.$3);
      });
    }
  });

  group('X13 / X13+ (S7, S23) the overlay covers everything', () {
    testApp('a pushed receipt: not hit-testable, not readable, back does nothing', (tester) async {
      final handle = tester.ensureSemantics();
      await openApp(tester);
      unawaited(navigator(tester).push(MaterialPageRoute(builder: (_) => ReceiptDetailScreen(receipt: _receipt))));
      await frames(tester, 10);
      expect(find.text('Carrefour Mecca').hitTestable(), findsWidgets);

      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      await away(tester, const Duration(minutes: 6));
      expect(overlay, findsOneWidget);
      expect(find.text('Carrefour Mecca').hitTestable(), findsNothing);
      // Not in the live semantics tree (VoiceOver can't read it).
      expect(semanticsLabels(tester).where((l) => l.contains('Carrefour')), isEmpty);
      expect(semanticsLabels(tester), contains('Nexus is locked'));
      expect(unlockButton, findsOneWidget);

      // The receipt's back button and an iOS back-swipe do nothing.
      final routesBefore = find.byType(ReceiptDetailScreen);
      await tester.tapAt(const Offset(40, 80));
      await tester.dragFrom(const Offset(2, 400), const Offset(300, 0));
      await frames(tester, 10);
      expect(routesBefore, findsOneWidget);
      expect(overlay, findsOneWidget);
      handle.dispose();
    });

    testApp('the QR sheet is covered too, and the keyboard is closed', (tester) async {
      await openApp(tester);
      await run(() async {
        await tester.tap(find.bySemanticsLabel('Show my code'));
      });
      await frames(tester, 10);
      expect(find.text('Show this\nat the till.').hitTestable(), findsOneWidget);

      // A focused field (keyboard up) in a pushed page.
      final focus = FocusNode();
      addTearDown(focus.dispose);
      unawaited(navigator(tester).push(MaterialPageRoute(
          builder: (_) => Scaffold(body: TextField(focusNode: focus, autofocus: true)))));
      await frames(tester, 10);
      expect(focus.hasFocus, isTrue);

      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      await away(tester, const Duration(minutes: 6));
      expect(focus.hasFocus, isFalse);
      expect(find.text('Show this\nat the till.').hitTestable(), findsNothing);
      expect(find.text('Nexus is locked'), findsOneWidget);
    });

    testApp('the overlay brings its own Material on the page colour', (tester) async {
      await openApp(tester);
      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      await away(tester, const Duration(minutes: 6));
      final materials = tester.widgetList<Material>(find.ancestor(of: unlockButton, matching: find.byType(Material)));
      final bg = Nx.of(tester.element(unlockButton)).bg;
      expect(materials.any((m) => m.color == bg), isTrue);
      expect(tester.takeException(), isNull);
    });

    testApp('Reduce Motion: the overlay shows at once, no fade', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await openApp(tester);
      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      background(tester);
      wall = wall.add(const Duration(minutes: 6));
      foreground(tester);
      await run(() => tester.pump());
      final fades = tester.widgetList<FadeTransition>(find.ancestor(of: overlay, matching: find.byType(FadeTransition)));
      expect(fades.every((f) => f.opacity.value == 1), isTrue);
    });
  });

  group('X14 / X14b (S8) the live socket', () {
    testApp('X14 the lock closes the socket; resume does not reconnect; no sheet; unlock reconnects',
        (tester) async {
      await openApp(tester);
      final first = sockets.last;
      first.fire('connect');
      await frames(tester, 2);

      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      await away(tester, const Duration(minutes: 6));
      expect(first.disposed, isTrue);
      final count = sockets.length;
      final connects = first.connectCalls;

      life(tester, AppLifecycleState.inactive);
      life(tester, AppLifecycleState.resumed);
      await frames(tester, 4);
      expect(sockets.length, count);
      expect(first.connectCalls, connects);

      first.fire('receipt:new', {
        'receipt': {
          'id': 'r9', 'storeName': 'Late Store', 'category': 'Food', 'totalAmount': 3,
          'items': <String>[], 'pointsEarned': 3, 'createdAt': '2026-11-19T10:00:00.000Z',
        },
        'pointsEarned': 3,
        'loyaltyPoints': 99,
      });
      await frames(tester, 6);
      expect(find.text('Late Store'), findsNothing);

      await run(() async {
        await tester.tap(unlockButton);
      });
      await frames(tester, 10);
      expect(auth.appLocked, isFalse);
      expect(overlay, findsNothing);
      expect(sockets.length, count + 1);
      expect(sockets.last.connectCalls, 1);
    });

    testApp('X14b a token change held across the lock does not reopen the socket', (tester) async {
      await openApp(tester);
      final realtime = tester.element(find.byType(NexusBottomNav)).read<RealtimeService>();
      final answer = Completer<void>();
      late Future<void> pending;
      await run(() async {
        pending = realtime.whileTokenChanges(() => answer.future);
      });
      final count = sockets.length;

      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      await away(tester, const Duration(minutes: 6));
      answer.complete();
      await run(() => pending);
      await frames(tester, 2);
      life(tester, AppLifecycleState.inactive);
      life(tester, AppLifecycleState.resumed);
      await frames(tester, 4);
      expect(sockets.length, count);
      expect(find.byType(BottomSheet), findsNothing);

      await run(() async {
        await tester.tap(unlockButton);
      });
      await frames(tester, 10);
      expect(sockets.length, count + 1);
    });
  });

  testApp('X15 (S9) a 401 that lands while locked never signs out; locked calls send nothing',
      (tester) async {
    await openApp(tester);
    final realtime = tester.element(find.byType(NexusBottomNav)).read<RealtimeService>();
    // A resume sync's /user/me is on its way...
    holdMe = Completer<http.Response>();
    final me = holdMe!;
    life(tester, AppLifecycleState.inactive);
    life(tester, AppLifecycleState.resumed);
    await frames(tester, 2);
    expect(realtime, isNotNull);
    // ...the app locks...
    fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
    await away(tester, const Duration(minutes: 6));
    holdMe = null;
    // ...and the answer is a 401.
    me.complete(http.Response(jsonEncode({'error': 'Invalid or expired token.'}), 401));
    await frames(tester, 4);
    life(tester, AppLifecycleState.inactive);
    life(tester, AppLifecycleState.resumed);
    await frames(tester, 4);
    expect(auth.isLoggedIn, isTrue);
    expect(auth.appLocked, isTrue);
    expect(fakeStore.protected, 'test-token-a');

    final before = requests.length;
    await expectLater(run(() => ApiClient.getMe()), throwsA(isA<SessionLockedException>()));
    expect(requests.length, before);
    expect(requests.where((r) => r.headers['Authorization'] == null && !r.url.path.contains('/auth/')), isEmpty);
  });

  testApp('X17 (S12) "Sign in with password": sheets closed, back to the first route, signed out',
      (tester) async {
    await openApp(tester);
    unawaited(navigator(tester).push(MaterialPageRoute(builder: (_) => ReceiptDetailScreen(receipt: _receipt))));
    await frames(tester, 6);
    navigator(tester).pop();
    await frames(tester, 6);
    await run(() async {
      await tester.tap(find.bySemanticsLabel('Show my code'));
    });
    await frames(tester, 6);
    unawaited(navigator(tester).push(MaterialPageRoute(builder: (_) => ReceiptDetailScreen(receipt: _receipt))));
    await frames(tester, 6);

    fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
    await away(tester, const Duration(minutes: 6));
    await run(() async {
      await tester.tap(passwordLink);
    });
    await frames(tester, 12);
    expect(overlay, findsNothing);
    expect(auth.appLocked, isFalse);
    expect(auth.isLoggedIn, isFalse);
    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(ReceiptDetailScreen), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(navigator(tester).canPop(), isFalse);
    expect(fakeStore.plain, isNull);
    expect(fakeStore.protected, isNull);
    expect((await SharedPreferences.getInstance()).getBool('nexus_bio_token_present'), isNull);
    // The sign-in tab is plain: no pill, no notice.
    expect(find.byKey(const ValueKey('face-id-sign-in')), findsNothing);
  });

  testApp('X21 (S23) marker cleared (S22) and re-locked: still locked, nothing sent, password path',
      (tester) async {
    await openApp(tester);
    fakeStore.throwOnWriteProtected = true;
    await run(() => TokenStore.saveSession('test-token-a')); // the S22 state: memory only, no marker
    fakeStore.throwOnWriteProtected = false;
    expect((await SharedPreferences.getInstance()).getBool('nexus_bio_token_present'), isNull);

    fakeStore.holdProtected = Completer<void>(); // keep the auto-prompt up
    await away(tester, const Duration(minutes: 6));
    expect(TokenStore.isLocked, isTrue);
    expect(overlay, findsOneWidget);
    final before = requests.length;
    await expectLater(run(() => ApiClient.getMe()), throwsA(isA<SessionLockedException>()));
    expect(requests.length, before);

    // "Not found": there is no protected item any more.
    fakeStore.holdProtected!.complete();
    await frames(tester, 6);
    expect(find.text('Face ID changed on this iPhone. Sign in with your password to turn it on again.'),
        findsOneWidget);
    expect(unlockButton, findsNothing);
    expect(find.widgetWithText(ElevatedButton, 'Sign in with password'), findsOneWidget);
    expect(requests.where((r) => r.headers['Authorization'] == null && !r.url.path.contains('/auth/')), isEmpty);
  });

  group('overlay outcomes (design 4.3)', () {
    for (final c in [
      (ProtectedStatus.error, "Face ID didn't work this time. Try again, or sign in with your password.", true),
      (ProtectedStatus.lockout, 'Face ID is locked on this iPhone. Sign in with your password.', false),
      (ProtectedStatus.invalidated,
          'Face ID changed on this iPhone. Sign in with your password to turn it on again.', false),
      (ProtectedStatus.notAvailable, 'Face ID is off for Nexus in iPhone Settings. Sign in with your password.', false),
    ]) {
      testApp(c.$1.name, (tester) async {
        await openApp(tester);
        fakeStore.nextProtectedResult = c.$1;
        await away(tester, const Duration(minutes: 6));
        expect(find.text(c.$2), findsOneWidget);
        final banner = tester.widget<Container>(find.byKey(const ValueKey('notice-banner')));
        expect((banner.decoration! as BoxDecoration).color, AppColors.amber);
        expect(unlockButton, c.$3 ? findsOneWidget : findsNothing);
        expect(find.widgetWithText(c.$3 ? TextButton : ElevatedButton, 'Sign in with password'), findsOneWidget);
        expect(auth.appLocked, isTrue);
        if (c.$1 == ProtectedStatus.invalidated || c.$1 == ProtectedStatus.notAvailable) {
          expect(fakeStore.protected, isNull);
          expect(TokenStore.bioUser, isNull);
        } else {
          expect(fakeStore.protected, 'test-token-a');
        }
      });
    }

    testApp('cancelled: rest, no notice; a tap on the button retries and unlocks', (tester) async {
      await openApp(tester);
      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      await away(tester, const Duration(minutes: 6));
      expect(find.byKey(const ValueKey('notice-banner')), findsNothing);
      expect(find.text('Unlock with Face ID'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Sign in with password'), findsOneWidget);
      await run(() async {
        await tester.tap(unlockButton);
      });
      await frames(tester, 8);
      expect(auth.appLocked, isFalse);
      expect(overlay, findsNothing);
      expect(await ApiClient.getToken(), 'test-token-a');
    });

    testApp('busy: the button ignores taps, the link still works (X17 clean-up)', (tester) async {
      final handle = tester.ensureSemantics();
      await openApp(tester);
      fakeStore.holdProtected = Completer<void>();
      await away(tester, const Duration(minutes: 6));
      expect(fakeStore.readProtectedCount, 2); // the cold start, then the overlay's auto-prompt
      expect(find.descendant(of: unlockButton, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      expect(tester.getSemantics(unlockButton).value, 'Waiting for Face ID');
      await tester.tap(unlockButton);
      await frames(tester, 2);
      expect(fakeStore.readProtectedCount, 2);

      await run(() async {
        await tester.tap(passwordLink);
      });
      await frames(tester, 10);
      expect(auth.isLoggedIn, isFalse);
      expect(overlay, findsNothing);
      expect(find.byType(AuthScreen), findsOneWidget);
      // A late Face ID answer is dropped.
      fakeStore.holdProtected!.complete();
      await frames(tester, 6);
      expect(auth.isLoggedIn, isFalse);
      expect(await ApiClient.getToken(), isNull);
      handle.dispose();
    });
  });

  group('T18b / X12 / X12+ (S20) a rotation while locked', () {
    testApp('is kept, never unlocks, and the next /user/me carries the new token', (tester) async {
      await openApp(tester);
      final changed = Completer<http.Response>();
      final base = handler;
      handler = (req) => req.url.path.endsWith('/user/password') ? changed.future : base(req);
      late Future<void> pending;
      await run(() async {
        pending = ApiClient.changePassword(currentPassword: 'Nexus@2026', newPassword: 'Nexus@2027!');
      });
      await frames(tester, 1);

      fakeStore.nextProtectedResult = ProtectedStatus.cancelled;
      await away(tester, const Duration(minutes: 6));
      final lockedAt = requests.length;
      changed.complete(http.Response(jsonEncode({'message': 'ok', 'token': 'test-token-b'}), 200));
      await run(() => pending);
      // X12+: still locked, still no token for requests.
      expect(await ApiClient.getToken(), isNull);
      expect(TokenStore.isLocked, isTrue);
      final realtime = tester.element(find.byType(NexusBottomNav)).read<RealtimeService>();
      final count = sockets.length;
      await run(realtime.start);
      expect(sockets.length, count);

      await run(() async {
        await tester.tap(unlockButton);
      });
      await frames(tester, 10);
      expect(auth.appLocked, isFalse);
      requests.clear();
      await run(() => auth.refreshUser());
      expect(bearer(requests.single), 'Bearer test-token-b');
      // Nothing after the lock carried the old token.
      expect(requests.skip(lockedAt).where((r) => bearer(r) == 'Bearer test-token-a'), isEmpty);
    });
  });

  testApp('T25 the shell opens the Face ID offer after a password sign-in', (tester) async {
    tester.view.physicalSize = const Size(440, 956);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'nexus_keychain_ready': true});
    if (tester.binding.lifecycleState != AppLifecycleState.resumed) life(tester, AppLifecycleState.resumed);
    await run(() async {
      auth = AuthProvider();
      await tester.pumpWidget(buildNexusRoot(auth: auth, theme: ThemeProvider()));
      await tester.pump(const Duration(seconds: 4));
      await auth.completeLogin('test-token-a', User.fromJson(userJson()));
    });
    await frames(tester, 12);
    expect(find.byType(BiometricOfferSheet), findsOneWidget);
    expect(find.text('Use Face ID next time?'), findsOneWidget);
  });
}

