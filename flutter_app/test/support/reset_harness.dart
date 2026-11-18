import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/main.dart' show NexusApp;
import 'package:nexus_app/screens/auth_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Test harness for the forgot-password flow: AuthScreen behind a stand-in
/// for the app's auth gate (logged in shows "SHELL"), with the app's builder
/// (tap outside closes the keyboard) and a fake HTTP client.
class ResetHarness {
  late Future<http.Response> Function(http.Request) handler;
  final requests = <http.Request>[];

  Future<T> run<T>(Future<T> Function() body) => http.runWithClient(body, () => MockClient((req) {
        requests.add(req);
        return handler(req);
      }));

  List<String> paths() => requests.map((r) => r.url.path).toList();
  int count(String suffix) => paths().where((p) => p.endsWith(suffix)).length;

  Future<void> pump(WidgetTester tester, {bool dark = false}) async {
    tester.view.physicalSize = const Size(440, 956);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    requests.clear();
    SharedPreferences.setMockInitialValues({});
    handler = (_) async => http.Response('{}', 200);
    await run(() async {
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
          builder: NexusApp.appBuilder,
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

  /// Tap a widget inside the fake HTTP zone and settle.
  Future<void> tap(WidgetTester tester, Finder f) => run(() async {
        await tester.ensureVisible(f);
        await tester.tap(f);
        await tester.pumpAndSettle();
      });
}

/// The forgot-password 200 body (same for every email).
const forgotOk = '{"message":"If an account uses that email, we sent it a code.","expiresInSeconds":600}';
