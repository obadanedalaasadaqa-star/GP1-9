import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/realtime_service.dart';
import '../core/user_model.dart';
import '../core/validators.dart';
import '../widgets/password_meter.dart';
import 'verify_email_screen.dart';

/// Pushes [screen] with the caller's RealtimeService (a pushed route does
/// not see the shell's providers; the email and password changes need it to
/// keep the live connection on the rotated token).
Future<void> _push(BuildContext context, Widget screen) {
  final realtime = context.read<RealtimeService?>();
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => realtime == null
        ? screen
        : ChangeNotifierProvider<RealtimeService>.value(value: realtime, child: screen),
  ));
}

/// Shared frame: back button, big title, the form in a card.
class _EditFrame extends StatelessWidget {
  final String title;
  final Widget child;
  const _EditFrame({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: nx.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: nx.bg,
        body: SafeArea(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const NxBackButton(),
                const SizedBox(height: 18),
                Text(title,
                  style: NxType.display(34, color: nx.text, letterSpacing: -1.4,
                    height: 1.05)),
                const SizedBox(height: 18),
                NxProfileCard(children: [child]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared pieces of the two forms.
mixin _FormBits<T extends StatefulWidget> on State<T> {
  Widget _statusBanner(String status, String msg) {
    final color = status == 'success' ? AppColors.teal : AppColors.coral;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.ink, width: 2),
      ),
      child: Text(msg, style: NxType.body(13.5,
        weight: FontWeight.w600, color: AppColors.ink)),
    );
  }

  Widget _gradientButton(
    String label, {
    required bool loading,
    required VoidCallback onPressed,
  }) {
    final nx = Nx.of(context);
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: NxButtonStyle.solid(nx, height: 50),
        child: loading
            ? SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5, color: nx.onButton))
            : Text(label),
      ),
    );
  }

  Widget _fieldLabel(String text, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text.toUpperCase(), style: NxType.label(Nx.of(context).muted)),
  );

  Widget _input(
    TextEditingController ctrl,
    String hint, {
    required bool isDark,
    required Color border,
    required Color textPrimary,
    required Color textMuted,
    TextInputType keyboard = TextInputType.text,
    bool obscure = false,
    Widget? suffix,
    String? Function(String?)? validator,
  }) =>
    TextFormField(
      controller: ctrl,
      obscureText: obscure,
      keyboardType: keyboard,
      validator: validator,
      style: NxType.body(15.5, color: textPrimary),
      decoration: nxInput(Nx.of(context), hint: hint, suffix: suffix),
    );

}

// ── Edit name and email ─────────────────────────────────────────────────────

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  static Future<void> open(BuildContext context) =>
      _push(context, const EditProfileScreen());

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen>
    with _FormBits<EditProfileScreen> {
  late TextEditingController _firstNameCtrl;
  late TextEditingController _lastNameCtrl;
  late TextEditingController _emailCtrl;
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  bool _obscure = true;
  String? _status;
  String _msg = '';

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().user;
    _firstNameCtrl = TextEditingController(text: user?.firstName ?? '');
    _lastNameCtrl  = TextEditingController(text: user?.lastName ?? '');
    _emailCtrl     = TextEditingController(text: user?.email ?? '');
    // Show/hide the password field as the email is edited
    _emailCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  // Compared like the server: case and surrounding spaces are not a change.
  bool get _emailChanged =>
      _emailCtrl.text.trim().toLowerCase() !=
      context.read<AuthProvider>().user?.email.trim().toLowerCase();

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    final first = _firstNameCtrl.text.trim();
    final last  = _lastNameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final emailChanged = _emailChanged;
    if (first == user?.firstName && last == user?.lastName && !emailChanged) {
      return;
    }

    // An email change ends every other session and sends a new token.
    final realtime = emailChanged ? context.read<RealtimeService?>() : null;
    setState(() { _loading = true; _status = null; });
    try {
      Future<User> update() => ApiClient.updateProfile(
        firstName: first, lastName: last,
        email: email,
        currentPassword: emailChanged ? _passwordCtrl.text : null);
      final updated = await (realtime == null ? update() : realtime.whileTokenChanges(update));
      // An email change turns two-step sign-in off on the server.
      final lostTwoFactor = (user?.loginTwoFactor ?? false) && !updated.loginTwoFactor;
      auth.updateUser(updated);
      _passwordCtrl.clear();
      setState(() {
        _status = 'success';
        _msg = lostTwoFactor
            ? 'Profile updated. Two-step sign-in was turned off; verify your new email to turn it on again.'
            : 'Profile updated.';
      });
      // A new email must be verified — the backend has already sent the code
      if (emailChanged && !updated.emailVerified && mounted) {
        VerifyEmailScreen.open(context, sendOnOpen: false);
      }
    } catch (e) {
      setState(() { _status = 'error'; _msg = e.toString(); });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final isDark = nx.dark;
    final border = nx.line;
    final textPrimary = nx.text;
    final textMuted = nx.muted;
    final textDim = nx.muted;
    return _EditFrame(
      title: 'Edit name and email',
      child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _fieldLabel('First Name', textDim),
                                _input(_firstNameCtrl, 'First',
                                  isDark: isDark, border: border,
                                  textPrimary: textPrimary, textMuted: textMuted,
                                  validator: (v) => validateName(v, 'First name')),
                              ],
                            )),
                            const SizedBox(width: 12),
                            Expanded(child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _fieldLabel('Last Name', textDim),
                                _input(_lastNameCtrl, 'Last',
                                  isDark: isDark, border: border,
                                  textPrimary: textPrimary, textMuted: textMuted,
                                  validator: (v) => validateName(v, 'Last name')),
                              ],
                            )),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _fieldLabel('Email', textDim),
                        _input(_emailCtrl, 'you@example.com',
                          keyboard: TextInputType.emailAddress,
                          isDark: isDark, border: border,
                          textPrimary: textPrimary, textMuted: textMuted,
                          // The strict check only for a new address, so an older
                          // account's stored email never blocks a name edit.
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return 'Email is required';
                            if (_emailChanged) return validateEmail(v);
                            return null;
                          }),
                        if (_emailChanged) ...[
                          const SizedBox(height: 14),
                          _fieldLabel('Current Password', textDim),
                          _input(_passwordCtrl, 'Required to change your email',
                            obscure: _obscure,
                            isDark: isDark, border: border,
                            textPrimary: textPrimary, textMuted: textMuted,
                            suffix: IconButton(
                              icon: Icon(
                                _obscure ? Icons.visibility_off : Icons.visibility,
                                color: textMuted, size: 18),
                              onPressed: () => setState(() => _obscure = !_obscure),
                            ),
                            validator: (v) => (v == null || v.isEmpty)
                                ? 'Enter your current password' : null),
                        ],

                        if (_status != null) ...[
                          const SizedBox(height: 12),
                          _statusBanner(_status!, _msg),
                        ],

                        const SizedBox(height: 16),
                        _gradientButton('Save Changes',
                          loading: _loading, onPressed: _save),
                      ],
                    ),
                  ),
    );
  }
}

