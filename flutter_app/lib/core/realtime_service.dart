import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'api_client.dart';
import 'budget_models.dart';
import 'constants.dart';
import 'receipt_event.dart';
import 'token_store.dart';

/// The small part of a Socket.IO socket the service uses, so tests can pass a fake.
abstract class RealtimeSocket {
  void connect();
  void disconnect();
  void dispose();
  void on(String event, void Function(dynamic data) handler);
  bool get connected;
}

typedef RealtimeSocketFactory = RealtimeSocket Function(String url, String token);

/// True when a `connect_error` means the server refused our token.
/// The Dart client usually passes the raw packet data, a Map like
/// `{'message': 'unauthorized'}`, not an Error object.
@visibleForTesting
bool isUnauthorizedError(Object? data) {
  if (data == null) return false;
  if (data is Map) return data['message'] == 'unauthorized';
  if (data is String) return data == 'unauthorized';
  return data.toString().contains('unauthorized');
}

/// Live connection to the backend (Socket.IO). The server pushes
/// `receipt:new` when a store sends this user a receipt.
///
/// - [receipts]: every new receipt (the shell shows the "New receipt" sheet).
/// - [budgetAlerts]: a store receipt took a budget to 80% or 100%
///   (`budget:alert`, always after that receipt's `receipt:new`).
/// - [refreshTick]: +1 when lists should reload (new receipt, reconnect, resume).
/// - [syncs]: reconnect or resume, so the shell refreshes the user (points).
/// - [unauthorized]: the token was refused, so the shell logs the user out.
///
/// Nothing is lost while offline: receipts are saved before they are pushed,
/// and reconnect/resume reload the lists.
class RealtimeService extends ChangeNotifier with WidgetsBindingObserver {
  RealtimeService({
    RealtimeSocketFactory? createSocket,
    Duration resumeSyncFallback = const Duration(seconds: 5),
  })  : _createSocket = createSocket ?? debugSocketFactory ?? _defaultSocket,
        _resumeSyncFallback = resumeSyncFallback {
    WidgetsBinding.instance.addObserver(this);
  }

  /// Tests that build the whole app set this to a fake socket factory.
  @visibleForTesting
  static RealtimeSocketFactory? debugSocketFactory;

  final RealtimeSocketFactory _createSocket;
  // How long a resume waits for the reconnect before syncing over HTTP anyway
  // (e.g. a Wi-Fi that blocks WebSockets).
  final Duration _resumeSyncFallback;
  RealtimeSocket? _socket;

  final _receipts = StreamController<ReceiptEvent>.broadcast();
  final _budgetAlerts = StreamController<BudgetAlert>.broadcast();
  final _syncs = StreamController<void>.broadcast();
  final _unauthorized = StreamController<void>.broadcast();
  final _refreshTick = ValueNotifier<int>(0);

  bool _disposed = false;
  // The first connect only sets this; later connects are reconnects.
  bool _hadConnected = false;
  // One manual connect() after "io server disconnect" (token expiry), not a loop.
  bool _serverDisconnectRetried = false;
  // Token refused: stop reconnecting and tell the shell once.
  bool _refused = false;
  // Resume started a reconnect: its connect does the sync (only one sync).
  bool _syncOnConnect = false;
  Timer? _resumeFallback;
  // stop() was called: no socket and no resume sync until start().
  bool _stopped = false;

  Stream<ReceiptEvent> get receipts => _receipts.stream;
  Stream<BudgetAlert> get budgetAlerts => _budgetAlerts.stream;
  Stream<void> get syncs => _syncs.stream;
  Stream<void> get unauthorized => _unauthorized.stream;
  ValueListenable<int> get refreshTick => _refreshTick;
  bool get connected => _socket?.connected ?? false;

  /// Set before [start] when the app opened offline: the first connect then
  /// syncs too, so the lists and points replace the saved copies.
  bool syncOnFirstConnect = false;

  static RealtimeSocket _defaultSocket(String url, String token) => _IoRealtimeSocket(
        io.io(
          url,
          io.OptionBuilder()
              .setTransports(['websocket'])
              .setAuth({'token': token})
              .enableReconnection()
              .setReconnectionDelay(1000)
              .setReconnectionDelayMax(5000)
              .setReconnectionAttempts(double.infinity)
              // A fresh Manager every time, so a cached socket can never reuse
              // the previous account's token after logout/login.
              .enableForceNew()
              .disableAutoConnect()
              .build(),
        ),
      );

  /// Connect with the saved token. Does nothing if there is no token, or
  /// while the app is locked behind Face ID (S8): a `whileTokenChanges` that
  /// finishes during the lock must not reopen the socket.
  Future<void> start() async {
    if (TokenStore.isLocked) return;
    _stopped = false;
    final token = await ApiClient.getToken();
    if (_disposed || _stopped || token == null || TokenStore.isLocked) return;

    _socket?.dispose();
    _hadConnected = false;
    _serverDisconnectRetried = false;
    _refused = false;
    _cancelResumeSync();

    final socket = _createSocket(AppConfig.socketUrl, token);
    _socket = socket;
    socket.on('connect', (_) => _onConnect(socket));
    socket.on('disconnect', (reason) => _onDisconnect(socket, reason));
    socket.on('connect_error', (data) => _onConnectError(socket, data));
    socket.on('receipt:new', (data) => _onReceipt(socket, data));
    socket.on('budget:alert', (data) => _onBudgetAlert(socket, data));
    socket.connect();
  }

