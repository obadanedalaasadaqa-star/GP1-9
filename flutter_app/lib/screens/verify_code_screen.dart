import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/theme_provider.dart';
import '../core/user_model.dart';

/// Where the code goes: the account email, or the profile's phone by SMS.
enum CodeChannel { email, phone }

/// '+962791234567' -> '079 123 4567' (anything else is shown as is).
String localPhoneDisplay(String? phone) {
  if (phone == null) return '';
  final m = RegExp(r'^\+962(7\d)(\d{3})(\d{4})$').firstMatch(phone);
  return m == null ? phone : '0${m[1]} ${m[2]} ${m[3]}';
}

/// What differs between the email and phone modes of [VerifyCodeScreen].
class _Mode {
  final IconData icon;
  final String title;
  final String lead;
  final String Function(User? user) destination;
  final Future<void> Function() send;
  final Future<User> Function(String code) verify;
  final String button;
  final String success;
  final String footer;
  const _Mode({
    required this.icon, required this.title, required this.lead, required this.destination,
    required this.send, required this.verify, required this.button, required this.success,
    required this.footer,
  });
}

final _modes = <CodeChannel, _Mode>{
  CodeChannel.email: _Mode(
    icon: Icons.mark_email_unread_rounded,
    title: 'Check your email',
    lead: 'We sent a 6-digit code to\n',
    destination: (user) => user?.email ?? '',
    send: ApiClient.sendEmailCode,
    verify: ApiClient.verifyEmail,
    button: 'Verify Email',
    success: 'Email verified ✓',
    footer: "Can't find it? Check your spam folder.",
  ),
  CodeChannel.phone: _Mode(
    icon: Icons.sms_rounded,
    title: 'Check your messages',
    lead: 'We sent a 6-digit code by SMS to\n',
    destination: (user) => localPhoneDisplay(user?.phone),
    send: ApiClient.sendPhoneCode,
    verify: ApiClient.verifyPhone,
    button: 'Verify Number',
    success: 'Phone number verified ✓',
    footer: 'No SMS after a minute? Check the number in Profile. '
        'Some carriers delay international SMS.',
  ),
};

/// Enter the 6-digit code sent to the user by email or SMS ([channel]).
/// [sendOnOpen]: request a fresh code when the screen opens (false when the
/// backend has just sent one, e.g. right after registering or changing email).
class VerifyCodeScreen extends StatefulWidget {
  final CodeChannel channel;
  final bool sendOnOpen;
  const VerifyCodeScreen({super.key, this.channel = CodeChannel.email, this.sendOnOpen = true});

  static Future<void> openEmail(BuildContext context, {bool sendOnOpen = true}) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VerifyCodeScreen(sendOnOpen: sendOnOpen)));

  /// Verify the profile's phone number. Always sends a fresh SMS on open.
  static Future<void> openPhone(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const VerifyCodeScreen(channel: CodeChannel.phone)));

  @override
  State<VerifyCodeScreen> createState() => _VerifyCodeScreenState();
}

class _VerifyCodeScreenState extends State<VerifyCodeScreen> {
  static const _codeLength = 6;
  static const _resendSeconds = 60;

  final _codeCtrl = TextEditingController();
  final _focus = FocusNode();
  bool _verifying = false;
  bool _sending = false;
  String? _error;
  String? _info;
  int _cooldown = 0;
  Timer? _timer;

  _Mode get _mode => _modes[widget.channel]!;

