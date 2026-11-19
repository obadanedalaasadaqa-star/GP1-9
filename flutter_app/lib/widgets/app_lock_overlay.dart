import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/app_lock.dart';
import '../core/auth_provider.dart';
import '../core/design.dart';
import '../core/secure_store.dart';
import 'face_id_glyph.dart';
import 'notice_banner.dart';

/// Sits in `NexusApp.appBuilder`, above the Navigator. While the app is
/// re-locked it covers every route and sheet with [AppLockOverlay]; what is
/// underneath can't be read by VoiceOver or touched (also no back-swipe).
/// The wrappers are always in the tree and only flip, so no route is lost
/// (S7).
class AppLockGate extends StatelessWidget {
  final Widget child;
  const AppLockGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final locked = context.select<AuthProvider?, bool>((a) => a?.appLocked ?? false);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Stack(
      alignment: Alignment.topLeft,
      fit: StackFit.passthrough,
      children: [
        ExcludeSemantics(
          excluding: locked,
          child: AbsorbPointer(absorbing: locked, child: child),
        ),
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 150),
            child: locked
                ? const AppLockOverlay(key: ValueKey('app-lock-overlay'))
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

/// "Nexus is locked": opaque, with Face ID to unlock and the password as the
/// way out. Brings its own Material (it sits above every Scaffold). No
/// Tooltip or TextField here: there is no Overlay above the Navigator.
class AppLockOverlay extends StatefulWidget {
  const AppLockOverlay({super.key});

  @override
  State<AppLockOverlay> createState() => _AppLockOverlayState();
}

class _AppLockOverlayState extends State<AppLockOverlay> {
  bool _busy = false;
  ProtectedStatus? _status;
  bool _prompted = false;
  AppLifecycleListener? _resumeListener;

  @override
  void initState() {
    super.initState();
    // Prompt once by itself, after the first frame and once the app is
    // resumed (a prompt started earlier gets a system cancel).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _autoPrompt();
      } else {
        _resumeListener = AppLifecycleListener(onResume: _autoPrompt);
      }
    });
  }

  @override
  void dispose() {
    _resumeListener?.dispose();
    super.dispose();
  }

  void _autoPrompt() {
    _resumeListener?.dispose();
    _resumeListener = null;
    if (_prompted || !mounted) return;
    _unlock();
  }

  Future<void> _unlock() async {
    if (_busy) return;
    _prompted = true;
    final auth = context.read<AuthProvider>();
    final lock = context.read<AppLock?>();
    setState(() {
      _busy = true;
      _status = null;
    });
    final status = await auth.unlockApp();
    if (status == ProtectedStatus.success) lock?.hooks?.onUnlocked();
    if (!mounted) return;
    setState(() {
      _busy = false;
      // Cancelled or not matched: back to rest, no notice.
      _status = status == ProtectedStatus.cancelled || status == ProtectedStatus.failed ? null : status;
    });
  }

  void _password() {
    final hooks = context.read<AppLock?>()?.hooks;
    if (hooks != null) {
      hooks.onPasswordRequested();
    } else {
      context.read<AuthProvider>().logout();
    }
  }

  String? _notice(String name) => switch (_status) {
        ProtectedStatus.error => "$name didn't work this time. Try again, or sign in with your password.",
        ProtectedStatus.lockout => '$name is locked on this iPhone. Sign in with your password.',
        ProtectedStatus.invalidated =>
          '$name changed on this iPhone. Sign in with your password to turn it on again.',
        ProtectedStatus.notAvailable => '$name is off for Nexus in iPhone Settings. Sign in with your password.',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final auth = context.read<AuthProvider>();
    final name = auth.biometricName;
    final touch = name == 'Touch ID';
    final notice = _notice(name);
    // Lockout, faces changed or turned off: Face ID can't unlock, so the
    // password is the one action.
    final canUnlock = _status != ProtectedStatus.lockout &&
        _status != ProtectedStatus.invalidated &&
        _status != ProtectedStatus.notAvailable;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: nx.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Material(
        color: nx.bg,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  touch
                      ? ExcludeSemantics(child: Icon(Icons.fingerprint, size: 64, color: nx.text))
                      : FaceIdGlyph(size: 64, color: nx.text),
                  const SizedBox(height: 16),
                  Semantics(
                    header: true,
                    child: Text('Nexus is locked', style: NxType.display(36, color: nx.text)),
                  ),
                  const SizedBox(height: 6),
                  Text('Unlock to see your receipts.', style: NxType.body(15, color: nx.muted)),
                  const SizedBox(height: 22),
                  if (notice != null) ...[
                    NxNoticeBanner(notice),
                    const SizedBox(height: 16),
                  ],
                  if (canUnlock) ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        key: const ValueKey('app-lock-unlock'),
                        // Busy keeps the fill: taps are ignored, not disabled.
                        onPressed: _busy ? () {} : _unlock,
                        style: NxButtonStyle.solid(nx),
                        child: _busy
                            ? Semantics(
                                label: 'Unlock with $name',
                                value: 'Waiting for $name',
                                child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2.5, color: nx.onButton)),
                              )
                            : Text('Unlock with $name'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: TextButton(
                        key: const ValueKey('app-lock-password'),
                        style: TextButton.styleFrom(
                            minimumSize: const Size(44, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        onPressed: _password,
                        child: Text('Sign in with password',
                            style: NxType.body(14, color: nx.text, weight: FontWeight.w700)
                                .copyWith(decoration: TextDecoration.underline, decorationColor: nx.text)),
                      ),
                    ),
                  ] else
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        key: const ValueKey('app-lock-password'),
                        onPressed: _password,
                        style: NxButtonStyle.solid(nx),
                        child: const Text('Sign in with password'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
