import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/budget_models.dart';
import 'package:nexus_app/core/realtime_service.dart';
import 'package:nexus_app/core/receipt_event.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake socket: records calls and lets the test fire server events.
class FakeSocket implements RealtimeSocket {
  FakeSocket(this.url, this.token);
  final String url;
  final String token;
  final _handlers = <String, void Function(dynamic)>{};

  int connectCalls = 0;
  int disconnectCalls = 0;
  bool disposed = false;
  @override
  bool connected = false;

  @override
  void connect() => connectCalls++;
  @override
  void disconnect() {
    disconnectCalls++;
    connected = false;
  }

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

final _receiptPayload = <String, dynamic>{
  'receipt': {
    'id': 'r1',
    'storeName': 'Carrefour',
    'category': 'Supermarket',
    'totalAmount': 12.5,
    'items': ['Milk x2'],
    'pointsEarned': 12,
    'createdAt': '2026-11-08T10:00:00.000Z',
  },
  'pointsEarned': 12,
  'loyaltyPoints': 140,
};

final _alertPayload = <String, dynamic>{
  'receiptId': 'r1',
  'category': 'Food',
  'level': 80,
  'percent': 85,
  'spent': 8.5,
  'limit': 10,
  'remaining': 1.5,
  'overBy': 0,
  'month': '2026-11',
  'monthLabel': 'November 2026',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<FakeSocket> sockets;
  late RealtimeService service;
  FakeSocket socket() => sockets.single;

  setUp(() {
    SharedPreferences.setMockInitialValues({'nexus_token': 'test-token'});
    sockets = [];
    service = RealtimeService(
      createSocket: (url, token) {
        final s = FakeSocket(url, token);
        sockets.add(s);
        return s;
      },
      resumeSyncFallback: const Duration(milliseconds: 50),
    );
  });

  tearDown(() {
    try {
      service.dispose();
    } catch (_) {/* already disposed in the test */}
  });

  // Let stream listeners run.
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('start() connects with the saved token to the socket URL', () async {
    await service.start();
    expect(socket().token, 'test-token');
    expect(socket().url, isNot(endsWith('/api')));
    expect(socket().connectCalls, 1);
  });

  test('no token: no socket is created', () async {
    SharedPreferences.setMockInitialValues({});
    await service.start();
    expect(sockets, isEmpty);
    expect(service.connected, isFalse);
  });

  test('receipt:new emits on receipts and adds 1 to refreshTick', () async {
    await service.start();
    final events = <ReceiptEvent>[];
    service.receipts.listen(events.add);
    socket().fire('connect');

    socket().fire('receipt:new', _receiptPayload);
    await flush();
    expect(events, hasLength(1));
    expect(events.single.receipt.storeName, 'Carrefour');
    expect(events.single.pointsEarned, 12);
    expect(events.single.loyaltyPoints, 140);
    expect(service.refreshTick.value, 1);
  });

  group('budget:alert', () {
    test('arrives on budgetAlerts and does not touch refreshTick', () async {
      await service.start();
      final alerts = <BudgetAlert>[];
      service.budgetAlerts.listen(alerts.add);
      socket().fire('connect');

      socket().fire('budget:alert', _alertPayload);
      await flush();
      expect(alerts, hasLength(1));
      expect(alerts.single.receiptId, 'r1');
      expect(alerts.single.level, 80);
      expect(alerts.single.title, 'Food budget: 85% used');
      expect(service.refreshTick.value, 0);
    });

    test('a bad payload is ignored', () async {
      await service.start();
      final alerts = <BudgetAlert>[];
      service.budgetAlerts.listen(alerts.add);
      socket().fire('budget:alert', {'category': 'Food'});
      socket().fire('budget:alert', 'nonsense');
      await flush();
      expect(alerts, isEmpty);
    });

    test('alerts from an old socket are ignored', () async {
      await service.start();
      final old = socket();
      final alerts = <BudgetAlert>[];
      service.budgetAlerts.listen(alerts.add);
      await service.start(); // replaces the socket
      old.fire('budget:alert', _alertPayload);
      await flush();
      expect(alerts, isEmpty);
      sockets.last.fire('budget:alert', _alertPayload);
      await flush();
      expect(alerts, hasLength(1));
    });
  });

  test('the first connect does not refresh; a reconnect refreshes and syncs', () async {
    await service.start();
    var syncs = 0;
    service.syncs.listen((_) => syncs++);

    socket().fire('connect');
    await flush();
    expect(service.connected, isTrue);
    expect(service.refreshTick.value, 0);
    expect(syncs, 0);

    socket().fire('disconnect', 'transport close');
    socket().fire('connect');
    await flush();
    expect(service.refreshTick.value, 1);
    expect(syncs, 1);
  });

  test('opened offline: the first connect syncs once, so saved copies get replaced', () async {
    service.syncOnFirstConnect = true;
    await service.start();
    var syncs = 0;
    service.syncs.listen((_) => syncs++);

    socket().fire('connect');
    await flush();
    expect(service.refreshTick.value, 1);
    expect(syncs, 1);
    expect(service.syncOnFirstConnect, isFalse);
  });

  test('resume while disconnected reconnects and syncs once, when it connects', () async {
    await service.start();
    socket().fire('connect');
    socket().fire('disconnect', 'transport close');
    var syncs = 0;
    service.syncs.listen((_) => syncs++);

    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await flush();
    expect(socket().connectCalls, 2);
    expect(syncs, 0); // waits for the reconnect

    socket().fire('connect');
    await flush();
    expect(service.refreshTick.value, 1);
    expect(syncs, 1);

    // The fallback timer was cancelled: no second sync later.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(syncs, 1);
  });

  test('resume before the first connect: that connect syncs', () async {
    await service.start();
    var syncs = 0;
    service.syncs.listen((_) => syncs++);

    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    socket().fire('connect');
    await flush();
    expect(socket().connectCalls, 2);
    expect(syncs, 1);
  });

  test('resume while the reconnect fails: syncs over HTTP after the fallback wait', () async {
    await service.start();
    var syncs = 0;
    service.syncs.listen((_) => syncs++);

    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await flush();
    expect(syncs, 0);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(service.refreshTick.value, 1);
    expect(syncs, 1);

    // A later connect is a plain first connect: no extra sync.
    socket().fire('connect');
    await flush();
    expect(syncs, 1);
  });

  test('resume while connected only refreshes and syncs', () async {
    await service.start();
    socket().fire('connect');
    var syncs = 0;
    service.syncs.listen((_) => syncs++);

    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await flush();
    expect(socket().connectCalls, 1);
    expect(service.refreshTick.value, 1);
    expect(syncs, 1);
  });

  test('connect_error unauthorized emits once and stops; other errors do nothing', () async {
    await service.start();
    var refused = 0;
    service.unauthorized.listen((_) => refused++);

    socket().fire('connect_error', {'message': 'timeout'});
    await flush();
    expect(refused, 0);
    expect(socket().disconnectCalls, 0);

    socket().fire('connect_error', {'message': 'unauthorized'});
    socket().fire('connect_error', {'message': 'unauthorized'});
    await flush();
    expect(refused, 1);
    expect(socket().disconnectCalls, 1);
  });

  test('a later start() with a new token resets the refusal', () async {
    await service.start();
    var refused = 0;
    service.unauthorized.listen((_) => refused++);
    socket().fire('connect_error', {'message': 'unauthorized'});

    SharedPreferences.setMockInitialValues({'nexus_token': 'new-token'});
    await service.start();
    expect(sockets.first.disposed, isTrue);
    expect(sockets.last.token, 'new-token');
    sockets.last.fire('connect_error', {'message': 'unauthorized'});
    await flush();
    expect(refused, 2);
  });

  group('isUnauthorizedError', () {
    test('true for the Map, String and Exception forms', () {
      expect(isUnauthorizedError({'message': 'unauthorized'}), isTrue);
      expect(isUnauthorizedError('unauthorized'), isTrue);
      expect(isUnauthorizedError(Exception('unauthorized')), isTrue);
    });

    test('false for other errors and null', () {
      expect(isUnauthorizedError({'message': 'timeout'}), isFalse);
      expect(isUnauthorizedError('xhr poll error'), isFalse);
      expect(isUnauthorizedError(null), isFalse);
    });
  });

  group('server disconnect (token expiry)', () {
    test('io server disconnect reconnects once by hand, then unauthorized emits', () async {
      await service.start();
      var refused = 0;
      service.unauthorized.listen((_) => refused++);
      socket().fire('connect');
      expect(socket().connectCalls, 1);

      socket().fire('disconnect', 'io server disconnect');
      expect(socket().connectCalls, 2);

      socket().fire('connect_error', {'message': 'unauthorized'});
      await flush();
      expect(refused, 1);
    });

    test('a second io server disconnect without a connect in between does not retry', () async {
      await service.start();
      socket().fire('connect');
      socket().fire('disconnect', 'io server disconnect');
      socket().fire('disconnect', 'io server disconnect');
      expect(socket().connectCalls, 2);

      // After a successful connect the retry is armed again.
      socket().fire('connect');
      socket().fire('disconnect', 'io server disconnect');
      expect(socket().connectCalls, 3);
    });

    test('transport close and io client disconnect do not call connect()', () async {
      await service.start();
      socket().fire('connect');
      socket().fire('disconnect', 'transport close');
      socket().fire('disconnect', 'ping timeout');
      socket().fire('disconnect', 'io client disconnect');
      expect(socket().connectCalls, 1);
    });
  });

  test('dispose disposes the socket and later events do nothing', () async {
    await service.start();
    final s = socket();
    s.fire('connect');
    service.dispose();
    expect(s.disposed, isTrue);

    s.fire('receipt:new', _receiptPayload);
    s.fire('disconnect', 'io server disconnect');
    s.fire('connect');
    expect(s.connectCalls, 1);
  });
}