  @override
  void initState() {
    super.initState();
    if (widget.sendOnOpen) {
      _resend();
    } else {
      _startCooldown(_resendSeconds);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startCooldown(int seconds) {
    _timer?.cancel();
    setState(() => _cooldown = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _resend() async {
    setState(() { _sending = true; _error = null; _info = null; });
    try {
      await _mode.send();
      _codeCtrl.clear();
      setState(() => _info = 'A new code is on its way.');
      _startCooldown(_resendSeconds);
    } on ApiException catch (e) {
      // 429: a code was sent recently — wait out the remaining seconds
      final wait = RegExp(r'(\d+)s').firstMatch(e.message)?.group(1);
      if (e.statusCode == 429 && wait != null) {
        _startCooldown(int.parse(wait));
      } else {
        setState(() => _error = e.message);
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _verify() async {
    final code = _codeCtrl.text;
    if (code.length != _codeLength || _verifying) return;
    setState(() { _verifying = true; _error = null; _info = null; });
    final auth = context.read<AuthProvider>();
    try {
      final user = await _mode.verify(code);
      auth.updateUser(user);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.mint,
        content: Text(_mode.success,
          style: GoogleFonts.dmSans(color: Colors.white, fontWeight: FontWeight.w600)),
      ));
      Navigator.of(context).pop();
    } catch (e) {
      _codeCtrl.clear();
      setState(() => _error = e.toString());
      _focus.requestFocus();
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark      = context.watch<ThemeProvider>().isDark;
    final destination = _mode.destination(context.watch<AuthProvider>().user);
    final bg          = isDark ? AppColors.bg      : AppColors.bgLight;
    final surface     = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border      = isDark ? AppColors.border  : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted   : AppColors.textMutedLight;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Later',
              style: GoogleFonts.dmSans(
                color: textMuted, fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            children: [
              Container(
                width: 72, height: 72,
                decoration: BoxDecoration(
                  gradient: AppColors.goldGlow,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.gold.withValues(alpha: 0.35),
                      blurRadius: 24, spreadRadius: 2),
                  ],
                ),
                child: Icon(_mode.icon, color: Colors.white, size: 34),
              ),
              const SizedBox(height: 24),
              Text(_mode.title,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 24, fontWeight: FontWeight.w800, color: textPrimary)),
              const SizedBox(height: 8),
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: _mode.lead),
                  TextSpan(text: destination,
                    style: TextStyle(color: textPrimary, fontWeight: FontWeight.w600)),
                ]),
                textAlign: TextAlign.center,
                style: GoogleFonts.dmSans(fontSize: 14, color: textMuted, height: 1.5),
              ),
              const SizedBox(height: 32),

              // Code boxes: one hidden text field drives six display boxes
              GestureDetector(
                onTap: () => _focus.requestFocus(),
                child: Stack(
                  children: [
                    Opacity(
                      opacity: 0,
                      child: TextField(
                        controller: _codeCtrl,
                        focusNode: _focus,
                        keyboardType: TextInputType.number,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        maxLength: _codeLength,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        onChanged: (v) {
                          setState(() => _error = null);
                          if (v.length == _codeLength) _verify();
                        },
                      ),
                    ),
                    ListenableBuilder(
                      listenable: Listenable.merge([_codeCtrl, _focus]),
                      builder: (context, _) => Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: List.generate(_codeLength, (i) {
                          final text = _codeCtrl.text;
                          final filled = i < text.length;
                          final active = _focus.hasFocus && i == text.length;
                          return Container(
                            width: 48, height: 58,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: surface,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                width: active ? 2 : 1,
                                color: _error != null
                                    ? AppColors.alert.withValues(alpha: 0.6)
                                    : active ? AppColors.gold : border),
                            ),
                            child: Text(filled ? text[i] : '',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 24, fontWeight: FontWeight.w700,
                                color: textPrimary)),
                          );
                        }),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              if (_error != null)
                Text(_error!, textAlign: TextAlign.center,
                  style: GoogleFonts.dmSans(fontSize: 13, color: AppColors.alert))
              else if (_info != null)
                Text(_info!, textAlign: TextAlign.center,
                  style: GoogleFonts.dmSans(fontSize: 13, color: AppColors.mint)),
              const SizedBox(height: 24),

              SizedBox(
                width: double.infinity, height: 50,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: AppColors.goldGlow,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: ElevatedButton(
                    onPressed: _verifying ? null : _verify,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14))),
                    child: _verifying
                        ? const SizedBox(width: 20, height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                        : Text(_mode.button,
                            style: GoogleFonts.spaceGrotesk(
                              fontWeight: FontWeight.w700,
                              fontSize: 15, color: Colors.white)),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              TextButton(
                onPressed: (_cooldown > 0 || _sending) ? null : _resend,
                child: Text(
                  _sending
                      ? 'Sending…'
                      : _cooldown > 0 ? 'Resend code in ${_cooldown}s' : 'Resend code',
                  style: GoogleFonts.dmSans(
                    fontSize: 14, fontWeight: FontWeight.w600,
                    color: (_cooldown > 0 || _sending) ? textMuted : AppColors.gold)),
              ),
              const SizedBox(height: 4),
              Text(_mode.footer, textAlign: TextAlign.center,
                style: GoogleFonts.dmSans(fontSize: 12, color: textMuted)),
            ],
          ),
        ),
      ),
    );
  }
}
