import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/realtime_service.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/screens/profile_screen.dart';
import 'package:nexus_app/screens/verify_email_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';

/// Counts the token-change wraps; never opens a socket.
class SpyRealtime extends RealtimeService {
  int wraps = 0;
  @override
  Future<T> whileTokenChanges<T>(Future<T> Function() action) async {
    wraps++;
    return action();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  late Future<http.Response> Function(http.Request) handler;
  Future<void> run(Future<void> Function() body) =>
      http.runWithClient(body, () => MockClient((req) => handler(req)));

  /// ProfileScreen behind a stand-in auth gate ("LOGGED OUT" after Sign Out).
  Future<void> pumpProfile(WidgetTester tester,
      {bool verified = true, String email = 'a@nexus.test', RealtimeService? realtime}) async {
    tester.view.physicalSize = const Size(800, 1600); // wide: the test font is wider than DM Sans
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    handler = (req) async => req.url.path.endsWith('/user/me')
        ? http.Response(jsonEncode(userJson(verified: verified, email: email)), 200)
        : http.Response(jsonEncode({'message': 'ok'}), 200);
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
            if (!auth.isLoggedIn) return const Scaffold(body: Text('LOGGED OUT'));
            // Like the main shell: the live connection is provided above the profile.
            return realtime == null
                ? const ProfileScreen()
                : ChangeNotifierProvider<RealtimeService>.value(value: realtime, child: const ProfileScreen());
          }),
        ),
      ));
      await tester.pumpAndSettle();
    });
  }

  Future<void> tapVisible(WidgetTester tester, Finder f) => run(() async {
        await tester.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);
        await tester.tap(f);
        await tester.pumpAndSettle();
      });

  testWidgets('shows the name, email and the "Verified" chip', (tester) async {
    await pumpProfile(tester);
    expect(find.text('Sara Ali'), findsWidgets);
    expect(find.text('a@nexus.test'), findsWidgets);
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text('Not verified · Verify'), findsNothing);
  });

  testWidgets('not verified: tapping the chip opens the code screen', (tester) async {
    await pumpProfile(tester, verified: false);
    expect(find.text('Verified'), findsNothing);
    await tapVisible(tester, find.text('Not verified · Verify'));
    expect(find.byType(VerifyEmailScreen), findsOneWidget);
    expect(find.text('Verify later'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stop the resend timer
  });

  testWidgets('the SIGN-IN SECURITY card is on the profile', (tester) async {
    await pumpProfile(tester);
    await run(() => tester.scrollUntilVisible(find.text('SIGN-IN SECURITY'), 200,
        scrollable: find.byType(Scrollable).first));
    expect(find.text('SIGN-IN SECURITY'), findsOneWidget);
    expect(find.byKey(const ValueKey('switch-2fa')), findsOneWidget);
  });

  testWidgets('Sign Out logs out and clears the token', (tester) async {
    await pumpProfile(tester);
    await tapVisible(tester, find.text('Sign Out'));
    expect(find.text('LOGGED OUT'), findsOneWidget);
    expect(await ApiClient.getToken(), isNull);
  });

  testWidgets('Sign out of all devices: confirm, POST /user/logout-all, logged out (no live connection)',
      (tester) async {
    await pumpProfile(tester);
    final paths = <String>[];
    handler = (req) async {
      paths.add('${req.method} ${req.url.path}');
      return http.Response(jsonEncode({'message': 'Signed out on all devices.'}), 200);
    };
    await tapVisible(tester, find.byKey(const ValueKey('logout-all')));
    expect(find.text('Sign out on every device, including this one?'), findsOneWidget);
    await run(() async {
      await tester.tap(find.byKey(const ValueKey('logout-all-confirm')));
      await tester.pumpAndSettle();
    });
    expect(paths, [endsWith('/user/logout-all')]);
    expect(paths.single, startsWith('POST'));
    expect(find.text('LOGGED OUT'), findsOneWidget);
    expect(await ApiClient.getToken(), isNull);
  });

  testWidgets('an older stored email (a@b) does not block a name edit', (tester) async {
    await pumpProfile(tester, email: 'a@b');
    final sent = <http.Request>[];
    handler = (req) async {
      sent.add(req);
      return http.Response(jsonEncode({...userJson(email: 'a@b'), 'firstName': 'Sami', 'name': 'Sami Ali'}), 200);
    };
    await tapVisible(tester, find.text('Edit name and email')); // the form has its own screen
    await run(() async {
      await tester.enterText(find.byType(TextFormField).first, 'Sami');
      await tester.pump();
    });
    expect(find.text('Required to change your email'), findsNothing); // not an email change
    await tapVisible(tester, find.text('Save Changes'));
    expect(find.text('Enter a valid email'), findsNothing);
    expect(sent, hasLength(1));
    expect(sent.single.method, 'PATCH');
    expect(sent.single.url.path, endsWith('/user/me'));
    expect(jsonDecode(sent.single.body), {'firstName': 'Sami', 'lastName': 'Ali', 'email': 'a@b'});
  });

  testWidgets('the same email in another case is not a change (no password field)', (tester) async {
    await pumpProfile(tester);
    await tapVisible(tester, find.text('Edit name and email')); // the form has its own screen
    await run(() async {
      await tester.enterText(find.widgetWithText(TextFormField, 'a@nexus.test'), ' A@Nexus.Test ');
      await tester.pump();
    });
    expect(find.text('Required to change your email'), findsNothing);
  });

  testWidgets('a changed email must be valid', (tester) async {
    await pumpProfile(tester);
    var sent = 0;
    handler = (_) async {
      sent++;
      return http.Response('{}', 200);
    };
    await tapVisible(tester, find.text('Edit name and email')); // the form has its own screen
    await run(() async {
      await tester.enterText(find.widgetWithText(TextFormField, 'a@nexus.test'), 'new@b');
      await tester.pump();
    });
    expect(find.text('Required to change your email'), findsOneWidget);
    await tapVisible(tester, find.text('Save Changes'));
    expect(find.text('Enter a valid email'), findsOneWidget);
    expect(sent, 0);
  });

  // The edit and password forms are pushed routes, which don't see the shell's
  // providers. They must still get its live connection, or the socket keeps the
  // revoked token and the user is signed out right after their own change.
  testWidgets('Change password runs inside the live connection\'s token change and keeps the new token',
      (tester) async {
    final spy = SpyRealtime();
    addTearDown(spy.dispose);
    await pumpProfile(tester, realtime: spy);
    handler = (req) async => req.url.path.endsWith('/user/password')
        ? http.Response(jsonEncode({'message': 'Password updated.', 'token': 'rotated'}), 200)
        : http.Response(jsonEncode(userJson()), 200);
    await tapVisible(tester, find.text('Change password'));
    await run(() async {
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'Old@Pass2026');
      await tester.enterText(fields.at(1), 'New@Pass2026!x');
      await tester.enterText(fields.at(2), 'New@Pass2026!x');
      await tester.pump();
    });
    await tapVisible(tester, find.text('Update Password'));
    expect(find.text('Password updated.'), findsOneWidget);
    expect(spy.wraps, 1);
    expect(await ApiClient.getToken(), 'rotated');
  });

  testWidgets('Changing the email runs inside the live connection\'s token change and keeps the new token',
      (tester) async {
    final spy = SpyRealtime();
    addTearDown(spy.dispose);
    await pumpProfile(tester, realtime: spy);
    handler = (req) async => req.method == 'PATCH' && req.url.path.endsWith('/user/me')
        ? http.Response(jsonEncode({...userJson(email: 'new@nexus.test', verified: false), 'token': 'rotated'}), 200)
        : http.Response(jsonEncode(userJson()), 200);
    await tapVisible(tester, find.text('Edit name and email'));
    await run(() async {
      await tester.enterText(find.widgetWithText(TextFormField, 'a@nexus.test'), 'new@nexus.test');
      await tester.pump();
    });
    await run(() async {
      await tester.enterText(find.byType(TextFormField).last, 'Old@Pass2026');
      await tester.pump();
    });
    await tapVisible(tester, find.text('Save Changes'));
    expect(spy.wraps, 1);
    expect(await ApiClient.getToken(), 'rotated');
    await tester.pumpWidget(const SizedBox()); // stop the verify screen's resend timer
  });
}
