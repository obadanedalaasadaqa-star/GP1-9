import 'package:flutter/widgets.dart';
import 'auth_provider.dart';

/// What the tab shell does when the app locks and unlocks (registered by the
/// shell while it is mounted).
class LockHooks {
  /// Close the live socket (synchronously, in the same `resumed` callback, S8).
  final VoidCallback onLock;

  /// Reconnect and refresh once the overlay is gone.
  final VoidCallback onUnlocked;

  /// "Sign in with password" on the overlay: close sheets, pop to the first
  /// route, sign out (S12).
  final VoidCallback onPasswordRequested;

  const LockHooks({required this.onLock, required this.onUnlocked, required this.onPasswordRequested});
}

/// Re-locks the app behind Face ID after [lockAfter] in the background
/// (Q2: 5 minutes). Registered in `main()` before `runApp`, so it handles
/// `resumed` before any [RealtimeService] does.
///
/// Time away is measured with the wall clock and a monotonic stopwatch; it
/// locks when either says [lockAfter] or more, or the wall clock went
/// backwards (S18, S24). `inactive` (the Face ID sheet, Control Centre) is
/// never time away.
class AppLock with WidgetsBindingObserver {
  AppLock({
    required this.auth,
    DateTime Function()? now,
    Stopwatch Function()? newStopwatch,
    this.lockAfter = const Duration(minutes: 5),
  })  : _now = now ?? DateTime.now,
        _newStopwatch = newStopwatch ?? Stopwatch.new;

  /// The one [AuthProvider] the app provides (S23).
  final AuthProvider auth;
  final DateTime Function() _now;
  final Stopwatch Function() _newStopwatch;
  final Duration lockAfter;

  LockHooks? hooks;

  DateTime? _awayAt;
  Stopwatch? _away;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        if (_awayAt == null) {
          _awayAt = _now();
          _away = _newStopwatch()..start();
        }
      case AppLifecycleState.resumed:
        _onResumed();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _onResumed() {
    final awayAt = _awayAt;
    final watch = _away;
    _awayAt = null;
    _away = null;
    watch?.stop();
    if (awayAt == null || !auth.isLoggedIn || auth.locked) return;
    if (auth.biometricsOn && _longEnough(awayAt, watch)) {
      // All synchronous, in this callback: the socket's own handler runs
      // next and must already see "locked".
      hooks?.onLock();
      auth.lockApp();
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    // Face ID may have been turned off for Nexus, or locked out, meanwhile.
    auth.refreshBiometricAvailability();
  }

  bool _longEnough(DateTime awayAt, Stopwatch? watch) {
    final wall = _now().difference(awayAt);
    return wall.isNegative || wall >= lockAfter || (watch != null && watch.elapsed >= lockAfter);
  }
}
