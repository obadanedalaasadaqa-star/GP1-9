import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/validators.dart';
import '../widgets/password_meter.dart';
import 'forgot_password_screen.dart';
import 'verify_email_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  final _formKey = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _lastName  = TextEditingController();
  final _email    = TextEditingController();
  final _password = TextEditingController();

  bool _loading = false;
  String? _error;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() => setState(() => _error = null));
  }

  @override
  void dispose() {
    _tabs.dispose();
    _firstName.dispose();
    _lastName.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _isRegister => _tabs.index == 1;

  Future<void> _submit() async {
    // Close the keyboard first, so field errors and the error banner are in view.
    FocusManager.instance.primaryFocus?.unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() { _loading = true; _error = null; });
    final auth = context.read<AuthProvider>();
    try {
      if (_isRegister) {
        await auth.register(
          firstName: _firstName.text.trim(),
          lastName: _lastName.text.trim(),
          email: _email.text.trim(),
          password: _password.text,
        );
      } else {
        final challenge = await auth.login(_email.text.trim(), _password.text);
        // Two-step sign-in is on: ask for the emailed code. Cancel comes back
        // here with the email and password still filled in.
        if (challenge != null && mounted) {
          setState(() => _loading = false);
          await VerifyEmailScreen.openLogin(context, challenge);
        }
      }
    } catch (e) {
      setState(() => _error = e.toString());
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
    final hero = isDark ? AppColors.ink : AppColors.cobalt;
    final sheet = isDark ? AppColors.surface : AppColors.paper;
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    // Hero + sheet fill the screen exactly with the keyboard down.
    final heroHeight = 300 + padding.top;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
      backgroundColor: sheet,
      // Only seen on iOS overscroll now (hero at the top, sheet at the bottom);
      // the sheet corners are backed by the ColoredBox below.
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [hero, hero, sheet, sheet],
            stops: const [0, 0.4, 0.4, 1],
          ),
        ),
        child: StatusBarStrip(
          color: hero,
          child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Hero ──────────────────────────────────────────────
                  Container(
                    key: const ValueKey('auth-hero'),
                    color: hero,
                    height: heroHeight,
                    padding: EdgeInsets.fromLTRB(26, padding.top, 0, 0),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // A receipt slip peeking in from the corner
                        Positioned(
                          key: const ValueKey('auth-hero-slip'),
                          right: -30, top: 26,
                          child: Transform.rotate(
                            angle: 0.32,
                            child: const _HeroSlip(),
                          ),
                        ),
                        Positioned(
                          left: 0, bottom: 30,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(right: 54),
                                    child: Text('Nexus',
                                      style: NxType.display(72, color: Colors.white,
                                        letterSpacing: -4, height: 1)),
                                  ),
                                  const Positioned(
                                    right: -6, top: -4,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.fromBorderSide(
                                          BorderSide(color: AppColors.ink, width: 2.5))),
                                      child: NxStamp(value: '+12', caption: 'POINTS',
                                        color: AppColors.ink, fill: AppColors.lime,
                                        size: 62, tilt: -12),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text('Every receipt, without\nthe paper.',
                                style: NxType.body(19, color: AppColors.lime,
                                  weight: FontWeight.w700, height: 1.2)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // ── Sheet ─────────────────────────────────────────────
                  // Hero colour behind the sheet, so its rounded top corners
                  // never show the page colour, whatever the scroll or keyboard.
                  ColoredBox(
                    color: hero,
                    child: Container(
                      key: const ValueKey('auth-sheet'),
                      constraints: BoxConstraints(
                        minHeight: math.max(0, size.height - heroHeight)),
                      decoration: BoxDecoration(
                        color: sheet,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                        border: Border(top: BorderSide(color: border, width: 2)),
                      ),
                      padding: EdgeInsets.fromLTRB(
                        22, 22, 22, 24 + padding.bottom),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Tab bar
                          Container(
                            height: 50,
                            decoration: BoxDecoration(
                              color: nx.card,
                              borderRadius: BorderRadius.circular(25),
                              border: Border.all(color: border, width: 2),
                            ),
                            padding: const EdgeInsets.all(4),
                            child: TabBar(
                              controller: _tabs,
                              indicator: BoxDecoration(
                                color: isDark ? AppColors.lime : AppColors.ink,
                                borderRadius: BorderRadius.circular(21),
                              ),
                              indicatorSize: TabBarIndicatorSize.tab,
                              labelColor: isDark ? AppColors.ink : Colors.white,
                              unselectedLabelColor: textPrimary,
                              labelStyle: NxType.body(15, weight: FontWeight.w700),
                              unselectedLabelStyle: NxType.body(15, weight: FontWeight.w700),
                              dividerColor: Colors.transparent,
                              splashFactory: NoSplash.splashFactory,
                              overlayColor: WidgetStateProperty.all(Colors.transparent),
                              tabs: const [Tab(text: 'Sign In'), Tab(text: 'Register')],
                            ),
                          ),
                          // 16, not 22: room for the forgot-password row, so Sign In
                          // still fits without scrolling at 393x852.
                          const SizedBox(height: 16),

                          Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_isRegister) ...[
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          _label('First Name', textMuted),
                                          _field(_firstName, 'First',
                                            isDark: isDark, border: border,
                                            textPrimary: textPrimary, textMuted: textMuted,
                                            validator: (v) => validateName(v, 'First name')),
                                        ],
                                      )),
                                      const SizedBox(width: 12),
                                      Expanded(child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          _label('Last Name', textMuted),
                                          _field(_lastName, 'Last',
                                            isDark: isDark, border: border,
                                            textPrimary: textPrimary, textMuted: textMuted,
                                            validator: (v) => validateName(v, 'Last name')),
                                        ],
                                      )),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                ],
                                _label('Email', textMuted),
                                _field(_email, 'you@example.com',
                                  keyboard: TextInputType.emailAddress,
                                  isDark: isDark, border: border,
                                  textPrimary: textPrimary, textMuted: textMuted,
                                  // Sign-in accepts older addresses; new ones must be valid
                                  validator: (v) {
                                    if (_isRegister) return validateEmail(v);
                                    if (v == null || v.isEmpty) return 'Email is required';
                                    if (!v.contains('@')) return 'Enter a valid email';
                                    return null;
                                  }),
                                const SizedBox(height: 16),
                                _label('Password', textMuted),
                                _field(_password, '••••••••',
                                  obscure: _obscure,
                                  isDark: isDark, border: border,
                                  textPrimary: textPrimary, textMuted: textMuted,
                                  suffix: IconButton(
                                    tooltip: _obscure ? 'Show password' : 'Hide password',
                                    icon: Icon(
                                      _obscure ? Icons.visibility_off : Icons.visibility,
                                      color: textMuted, size: 20),
                                    onPressed: () => setState(() => _obscure = !_obscure),
                                  ),
                                  // Sign-in accepts older passwords; new ones must meet the rules
                                  validator: (v) => _isRegister
                                      ? validateNewPassword(v)
                                      : (v == null || v.isEmpty) ? 'Password is required' : null),
                                if (!_isRegister)
                                  SizedBox(
                                    key: const ValueKey('forgot-password-row'),
                                    height: 44,
                                    width: double.infinity,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton(
                                        style: TextButton.styleFrom(
                                          minimumSize: const Size(44, 44),
                                          padding: const EdgeInsets.symmetric(horizontal: 4),
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                                        onPressed: () => Navigator.of(context).push(
                                          MaterialPageRoute(builder: (_) => ForgotPasswordScreen(
                                            initialEmail: _email.text.trim()))),
                                        child: Text('Forgot password?',
                                          style: NxType.body(14, color: textPrimary,
                                            weight: FontWeight.w700).copyWith(
                                            decoration: TextDecoration.underline,
                                            decorationColor: textPrimary)),
                                      ),
                                    ),
                                  ),
                                if (_isRegister)
                                  PasswordMeter(
                                    controller: _password,
                                    textMuted: textMuted,
                                    track: nx.hairline),

                                if (_error != null) ...[
                                  const SizedBox(height: 16),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 11),
                                    decoration: BoxDecoration(
                                      color: AppColors.coral,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(color: AppColors.ink, width: 2),
                                    ),
                                    child: Row(children: [
                                      const Icon(Icons.error_outline,
                                        color: AppColors.ink, size: 18),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text(_error!,
                                        style: NxType.body(13.5,
                                          weight: FontWeight.w600, color: AppColors.ink))),
                                    ]),
                                  ),
                                ],

                                // The forgot-password row already gives the air on Sign In.
                                SizedBox(height: _isRegister ? 22 : 0),
                                Padding(
                                  padding: const EdgeInsets.only(right: 4, bottom: 4),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(28),
                                      boxShadow: const [
                                        BoxShadow(color: AppColors.ink, offset: Offset(4, 4)),
                                      ],
                                    ),
                                    child: SizedBox(
                                      width: double.infinity,
                                      child: ElevatedButton(
                                        onPressed: _loading ? null : _submit,
                                        style: NxButtonStyle.solid(nx,
                                          fill: AppColors.lime, text: AppColors.ink, height: 56)
                                          .copyWith(
                                            side: WidgetStateProperty.all(
                                              const BorderSide(color: AppColors.ink, width: 2)),
                                            textStyle: WidgetStateProperty.all(
                                              NxType.display(18, weight: FontWeight.w700,
                                                letterSpacing: -0.2))),
                                        child: _loading
                                            ? const SizedBox(width: 20, height: 20,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2.5, color: AppColors.ink))
                                            : Text(_isRegister ? 'Create Account' : 'Sign In'),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Center(
                                  child: TextButton(
                                    // 44 high like the forgot-password link (not
                                    // Material's padded 48), so Sign In fits at 393x852.
                                    style: TextButton.styleFrom(
                                      minimumSize: const Size(44, 44),
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                                    onPressed: () => _tabs.animateTo(_isRegister ? 0 : 1),
                                    child: Text(
                                      _isRegister
                                          ? 'Have an account? Sign in instead'
                                          : 'New here? Create an account',
                                      style: NxType.body(14, color: textPrimary,
                                        weight: FontWeight.w700).copyWith(
                                        decoration: TextDecoration.underline,
                                        decorationColor: textPrimary)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    ),
    );
  }

  Widget _label(String text, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text.toUpperCase(), style: NxType.label(color)),
  );

  Widget _field(
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

/// Decorative till slip in the sign-in hero.
class _HeroSlip extends StatelessWidget {
  const _HeroSlip();

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, Color c, {double h = 9}) => Container(
      width: w, height: h,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)));
    return ExcludeSemantics(
      child: SizedBox(
        width: 150,
        child: Column(
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bar(90, AppColors.ink, h: 11),
                  const DashedRule(color: AppColors.ink, thickness: 1.5),
                  const SizedBox(height: 8),
                  bar(110, AppColors.dotted),
                  bar(80, AppColors.dotted),
                  const DashedRule(color: AppColors.ink, thickness: 1.5),
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerRight,
                    child: bar(56, AppColors.coral, h: 13)),
                ],
              ),
            ),
            const ReceiptEdge(color: AppColors.ink, height: 9),
          ],
        ),
      ),
    );
  }
}
