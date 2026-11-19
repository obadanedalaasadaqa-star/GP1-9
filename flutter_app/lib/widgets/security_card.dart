import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/biometric_service.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/realtime_service.dart';
import '../core/theme_provider.dart';
import '../core/user_model.dart';
import '../screens/forgot_password_screen.dart';
import '../screens/verify_email_screen.dart';

/// Profile's "SIGN-IN SECURITY" card: the opt-in two-step sign-in switch.
/// Turning it on needs a verified email; turning it off asks for the current
/// password (the server checks both). On iOS, a second row turns Face ID on
/// and off (both ask for Face ID first).
class SecurityCard extends StatefulWidget {
  const SecurityCard({super.key});

  @override
  State<SecurityCard> createState() => _SecurityCardState();
}

class _SecurityCardState extends State<SecurityCard> {
  // Value shown while the turn-on request runs (null = show the user's value).
  bool? _pending;
  // Value shown while the Face ID prompt is up (null = the real state).
  bool? _bioPending;

  @override
  void initState() {
    super.initState();
    // Face ID may have been set up, locked or turned off since the last check.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && isIosPlatform) context.read<AuthProvider>().refreshBiometricAvailability();
    });
  }

  Future<void> _toggleBiometrics(bool on) async {
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final name = auth.biometricName;
    setState(() => _bioPending = on);
    final outcome = on ? await auth.enableBiometrics() : await auth.disableBiometrics();
    if (mounted) setState(() => _bioPending = null);
    final state = on ? 'off' : 'on'; // where it stays when it didn't work
    final String text;
    if (outcome == BioOutcome.success) {
      text = on ? '$name is on. Next time, just look at your iPhone.' : '$name is off.';
    } else if (outcome == BioOutcome.lockout) {
      text = '$name is locked, so it\'s still $state. Unlock your iPhone, then try again.';
    } else {
      text = "$name didn't go through, so it's still $state.";
    }
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  /// The line under "Face ID" (design 3.2).
  static String _bioLine(BiometricAvailability a, bool on) {
    final name = a.name;
    if (a.usable) {
      return on ? 'Nexus opens with $name on this iPhone' : 'Open Nexus with $name instead of your password';
    }
    return switch (a.reason) {
      BiometricReason.notEnrolled || BiometricReason.noPasscode => 'Set up $name in iPhone Settings to use this',
      BiometricReason.turnedOffForApp => 'Allow $name for Nexus in iPhone Settings to use this',
      BiometricReason.lockout => '$name is locked. Unlock your iPhone, then try again',
      BiometricReason.unknown => "Couldn't check $name just now. Reopen Nexus to try again",
      _ => 'Not available on this iPhone',
    };
  }

  Widget _biometricRow(AuthProvider auth, Color textPrimary, Color textMuted) {
    final a = auth.biometricAvailability;
    final on = auth.biometricsOn;
    return MergeSemantics(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.name, style: NxType.body(15, weight: FontWeight.w700, color: textPrimary)),
                const SizedBox(height: 2),
                Text(_bioLine(a, on), style: NxType.body(12.5, color: textMuted)),
              ],
            ),
          ),
          Switch(
            key: const ValueKey('switch-face-id'),
            // Always the real state; being disabled never moves it.
            value: _bioPending ?? on,
            onChanged: _bioPending == null && a.usable ? _toggleBiometrics : null,
          ),
        ],
      ),
    );
  }

  Future<void> _turnOn() async {
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    // Turning it on ends every other session and sends this device a new
    // token; the live connection reconnects with it.
    final realtime = context.read<RealtimeService?>();
    setState(() => _pending = true);
    try {
      Future<User> turnOn() => ApiClient.setLoginTwoFactor(true);
      auth.updateUser(await (realtime == null ? turnOn() : realtime.whileTokenChanges(turnOn)));
      messenger.showSnackBar(const SnackBar(
        content: Text("Two-step sign-in is on. Next time you log in, we'll email you a code.")));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't turn on two-step sign-in. $e")));
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  Future<void> _turnOff() async {
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final updated = await showDialog<User>(
      context: context,
      builder: (_) => const _TurnOffDialog(),
    );
    if (updated == null) return; // cancelled: nothing sent, the switch stays on
    auth.updateUser(updated);
    messenger.showSnackBar(const SnackBar(content: Text('Two-step sign-in is off.')));
  }

  @override
  Widget build(BuildContext context) {
    final auth        = context.watch<AuthProvider>();
    final user        = auth.user!;
    final isDark      = context.watch<ThemeProvider>().isDark;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted   : AppColors.textMutedLight;
    final verified = user.emailVerified;
    // An account made with Google has no password: it could never turn this
    // off again, so it sets a password first (the server says the same).
    final noPassword = !user.passwordSet;
    final value = _pending ?? user.loginTwoFactor;
    // Unverified but already on should not happen, but turning off stays possible.
    final enabled = _pending == null && (user.loginTwoFactor || (verified && !noPassword));

    return NxProfileCard(
        children: [
          Text('SIGN-IN SECURITY', style: NxType.label(textMuted)),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Two-step sign-in', style: NxType.body(15, weight: FontWeight.w700, color: textPrimary)),
                      const SizedBox(height: 2),
                      Text(value
                          ? 'A code is emailed to you at every password login'
                          : 'Ask for an email code when I log in with my password',
                        style: NxType.body(12.5, color: textMuted)),
                    ],
                  ),
                ),
                Switch(
                  key: const ValueKey('switch-2fa'),
                  value: value,
                  onChanged: enabled ? (v) => v ? _turnOn() : _turnOff() : null,
                ),
              ],
            ),
          ),
          // Both missing: only the password line, it's the first step.
          if (noPassword && !user.loginTwoFactor)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Set a password to turn this on',
                      style: NxType.body(12.5, color: textMuted)),
                  ),
                  TextButton(
                    key: const ValueKey('security-set-password'),
                    style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ForgotPasswordScreen(initialEmail: user.email, setPassword: true))),
                    child: Text('Set a password',
                      style: NxType.body(13.5, weight: FontWeight.w700, color: Nx.of(context).accent)),
                  ),
                ],
              ),
            )
          else if (!verified)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Verify your email to turn this on',
                      style: NxType.body(12.5, color: textMuted)),
                  ),
                  TextButton(
                    onPressed: () => VerifyEmailScreen.open(context),
                    child: Text('Verify', style: NxType.body(13.5, weight: FontWeight.w700, color: Nx.of(context).accent)),
                  ),
                ],
              ),
            ),
          if (isIosPlatform) ...[
            const SizedBox(height: 12),
            const NxRowDivider(),
            const SizedBox(height: 12),
            _biometricRow(auth, textPrimary, textMuted),
          ],
        ],
    );
  }
}

/// Asks for the current password and turns two-step sign-in off. Pops with the
/// updated user; a wrong or missing password shows the server text and stays open.
class _TurnOffDialog extends StatefulWidget {
  const _TurnOffDialog();

  @override
  State<_TurnOffDialog> createState() => _TurnOffDialogState();
}

class _TurnOffDialogState extends State<_TurnOffDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final navigator = Navigator.of(context);
    setState(() { _busy = true; _error = null; });
    try {
      final user = await ApiClient.setLoginTwoFactor(false, currentPassword: _password.text);
      navigator.pop(user);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Turn off two-step sign-in?'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('2fa-password'),
          controller: _password,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Current password'),
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: NxType.body(13, color: AppColors.coral)),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel')),
      TextButton(
        key: const ValueKey('2fa-turn-off'),
        onPressed: _busy ? null : _submit,
        child: const Text('Turn off', style: TextStyle(color: AppColors.coral))),
    ],
  );
}
