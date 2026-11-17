import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/money.dart';
import '../core/realtime_service.dart';
import '../core/theme_provider.dart';
import '../core/user_model.dart';
import '../core/validators.dart';
import '../widgets/budgets_alerts_card.dart';
import '../widgets/password_meter.dart';
import '../widgets/security_card.dart';
import 'verify_email_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _firstNameCtrl;
  late TextEditingController _lastNameCtrl;
  late TextEditingController _emailCtrl;
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  bool _obscure = true;
  String? _status;
  String _msg = '';

  // Change password card
  final _pwFormKey     = GlobalKey<FormState>();
  final _currentPwCtrl = TextEditingController();
  final _newPwCtrl     = TextEditingController();
  final _confirmPwCtrl = TextEditingController();
  bool _pwLoading = false;
  bool _pwObscure = true;
  String? _pwStatus;
  String _pwMsg = '';

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

  // Ends every session on the server, this one too, then logs out here. The
  // live connection is stopped first, so the server dropping it can't show
  // "session expired". No context is used after the first await.
  Future<void> _logoutAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out of all devices?'),
        content: const Text('Sign out on every device, including this one?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('logout-all-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign out', style: TextStyle(color: AppColors.alert))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final auth = context.read<AuthProvider>();
    final realtime = context.read<RealtimeService?>();
    final messenger = ScaffoldMessenger.of(context);

    realtime?.stop();
    try {
      await ApiClient.logoutAll();
      await auth.logout();
    } on ApiException catch (e) {
      // 401: the session is already gone (e.g. the answer was lost after the
      // server ended it), so just log out here.
      if (e.statusCode == 401) {
        await auth.logout();
        return;
      }
      _logoutAllFailed(realtime, messenger, e.toString());
    } catch (e) {
      _logoutAllFailed(realtime, messenger, e.toString());
    }
  }

  // Still signed in: reconnect (syncing what was pushed meanwhile) and say why.
  void _logoutAllFailed(RealtimeService? realtime, ScaffoldMessengerState messenger, String error) {
    if (realtime != null) {
      realtime.syncOnFirstConnect = true;
      realtime.start();
    }
    if (mounted) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't sign out of all devices. $error")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final user   = context.watch<AuthProvider>().user!;
    final isDark = context.watch<ThemeProvider>().isDark;
    final theme  = context.watch<ThemeProvider>();

    final bg      = isDark ? AppColors.bg      : AppColors.bgLight;
    final surface = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border  = isDark ? AppColors.border  : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted   : AppColors.textMutedLight;
    final textDim     = isDark ? AppColors.textDim     : AppColors.textDimLight;
    final nx          = Nx.of(context);

    final initials = user.name.isNotEmpty
        ? user.name.trim().split(' ').map((w) => w[0].toUpperCase()).take(2).join()
        : '?';

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Profile',
                style: NxType.display(40, color: textPrimary, letterSpacing: -1.8)),
              const SizedBox(height: 18),

              // Member card
              Padding(
                padding: const EdgeInsets.only(right: 6, bottom: 6),
                child: NxCard(
                  tilt: 2,
                  color: AppColors.cobalt,
                  borderColor: AppColors.ink,
                  shadowColor: isDark ? AppColors.lime : AppColors.ink,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('NEXUS', style: NxType.display(18,
                            color: Colors.white, letterSpacing: 1)),
                          const Spacer(),
                          Text('MEMBER SINCE ${_formatDate(user.createdAt).toUpperCase()}',
                            style: NxType.mono(12, color: AppColors.cobaltSoft,
                              letterSpacing: 1)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Container(
                            width: 56, height: 56,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.lime,
                              shape: BoxShape.circle,
                              border: Border.all(color: AppColors.ink, width: 2)),
                            child: Text(initials,
                              style: NxType.display(19, color: AppColors.ink,
                                letterSpacing: 0)),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_titleCase(user.name),
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: NxType.display(22, color: Colors.white)),
                                Text(user.email,
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: NxType.body(13.5, color: AppColors.cobaltSoft)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      DashedRule(color: Colors.white.withValues(alpha: 0.8),
                        thickness: 1.5),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: Text(user.serialNumber,
                              style: NxType.mono(13, color: Colors.white,
                                weight: FontWeight.w500)),
                          ),
                          Text('${formatPoints(user.loyaltyPoints)} pts',
                            style: NxType.display(20, color: AppColors.lime)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),

              // Appearance card (theme toggle)
              _card(
                surface: surface, border: border,
                children: [
                  _sectionTitle('APPEARANCE', textMuted),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Dark mode',
                            style: NxType.body(15, weight: FontWeight.w700,
                              color: textPrimary)),
                          const SizedBox(height: 2),
                          Text(isDark ? 'On, ink theme' : 'Off, paper theme',
                            style: NxType.body(12.5, color: textMuted)),
                        ],
                      ),
                      Switch(
                        value: isDark,
                        onChanged: (_) => theme.toggle(),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Budgets & alerts card (budgets link + email switches)
              const BudgetsAlertsCard(),
              const SizedBox(height: 14),

              // Sign-in security card (two-step sign-in switch)
              const SecurityCard(),
              const SizedBox(height: 14),

              // Account info card
              _card(
                surface: surface, border: border,
                children: [
                  _sectionTitle('ACCOUNT', textMuted),
                  // Email, serial, points and member-since are on the member
                  // card above; only the verification status lives here.
                  _emailStatusRow(user.emailVerified, textMuted: textMuted,
                    last: true),
                ],
              ),
              const SizedBox(height: 14),

              // Edit name card
              _card(
                surface: surface, border: border,
                children: [
                  _sectionTitle('EDIT PROFILE', textMuted),
                  Form(
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
                ],
              ),
              const SizedBox(height: 14),

              // Change password card
              _card(
                surface: surface, border: border,
                children: [
                  _sectionTitle('CHANGE PASSWORD', textMuted),
                  Form(
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
                ],
              ),
              const SizedBox(height: 16),

              // Sign out
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => context.read<AuthProvider>().logout(),
                  style: NxButtonStyle.outline(nx, color: nx.danger),
                  child: const Text('Sign Out'),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  key: const ValueKey('logout-all'),
                  onPressed: _logoutAll,
                  child: Text('Sign out of all devices',
                    style: NxType.body(13.5, weight: FontWeight.w700,
                      color: nx.danger)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }

  Widget _card({
    required Color surface,
    required Color border,
    required List<Widget> children,
  }) => NxProfileCard(children: children);

  Widget _emailStatusRow(bool verified, {required Color textMuted, bool last = false}) => Column(children: [
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Email status', style: NxType.body(14.5,
            weight: FontWeight.w700, color: Nx.of(context).text)),
          verified
              ? _chip(Icons.check_rounded, 'Verified', AppColors.teal)
              : GestureDetector(
                  onTap: () => VerifyEmailScreen.open(context),
                  child: _chip(Icons.error_outline_rounded,
                    'Not verified · Verify', AppColors.amber),
                ),
        ],
      ),
    ),
    if (!last) const NxRowDivider(),
  ]);

  Widget _chip(IconData icon, String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: AppColors.ink),
      const SizedBox(width: 5),
      Text(label, style: NxType.body(12.5,
        weight: FontWeight.w700, color: AppColors.ink)),
    ]),
  );

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

  Widget _sectionTitle(String t, Color textMuted) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(t, style: NxType.label(textMuted)),
  );

  /// "obada sadaqa" → "Obada Sadaqa" for display (the stored name is unchanged).
  static String _titleCase(String s) => s
      .split(' ')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');

  String _formatDate(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun',
                'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${m[d.month - 1]} ${d.year}';
  }
}
