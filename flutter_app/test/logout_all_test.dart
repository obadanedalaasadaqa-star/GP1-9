import 'dart:async';
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
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/auth_fixtures.dart';

// "Sign out of all devices" with the live connection wired like the shell
// (main.dart _MainShell: unauthorized and a 401 sync both log out with
// "Your session expired"). The host copies that wiring; the real shell is
// checked in the Simulator.

const _expired = 'Your session expired. Please log in again.';

class FakeSocket implements RealtimeSocket {
  FakeSocket(this.token);
  final String token;
  final _handlers = <String, void Function(dynamic)>{};
  int connectCalls = 0;
  bool disposed = false;
  @override
  bool connected = false;
  @override
  void connect() => connectCalls++;
  @override
  void disconnect() => connected = false;
  @override
  void dispose() => disposed = true;
  @override
  void on(String event, void Function(dynamic data) handler) => _handlers[event] = handler;
  void fire(String event, [dynamic data]) {
    if (event == 'connect') connected = true;
    if (event == 'disconnect') connected = false;
    _handlers[event]?.call(data);
  }
}

final sockets = <FakeSocket>[];

/// The shell's realtime wiring around ProfileScreen.
class _Host extends StatefulWidget {
  const _Host();
  @override
  State<_Host> createState() => HostState();
}

class HostState extends State<_Host> {
  late final RealtimeService realtime;
  final _subs = <StreamSubscription<void>>[];
  bool _expiring = false;

  @override
  void initState() {
    super.initState();
    realtime = RealtimeService(
      createSocket: (_, token) {
        final s = FakeSocket(token);
        sockets.add(s);
        return s;
      },
      resumeSyncFallback: const Duration(milliseconds: 10),
    );
    _subs.addAll([
      realtime.syncs.listen((_) => _onSync()),
      realtime.unauthorized.listen((_) => _onSessionExpired()),
    ]);
    realtime.syncOnFirstConnect = context.read<AuthProvider>().offline;
    realtime.start();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    realtime.dispose();
    super.dispose();
  }

  Future<void> _onSync() async {
    try {
      await context.read<AuthProvider>().refreshUser();
    } on ApiException catch (e) {
      if (e.statusCode == 401) _onSessionExpired();
    } catch (_) {}
  }

  void _onSessionExpired() {
    if (!mounted || _expiring) return;
    _expiring = true;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(_expired)));
    context.read<AuthProvider>().logout();
  }

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider<RealtimeService>.value(
        value: realtime,
        child: const ProfileScreen(),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  late Completer<http.Response> logoutReply;
  // Set once the server has ended every session: /user/me then gives 401.
  late bool revoked;
  late int logoutCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({'nexus_token': 't'});
    sockets.clear();
    revoked = false;
    logoutCalls = 0;
  });

  Future<http.Response> handler(http.Request req) async {
    if (req.url.path.endsWith('/user/logout-all')) {
      logoutCalls++;
      return logoutReply.future;
    }
    if (req.url.path.endsWith('/user/me')) {
      return revoked
          ? http.Response(jsonEncode({'error': 'Unauthorized'}), 401)
          : http.Response(jsonEncode(userJson()), 200);
    }
    return http.Response(jsonEncode({'message': 'ok'}), 200);
  }

  Future<void> run(Future<void> Function() body) =>
      http.runWithClient(body, () => MockClient(handler));

  Future<void> pumpApp(WidgetTester tester) async {
    // Made inside the test body (the fake-async zone), so completing it is
    // seen by tester.pump; one made in setUp would complete on the real loop.
    logoutReply = Completer<http.Response>();
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
            return auth.isLoggedIn ? const _Host() : const Scaffold(body: Text('LOGGED OUT'));
          }),
        ),
      ));
      await tester.pumpAndSettle();
    });
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(sockets, hasLength(1));
    sockets.single.fire('connect');
  }

  /// Taps the button and confirms; the request is then held.
  Future<void> startLogoutAll(WidgetTester tester) => run(() async {
        final button = find.byKey(const ValueKey('logout-all'));
        await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
        await tester.tap(button);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('logout-all-confirm')));
        await tester.pump();
        expect(logoutCalls, 1);
      });

  /// While the call is held, the server drops the old socket and the user
  /// leaves and comes back to the app (a resume sync).
  Future<void> serverDropsSessions(WidgetTester tester) => run(() async {
        revoked = true;
        final old = sockets.first;
        old.fire('disconnect', 'io server disconnect');
        old.fire('connect_error', {'message': 'unauthorized'});
        tester.state<HostState>(find.byType(_Host)).realtime
            .didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump(const Duration(milliseconds: 50));
      });

  testWidgets('1: success signs out with no "session expired", despite the dropped socket and a resume',
      (tester) async {
    await pumpApp(tester);
    await startLogoutAll(tester);
    expect(sockets.first.disposed, isTrue); // stopped before the call
    await serverDropsSessions(tester);
    expect(find.text('LOGGED OUT'), findsNothing); // nothing logged out early

    await run(() async {
      logoutReply.complete(http.Response(jsonEncode({'message': 'Signed out on all devices.'}), 200));
      await tester.pumpAndSettle();
    });
    expect(find.text('LOGGED OUT'), findsOneWidget);
    expect(find.text(_expired), findsNothing);
    expect(sockets.first.connectCalls, 1); // never retried with the old token
    expect(await ApiClient.getToken(), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('2: a 500 keeps the user signed in, shows the error and reconnects', (tester) async {
    await pumpApp(tester);
    await startLogoutAll(tester);
    await run(() async {
      logoutReply.complete(http.Response(jsonEncode({'error': 'Failed to sign out.'}), 500));
      await tester.pumpAndSettle();
    });
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(find.textContaining("Couldn't sign out of all devices. Failed to sign out."), findsOneWidget);
    expect(find.text(_expired), findsNothing);
    expect(sockets, hasLength(2)); // start() again
    expect(sockets.last.token, 't');
    final realtime = tester.state<HostState>(find.byType(_Host)).realtime;
    expect(realtime.syncOnFirstConnect, isTrue); // a receipt pushed meanwhile is reloaded
    expect(await ApiClient.getToken(), 't');
    expect(tester.takeException(), isNull);
  });

  testWidgets('3: a 401 (already revoked) signs out with no "session expired"', (tester) async {
    await pumpApp(tester);
    await startLogoutAll(tester);
    await serverDropsSessions(tester);
    await run(() async {
      logoutReply.complete(http.Response(jsonEncode({'error': 'Unauthorized'}), 401));
      await tester.pumpAndSettle();
    });
    expect(find.text('LOGGED OUT'), findsOneWidget);
    expect(find.text(_expired), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel sends nothing and keeps the connection', (tester) async {
    await pumpApp(tester);
    await run(() async {
      final button = find.byKey(const ValueKey('logout-all'));
      await tester.scrollUntilVisible(button, 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });
    expect(logoutCalls, 0);
    expect(sockets.single.disposed, isFalse);
    expect(find.byType(ProfileScreen), findsOneWidget);
  });
}