// ── Change password ─────────────────────────────────────────────────────────

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  static Future<void> open(BuildContext context) =>
      _push(context, const ChangePasswordScreen());

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen>
    with _FormBits<ChangePasswordScreen> {
  final _pwFormKey     = GlobalKey<FormState>();
  final _currentPwCtrl = TextEditingController();
  final _newPwCtrl     = TextEditingController();
  final _confirmPwCtrl = TextEditingController();
  bool _pwLoading = false;
  bool _pwObscure = true;
  String? _pwStatus;
  String _pwMsg = '';

  @override
  void dispose() {
    _currentPwCtrl.dispose();
    _newPwCtrl.dispose();
    _confirmPwCtrl.dispose();
    super.dispose();
  }

  Future<void> _changePassword() async {
    if (!(_pwFormKey.currentState?.validate() ?? false)) return;
    // The server ends every other session and sends this device a new token;
    // the live connection reconnects with it (no "session expired").
    final realtime = context.read<RealtimeService?>();
    setState(() { _pwLoading = true; _pwStatus = null; });
    try {
      Future<void> change() => ApiClient.changePassword(
        currentPassword: _currentPwCtrl.text,
        newPassword: _newPwCtrl.text);
      await (realtime == null ? change() : realtime.whileTokenChanges(change));
      if (!mounted) return;
      _currentPwCtrl.clear();
      _newPwCtrl.clear();
      _confirmPwCtrl.clear();
      setState(() { _pwStatus = 'success'; _pwMsg = 'Password updated.'; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _pwStatus = 'error'; _pwMsg = e.toString(); });
    } finally {
      if (mounted) setState(() => _pwLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final isDark = nx.dark;
    final border = nx.line;
    final textPrimary = nx.text;
    final textMuted = nx.muted;
    final textDim = nx.muted;
    return _EditFrame(
      title: 'Change password',
      child: Form(
                    key: _pwFormKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _fieldLabel('Current Password', textDim),
                        _input(_currentPwCtrl, '••••••••',
                          obscure: _pwObscure,
                          isDark: isDark, border: border,
                          textPrimary: textPrimary, textMuted: textMuted,
                          suffix: IconButton(
                            icon: Icon(
                              _pwObscure ? Icons.visibility_off : Icons.visibility,
                              color: textMuted, size: 18),
                            onPressed: () => setState(() => _pwObscure = !_pwObscure),
                          ),
                          validator: (v) => (v == null || v.isEmpty)
                              ? 'Enter your current password' : null),
                        const SizedBox(height: 14),
                        _fieldLabel('New Password', textDim),
                        _input(_newPwCtrl, 'Choose a strong password',
                          obscure: _pwObscure,
                          isDark: isDark, border: border,
                          textPrimary: textPrimary, textMuted: textMuted,
                          validator: (v) {
                            if (v != null && v.isNotEmpty && v == _currentPwCtrl.text) {
                              return 'Must be different from the current password';
                            }
                            return validateNewPassword(v);
                          }),
                        PasswordMeter(
                          controller: _newPwCtrl,
                          textMuted: textMuted,
                          track: border),
                        const SizedBox(height: 14),
                        _fieldLabel('Confirm New Password', textDim),
                        _input(_confirmPwCtrl, 'Repeat the new password',
                          obscure: _pwObscure,
                          isDark: isDark, border: border,
                          textPrimary: textPrimary, textMuted: textMuted,
                          validator: (v) => v != _newPwCtrl.text
                              ? 'Passwords do not match' : null),

                        if (_pwStatus != null) ...[
                          const SizedBox(height: 12),
                          _statusBanner(_pwStatus!, _pwMsg),
                        ],

                        const SizedBox(height: 16),
                        _gradientButton('Update Password',
                          loading: _pwLoading, onPressed: _changePassword),
                      ],
                    ),
                  ),
    );
  }
}
