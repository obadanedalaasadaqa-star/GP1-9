import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/auth_provider.dart';
import '../core/biometric_service.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/google_sign_in_result.dart';
import '../core/validators.dart';
import '../widgets/face_id_glyph.dart';
import '../widgets/google_password_sheet.dart';
import '../widgets/google_sign_in_button.dart';
import '../widgets/notice_banner.dart';
import '../widgets/password_meter.dart';
import 'forgot_password_screen.dart';
import 'verify_email_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  /// The amber Face ID notice text (design 1.6), for tests.
  @visibleForTesting
  static String noticeTextFor(BiometricNotice notice, String name, {bool google = false}) =>
      _AuthScreenState._noticeText(notice, name, google: google);
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

  // Continue with Google: busy while Google's sheet is up and Nexus checks
  // the token; its banner (coral or amber, design 1.6) takes the one banner
  // spot like _error.
  bool _googleBusy = false;
  ({String text, bool error})? _googleNotice;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() {
      setState(() {
        _error = null;
        _googleNotice = null;
      });
      context.read<AuthProvider>().clearBiometricNotice();
    });
    // Face ID locked cold start: prompt once by itself. The one-shot lives in
    // AuthProvider, so rebuilds and tab switches never prompt again.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      if (auth.showFacePill && auth.consumeAutoPrompt()) auth.unlockWithBiometrics();
    });
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
    final auth = context.read<AuthProvider>();
    // A wrong password's coral banner takes the notice's place, never both.
    auth.clearBiometricNotice();
    if (_googleNotice != null) setState(() => _googleNotice = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() { _loading = true; _error = null; });
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

  /// Continue with Google: Google's sheet, then the Nexus server. A
  /// challenge opens the code screen; "password needed" opens the link sheet.
  Future<void> _google() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final auth = context.read<AuthProvider>();
    auth.clearBiometricNotice();
    setState(() {
      _googleBusy = true;
      _error = null;
      _googleNotice = null;
    });
    try {
      final result = await auth.signInWithGoogle();
      if (!mounted) return;
      setState(() => _googleBusy = false);
      switch (result) {
        case GoogleChallenge(:final challenge):
          await VerifyEmailScreen.openLogin(context, challenge);
        case GooglePasswordNeeded(:final email):
          await _link(email);
        case GoogleTokenExpired():
          setState(() => _googleNotice = (
            text: 'That took a while, so Google needs to check again. Tap Continue with Google.',
            error: false));
        case GoogleSession():
        case null:
          break; // signed in (the shell takes over), or cancelled: no message
      }
    } catch (e) {
      if (mounted) setState(() => _googleNotice = googleNoticeFor(e));
    } finally {
      if (mounted && _googleBusy) setState(() => _googleBusy = false);
    }
  }

  /// "Connect Google to your account": the Google email already has a Nexus
  /// account. Every way out that isn't a sign-in drops the held token.
  Future<void> _link(String email) async {
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final outcome = await GooglePasswordSheet.show(context, email: email);
    switch (outcome) {
      case GoogleLinkDone():
        messenger.showSnackBar(const SnackBar(
          content: Text('Google is connected. Next time, just tap Continue with Google.')));
      case GoogleLinkChallenge(:final challenge):
        if (mounted) await VerifyEmailScreen.openLogin(context, challenge);
      case GoogleLinkNotice(:final text, :final error):
        auth.dropPendingGoogle();
        if (mounted) setState(() => _googleNotice = (text: text, error: error));
      case GoogleLinkForgot():
        auth.dropPendingGoogle();
        await navigator.push(MaterialPageRoute(
          builder: (_) => ForgotPasswordScreen(initialEmail: email)));
      case null:
        auth.dropPendingGoogle();
    }
  }

  /// The design 1.6 notice copy ("Touch ID" on Touch ID phones). With the
  /// Google button shown, "with your password" becomes "with your password
  /// or with Google" (a Google-only account has no password).
  static String _noticeText(BiometricNotice notice, String name, {bool google = false}) =>
      google ? _noticeTextGoogle(notice, name) : _noticeTextPassword(notice, name);

  static String _noticeTextGoogle(BiometricNotice notice, String name) => switch (notice) {
    BiometricNotice.sessionEnded => 'Your session ended. Sign in with your password or with Google.',
    BiometricNotice.invalidated =>
      '$name changed on this iPhone. Sign in with your password or with Google to turn it on again.',
    BiometricNotice.lockout =>
      '$name is locked. Sign in with your password or with Google, or unlock your iPhone and try again.',
    BiometricNotice.notAvailable =>
      '$name is off for Nexus in iPhone Settings. Sign in with your password or with Google.',
    BiometricNotice.notEnrolled =>
      "$name isn't set up on this iPhone. Sign in with your password or with Google.",
    BiometricNotice.error => "$name didn't work this time. Sign in with your password or with Google.",
  };

  static String _noticeTextPassword(BiometricNotice notice, String name) => switch (notice) {
    BiometricNotice.sessionEnded => 'Your session ended. Sign in with your password.',
    BiometricNotice.invalidated =>
      '$name changed on this iPhone. Sign in with your password to turn it on again.',
    BiometricNotice.lockout =>
      '$name is locked. Sign in with your password, or unlock your iPhone and try again.',
    BiometricNotice.notAvailable =>
      '$name is off for Nexus in iPhone Settings. Sign in with your password.',
    BiometricNotice.notEnrolled => "$name isn't set up on this iPhone. Sign in with your password.",
    BiometricNotice.error => "$name didn't work this time. Sign in with your password.",
  };

  /// "Sign in with Face ID": the lime action while the session is Face ID
  /// locked. Busy while the prompt (and the session check after it) runs.
  Widget _facePill(AuthProvider auth, Nx nx) {
    final name = auth.biometricName;
    final busy = auth.unlocking;
    // Busy keeps the look and ignores taps; a password sign-in disables it.
    final VoidCallback? onTap = _loading || _googleBusy ? null : (busy ? () {} : auth.unlockWithBiometrics);
    return Padding(
      padding: const EdgeInsets.only(right: 4, bottom: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          boxShadow: const [
            BoxShadow(color: AppColors.ink, offset: Offset(4, 4)),
          ],
        ),
        child: Pressable(
          onTap: onTap,
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const ValueKey('face-id-sign-in'),
              onPressed: onTap,
              style: NxButtonStyle.solid(nx,
                fill: AppColors.lime, text: AppColors.ink, height: 56)
                .copyWith(
                  side: WidgetStateProperty.all(
                    const BorderSide(color: AppColors.ink, width: 2)),
                  textStyle: WidgetStateProperty.all(
                    NxType.display(18, weight: FontWeight.w700,
                      letterSpacing: -0.2))),
              // Merged into the button: "Sign in with Face ID, Waiting for Face ID".
              child: Semantics(
                value: busy ? 'Waiting for $name' : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy)
                      const SizedBox(width: 24, height: 24,
                        child: Center(child: SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: AppColors.ink))))
                    else if (auth.biometricAvailability.kind == BiometricKind.fingerprint)
                      const ExcludeSemantics(
                        child: Icon(Icons.fingerprint, size: 24, color: AppColors.ink))
                    else
                      const FaceIdGlyph(size: 24, color: AppColors.ink),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text('Sign in with $name',
                        textAlign: TextAlign.center, maxLines: 2),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final auth = context.watch<AuthProvider>();
    // The pill, the outline password button and the hidden "New here?" link
    // go together (design R4). Never on Register, never off iOS (S21).
    final showPill = auth.showFacePill && !_isRegister;
    final showGoogle = auth.googleAvailable;
    final googleNotice = _error == null ? _googleNotice : null;
    final notice = isIosPlatform && !_isRegister && _error == null && googleNotice == null
        ? auth.biometricNotice : null;
    final hasBanner = _error != null || googleNotice != null || notice != null;
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
                      // While Google is busy, nothing else on the sheet takes
                      // a tap (one sign-in at a time).
                      child: AbsorbPointer(
                        absorbing: _googleBusy,
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
                          if (showPill) ...[
                            _facePill(auth, nx),
                            const SizedBox(height: 16),
                          ],

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

                                if (notice != null) ...[
                                  const SizedBox(height: 16),
                                  NxNoticeBanner(_noticeText(notice, auth.biometricName,
                                    google: showGoogle)),
                                ],
                                if (googleNotice != null) ...[
                                  const SizedBox(height: 16),
                                  NxNoticeBanner(googleNotice.text, error: googleNotice.error),
                                ],
                                if (_error != null) ...[
                                  const SizedBox(height: 16),
                                  NxNoticeBanner(_error!, error: true),
                                ],

                                // The forgot-password row already gives the air on Sign In;
                                // a banner gets 12 so it never touches the button.
                                SizedBox(height: _isRegister ? 22 : (hasBanner ? 12 : 0)),
                                // Face ID locked: the password is the outline second
                                // action, and "New here?" waits (the Register tab is there).
                                if (showPill)
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton(
                                      key: const ValueKey('password-sign-in'),
                                      onPressed: _loading || auth.unlocking ? null : _submit,
                                      style: NxButtonStyle.outline(nx),
                                      child: _loading
                                          ? SizedBox(width: 20, height: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2.5, color: nx.text))
                                          : const Text('Sign in with password'),
                                    ),
                                  )
                                else ...[
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
                                ],
                                // Continue with Google under the main button (or the
                                // outline password button), never next to the Face ID
                                // pill (S32). It replaces the switch link: the tab bar
                                // already does that job (design 1.3).
                                // Gap 10, not 12: the design's fallback, because 12
                                // made the Sign In tab scroll 1 pt at 393x852.
                                if (showGoogle) ...[
                                  const SizedBox(height: 10),
                                  GoogleSignInButton(
                                    busy: _googleBusy,
                                    onPressed: _loading || auth.unlocking ? null : _google),
                                ] else if (!showPill) ...[
                                const SizedBox(height: 14),
                                Center(
                                  key: const ValueKey('auth-switch-link'),
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
                              ],
                            ),
                          ),
                        ],
                      ),
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
      onChanged: (_) {
        context.read<AuthProvider>().clearBiometricNotice();
        if (_googleNotice != null) setState(() => _googleNotice = null);
      },
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
