import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/theme_provider.dart';
import '../core/validators.dart';
import '../widgets/budgets_alerts_card.dart';
import '../widgets/password_meter.dart';
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
    setState(() { _pwLoading = true; _pwStatus = null; });
    try {
      await ApiClient.changePassword(
        currentPassword: _currentPwCtrl.text,
        newPassword: _newPwCtrl.text);
      _currentPwCtrl.clear();
      _newPwCtrl.clear();
      _confirmPwCtrl.clear();
      setState(() { _pwStatus = 'success'; _pwMsg = 'Password updated.'; });
    } catch (e) {
      setState(() { _pwStatus = 'error'; _pwMsg = e.toString(); });
    } finally {
      if (mounted) setState(() => _pwLoading = false);
    }
  }

  bool get _emailChanged =>
      _emailCtrl.text.trim() != context.read<AuthProvider>().user?.email;

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    final first = _firstNameCtrl.text.trim();
    final last  = _lastNameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    if (first == user?.firstName && last == user?.lastName && !_emailChanged) {
      return;
    }

    setState(() { _loading = true; _status = null; });
    try {
      final updated = await ApiClient.updateProfile(
        firstName: first, lastName: last,
        email: email,
        currentPassword: _emailChanged ? _passwordCtrl.text : null);
      final emailChanged = _emailChanged;
      auth.updateUser(updated);
      _passwordCtrl.clear();
      setState(() { _status = 'success'; _msg = 'Profile updated.'; });
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
    final user   = context.watch<AuthProvider>().user!;
    final isDark = context.watch<ThemeProvider>().isDark;
    final theme  = context.watch<ThemeProvider>();

    final bg      = isDark ? AppColors.bg      : AppColors.bgLight;
    final surface = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border  = isDark ? AppColors.border  : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted   : AppColors.textMutedLight;
    final textDim     = isDark ? AppColors.textDim     : AppColors.textDimLight;

    final initials = user.name.isNotEmpty
        ? user.name.trim().split(' ').map((w) => w[0].toUpperCase()).take(2).join()
        : '?';

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Profile',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 28, fontWeight: FontWeight.w800,
                  color: textPrimary, letterSpacing: -0.5)),
              const SizedBox(height: 4),
              Text('Manage your Nexus account.',
                style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
              const SizedBox(height: 28),

              // Avatar + name hero
              Center(
                child: Column(
                  children: [
                    Container(
                      width: 80, height: 80,
                      decoration: BoxDecoration(
                        gradient: AppColors.goldGlow,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.gold.withValues(alpha: 0.4),
                            blurRadius: 24, spreadRadius: 2),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Text(initials,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 26, fontWeight: FontWeight.w800,
                          color: Colors.white)),
                    ),
                    const SizedBox(height: 12),
                    Text(user.name,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 18, fontWeight: FontWeight.w700,
                        color: textPrimary)),
                    const SizedBox(height: 2),
                    Text(user.email,
                      style: GoogleFonts.dmSans(
                        fontSize: 13, color: textMuted)),
                  ],
                ),
              ),
              const SizedBox(height: 28),

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
                          Text('Dark Mode',
                            style: GoogleFonts.dmSans(
                              fontSize: 14, fontWeight: FontWeight.w500,
                              color: textPrimary)),
                          const SizedBox(height: 2),
                          Text(isDark ? 'On — deep navy theme' : 'Off — light theme',
                            style: GoogleFonts.dmSans(
                              fontSize: 12, color: textMuted)),
                        ],
                      ),
                      Switch(
                        value: isDark,
                        onChanged: (_) => theme.toggle(),
                        activeThumbColor: AppColors.gold,
                        activeTrackColor: AppColors.gold.withValues(alpha: 0.25),
                        inactiveThumbColor: textMuted,
                        inactiveTrackColor: border,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Budgets & alerts card (budgets link + email switches)
              const BudgetsAlertsCard(),
              const SizedBox(height: 14),

              // Account info card
              _card(
                surface: surface, border: border,
                children: [
                  _sectionTitle('ACCOUNT INFO', textMuted),
                  _row('Email', user.email,
                    textMuted: textMuted, textPrimary: textPrimary, border: border),
                  _emailStatusRow(user.emailVerified, textMuted: textMuted),
                  _row('Serial Number', user.serialNumber,
                    textMuted: textMuted, textPrimary: textPrimary, border: border,
                    valueStyle: GoogleFonts.spaceGrotesk(
                      fontSize: 13, color: AppColors.gold,
                      letterSpacing: 1.5,
                      fontFeatures: [const FontFeature.tabularFigures()])),
                  _row('Loyalty Points', '${user.loyaltyPoints} pts',
                    textMuted: textMuted, textPrimary: textPrimary, border: border,
                    valueStyle: GoogleFonts.spaceGrotesk(
                      fontSize: 14, color: AppColors.mint,
                      fontWeight: FontWeight.w700)),
                  _row('Member Since', _formatDate(user.createdAt),
                    textMuted: textMuted, textPrimary: textPrimary, border: border,
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
                                  validator: (v) => (v?.trim().isEmpty ?? true)
                                      ? 'Required' : null),
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
                                  validator: (v) => (v?.trim().isEmpty ?? true)
                                      ? 'Required' : null),
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
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return 'Email is required';
                            if (!v.contains('@')) return 'Enter a valid email';
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
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: BorderSide(
                      color: AppColors.alert.withValues(alpha: 0.4)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                    foregroundColor: AppColors.alert,
                  ),
                  child: Text('Sign Out',
                    style: GoogleFonts.spaceGrotesk(
                      fontWeight: FontWeight.w700, fontSize: 14)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card({
    required Color surface,
    required Color border,
    required List<Widget> children,
  }) =>
    Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );

  Widget _emailStatusRow(bool verified, {required Color textMuted}) => Column(children: [
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Email Status', style: GoogleFonts.dmSans(
            fontSize: 13, color: textMuted)),
          verified
              ? _chip(Icons.verified_rounded, 'Verified', AppColors.mint)
              : GestureDetector(
                  onTap: () => VerifyEmailScreen.open(context),
                  child: _chip(Icons.error_outline_rounded,
                    'Not verified · Verify', AppColors.gold),
                ),
        ],
      ),
    ),
    Divider(height: 1, color: AppColors.border.withValues(alpha: 0.4)),
  ]);

  Widget _chip(IconData icon, String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 5),
      Text(label, style: GoogleFonts.dmSans(
        fontSize: 12, fontWeight: FontWeight.w600, color: color)),
    ]),
  );

  Widget _statusBanner(String status, String msg) {
    final color = status == 'success' ? AppColors.mint : AppColors.alert;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(msg, style: GoogleFonts.dmSans(fontSize: 13, color: color)),
    );
  }

  Widget _gradientButton(
    String label, {
    required bool loading,
    required VoidCallback onPressed,
  }) =>
    SizedBox(
      width: double.infinity, height: 48,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppColors.goldGlow,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: AppColors.gold.withValues(alpha: 0.25),
              blurRadius: 14, offset: const Offset(0, 5)),
          ],
        ),
        child: ElevatedButton(
          onPressed: loading ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12))),
          child: loading
              ? const SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
              : Text(label,
                  style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.w700,
                    fontSize: 14, color: Colors.white)),
        ),
      ),
    );

  Widget _fieldLabel(String text, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: GoogleFonts.dmSans(
      fontSize: 13, fontWeight: FontWeight.w500, color: color)),
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
      style: GoogleFonts.dmSans(color: textPrimary, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.dmSans(color: textMuted),
        suffixIcon: suffix,
        filled: true,
        fillColor: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: AppColors.gold.withValues(alpha: 0.6))),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: AppColors.alert.withValues(alpha: 0.5))),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: AppColors.alert.withValues(alpha: 0.7))),
      ),
    );

  Widget _sectionTitle(String t, Color textMuted) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Text(t, style: GoogleFonts.spaceGrotesk(
      fontSize: 10, fontWeight: FontWeight.w700,
      color: textMuted, letterSpacing: 2)),
  );

  Widget _row(
    String label, String value, {
    required Color textMuted,
    required Color textPrimary,
    required Color border,
    TextStyle? valueStyle,
    bool last = false,
  }) =>
    Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: GoogleFonts.dmSans(
              fontSize: 13, color: textMuted)),
            Text(value, style: valueStyle ?? GoogleFonts.dmSans(
              fontSize: 14, color: textPrimary, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
      if (!last) Divider(height: 1,
        color: AppColors.border.withValues(alpha: 0.4)),
    ]);

  String _formatDate(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun',
                'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${m[d.month - 1]} ${d.year}';
  }
}
