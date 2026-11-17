import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/realtime_service.dart';
import '../core/theme_provider.dart';
import '../core/user_model.dart';
import '../screens/verify_email_screen.dart';

/// Profile's "SIGN-IN SECURITY" card: the opt-in two-step sign-in switch.
/// Turning it on needs a verified email; turning it off asks for the current
/// password (the server checks both).
class SecurityCard extends StatefulWidget {
  const SecurityCard({super.key});

  @override
  State<SecurityCard> createState() => _SecurityCardState();
}

class _SecurityCardState extends State<SecurityCard> {
  // Value shown while the turn-on request runs (null = show the user's value).
  bool? _pending;

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
    final user        = context.watch<AuthProvider>().user!;
    final isDark      = context.watch<ThemeProvider>().isDark;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted   : AppColors.textMutedLight;
    final verified = user.emailVerified;
    final value = _pending ?? user.loginTwoFactor;
    // Unverified but already on should not happen, but turning off stays possible.
    final enabled = _pending == null && (verified || user.loginTwoFactor);

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
          if (!verified)
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
