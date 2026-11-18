import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/validators.dart';
import '../widgets/code_boxes.dart';
import '../widgets/password_meter.dart';
import '../widgets/reset_form_bits.dart';
import 'verify_email_screen.dart';

/// Forgot password, step 2: the emailed code plus a new password. Success
/// signs in (Home + "Password updated ✓"), or opens "Confirm it's you" when
/// the account has two-step sign-in on. Nothing here is saved on the phone.
class ResetPasswordScreen extends StatefulWidget {
  /// The email typed on step 1 (trimmed).
  final String email;
  const ResetPasswordScreen({super.key, required this.email});

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  static const _resendSeconds = 60;

  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _codeFocus = FocusNode();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();

  bool _obscure = true;
  bool _loading = false;
  bool _sending = false;
  bool _codeError = false;
  String? _error;
  String? _info;
  int _cooldown = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startCooldown();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _codeFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _code.dispose();
    _codeFocus.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = _resendSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  void _onCodeChanged(String v) {
    if (_codeError || _error != null) setState(() { _codeError = false; _error = null; });
    // The 6th digit never submits (the password is needed too).
    if (v.length == CodeBoxes.length && _password.text.isEmpty) _passwordFocus.requestFocus();
  }

  Future<void> _resend() async {
    setState(() { _sending = true; _error = null; _info = null; });
    try {
      await ApiClient.forgotPassword(widget.email);
      if (!mounted) return;
      _code.clear();
      setState(() {
        _codeError = false;
        _info = 'If an account uses that email, a new code is on its way.';
      });
      _startCooldown();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _submit() async {
    // Close the keyboard first, so field errors and the banner are in view.
    FocusManager.instance.primaryFocus?.unfocus();
    if (_loading) return;
    final codeShort = _code.text.length != CodeBoxes.length;
    final passwordOk = _formKey.currentState?.validate() ?? false;
    if (codeShort) {
      setState(() { _codeError = true; _error = 'Enter the 6-digit code.'; _info = null; });
      return;
    }
    if (!passwordOk) return;

    setState(() { _loading = true; _error = null; _info = null; });
    // Captured before the await: this route is gone by the time they're used.
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final auth = context.read<AuthProvider>();
    try {
      final challenge = await auth.resetPassword(
          email: widget.email, code: _code.text, newPassword: _password.text);
      if (challenge != null) {
        // Two-step sign-in is on: the usual "Confirm it's you" screen takes
        // over; Back from it returns to sign in.
        nav.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => VerifyEmailScreen(login: challenge)),
          (r) => r.isFirst);
        return;
      }
      // Signed in: the app shell is already under these routes.
      nav.popUntil((r) => r.isFirst);
      messenger.showSnackBar(SnackBar(
        backgroundColor: AppColors.teal,
        content: Text('Password updated ✓',
          style: NxType.body(14, color: AppColors.ink, weight: FontWeight.w700)),
      ));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 400) {
        // Wrong or expired code: clear it, keep the password.
        _code.clear();
        setState(() { _error = e.message; _codeError = true; });
        _codeFocus.requestFocus();
      } else {
        // 429, no connection, server asleep: keep what was typed.
        setState(() => _error = e.message);
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final waiting = _cooldown > 0 || _sending;

    return ResetFrame(
      title: 'Check your email',
      intro: Text.rich(
        TextSpan(children: [
          const TextSpan(text: 'If an account uses '),
          TextSpan(text: widget.email,
            style: TextStyle(color: nx.text, fontWeight: FontWeight.w700)),
          const TextSpan(text: ', we sent it a 6-digit code. It works for 10 minutes.'),
        ]),
        style: NxType.body(15, color: nx.muted, height: 1.45),
      ),
      children: [
        const SizedBox(height: 22),
        CodeBoxes(
          controller: _code,
          focusNode: _codeFocus,
          hasError: _codeError,
          onChanged: _onCodeChanged,
        ),
        const SizedBox(height: 22),
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ResetLabel('New password'),
              TextFormField(
                controller: _password,
                focusNode: _passwordFocus,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                validator: validateNewPassword,
                style: NxType.body(15.5, color: nx.text),
                decoration: nxInput(nx,
                  hint: 'Choose a strong password',
                  suffix: IconButton(
                    tooltip: _obscure ? 'Show password' : 'Hide password',
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility,
                      color: nx.muted, size: 20),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  )),
              ),
              PasswordMeter(controller: _password, textMuted: nx.muted, track: nx.hairline),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          ResetErrorBanner(_error!),
        ] else if (_info != null) ...[
          const SizedBox(height: 16),
          Text(_info!, style: NxType.body(14, color: nx.text, weight: FontWeight.w700)),
        ],
        const SizedBox(height: 22),
        ResetButton(label: 'Set new password', loading: _loading, onPressed: _submit),
        const SizedBox(height: 12),
        Center(
          child: Column(
            children: [
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                onPressed: waiting ? null : _resend,
                child: Text(
                  _sending
                      ? 'Sending…'
                      : _cooldown > 0 ? 'Resend code in ${_cooldown}s' : 'Resend code',
                  style: NxType.mono(13.5,
                    color: waiting ? nx.muted : nx.text,
                    weight: waiting ? FontWeight.w400 : FontWeight.w500)),
              ),
              const SizedBox(height: 2),
              Text("Can't find it? Check your spam folder.",
                textAlign: TextAlign.center,
                style: NxType.body(12.5, color: nx.muted)),
            ],
          ),
        ),
      ],
    );
  }
}
