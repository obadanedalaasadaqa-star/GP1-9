import 'package:flutter/material.dart';
import '../core/api_client.dart';
import '../core/design.dart';
import '../widgets/reset_form_bits.dart';
import 'reset_password_screen.dart';

/// Forgot password, step 1: ask for a reset code by email. The server
/// answers the same whether or not the email has an account, so step 2
/// never says "we sent a code to …".
class ForgotPasswordScreen extends StatefulWidget {
  /// What was typed on the sign-in form (may be empty).
  final String initialEmail;
  const ForgotPasswordScreen({super.key, this.initialEmail = ''});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.initialEmail);
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    // Close the keyboard first, so field errors and the banner are in view.
    FocusManager.instance.primaryFocus?.unfocus();
    if (_loading || !(_formKey.currentState?.validate() ?? false)) return;
    final email = _email.text.trim();
    setState(() { _loading = true; _error = null; });
    try {
      await ApiClient.forgotPassword(email);
      if (!mounted) return;
      setState(() => _loading = false);
      // Push, so Back returns here with the email kept.
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ResetPasswordScreen(email: email)));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    return ResetFrame(
      title: 'Reset your password',
      backTooltip: 'Back to sign in',
      intro: Text("Enter the email you signed up with. We'll send you a 6-digit code.",
        style: NxType.body(15, color: nx.muted, height: 1.45)),
      children: [
        const SizedBox(height: 22),
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ResetLabel('Email'),
              TextFormField(
                controller: _email,
                autofocus: widget.initialEmail.isEmpty,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                autocorrect: false,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _send(),
                style: NxType.body(15.5, color: nx.text),
                decoration: nxInput(nx, hint: 'you@example.com'),
                // Same loose rule as sign-in: older addresses can reset too.
                validator: (v) {
                  final t = v?.trim() ?? '';
                  if (t.isEmpty) return 'Email is required';
                  if (!t.contains('@')) return 'Enter a valid email';
                  return null;
                },
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          ResetErrorBanner(_error!),
        ],
        const SizedBox(height: 22),
        ResetButton(label: 'Send code', loading: _loading, onPressed: _send),
      ],
    );
  }
}