  /// Closes the live connection and keeps it closed (no reconnect, no resume
  /// sync) until start() is called again. Used before "sign out everywhere".
  void stop() {
    _stopped = true;
    _cancelResumeSync();
    final socket = _socket;
    // With no current socket, _isLive drops every later event of the old one
    // (the server's disconnect, a retry, an "unauthorized" refusal).
    _socket = null;
    socket?.dispose();
    if (!_disposed) notifyListeners();
  }

  /// Runs [action] with the live socket closed, then reconnects with the
  /// token saved now (a password/email/2FA change gives a new one).
  /// Without this, the server's disconnect of the old session would reach this
  /// socket, its retry with the old token would be refused, and the shell
  /// would log out the user who just made the change.
  Future<T> whileTokenChanges<T>(Future<T> Function() action) async {
    stop();
    try {
      return await action();
    } finally {
      // The first connect syncs, so nothing pushed during the gap is lost.
      syncOnFirstConnect = true;
      unawaited(start());
    }
  }

  // Events from an old (replaced or disposed) socket are ignored.
  bool _isLive(RealtimeSocket socket) => !_disposed && identical(socket, _socket);

  void _onConnect(RealtimeSocket socket) {
    if (!_isLive(socket)) return;
    _serverDisconnectRetried = false;
    final resumed = _syncOnConnect;
    _cancelResumeSync();
    if (_hadConnected || resumed || syncOnFirstConnect) _sync();
    syncOnFirstConnect = false;
    _hadConnected = true;
    notifyListeners();
  }

  void _onDisconnect(RealtimeSocket socket, dynamic reason) {
    if (!_isLive(socket)) return;
    notifyListeners();
    // Only the server's token-expiry timer sends this, and the client does not
    // reconnect by itself after it. Reconnect once: the handshake carries the
    // expired token, fails with "unauthorized", and the shell logs out.
    // Other reasons (transport close, ping timeout) use the built-in reconnection.
    if (reason == 'io server disconnect' && !_serverDisconnectRetried && !_refused) {
      _serverDisconnectRetried = true;
      socket.connect();
    }
  }

  void _onConnectError(RealtimeSocket socket, dynamic data) {
    if (!_isLive(socket) || _refused) return;
    if (!isUnauthorizedError(data)) return; // network errors: keep reconnecting
    _refused = true;
    socket.disconnect();
    _unauthorized.add(null);
  }

  void _onReceipt(RealtimeSocket socket, dynamic data) {
    if (!_isLive(socket)) return;
    try {
      // Normalise nested maps to Map<String, dynamic> before parsing.
      final json = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
      _receipts.add(ReceiptEvent.fromJson(json));
    } catch (e) {
      debugPrint('[realtime] bad receipt:new payload: $e');
    }
    _refreshTick.value++;
  }

  // No refreshTick here: the receipt that caused it already bumped it.
  void _onBudgetAlert(RealtimeSocket socket, dynamic data) {
    if (!_isLive(socket)) return;
    try {
      final json = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
      _budgetAlerts.add(BudgetAlert.fromJson(json));
    } catch (e) {
      debugPrint('[realtime] bad budget:alert payload: $e');
    }
  }

  void _sync() {
    _refreshTick.value++;
    _syncs.add(null);
  }

  void _cancelResumeSync() {
    _syncOnConnect = false;
    _resumeFallback?.cancel();
    _resumeFallback = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Stopped: a sync now could hit a revoked session and log out by mistake.
    if (_disposed || _stopped || state != AppLifecycleState.resumed) return;
    // Locked (AppLock ran first in this same callback): no sync, no reconnect.
    if (TokenStore.isLocked) return;
    // The user was away: reload, even before the first connect. If the socket
    // has to reconnect, its connect does the sync (so it runs once, not twice);
    // if the reconnect is slow or blocked, sync over HTTP after a short wait.
    final socket = _socket;
    if (socket != null && !socket.connected && !_refused) {
      _syncOnConnect = true;
      _resumeFallback?.cancel();
      _resumeFallback = Timer(_resumeSyncFallback, () {
        if (_disposed || !_syncOnConnect) return;
        _cancelResumeSync();
        _sync();
      });
      socket.connect();
      return;
    }
    _sync();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelResumeSync();
    WidgetsBinding.instance.removeObserver(this);
    _socket?.dispose();
    _socket = null;
    _receipts.close();
    _budgetAlerts.close();
    _syncs.close();
    _unauthorized.close();
    _refreshTick.dispose();
    super.dispose();
  }
}

/// [RealtimeSocket] backed by socket_io_client.
class _IoRealtimeSocket implements RealtimeSocket {
  _IoRealtimeSocket(this._socket);
  final io.Socket _socket;

  @override
  void connect() => _socket.connect();
  @override
  void disconnect() => _socket.disconnect();
  @override
  void dispose() => _socket.dispose();
  @override
  void on(String event, void Function(dynamic data) handler) => _socket.on(event, handler);
  @override
  bool get connected => _socket.connected;
}
