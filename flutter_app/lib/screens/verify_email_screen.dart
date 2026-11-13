import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/theme_provider.dart';

/// Enter the 6-digit code emailed to the user.
/// [sendOnOpen]: request a fresh code when the screen opens (false when the
/// backend has just sent one, e.g. right after registering or changing email).
class VerifyEmailScreen extends StatefulWidget {
  final bool sendOnOpen;
  const VerifyEmailScreen({super.key, this.sendOnOpen = true});

  static Future<void> open(BuildContext context, {bool sendOnOpen = true}) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VerifyEmailScreen(sendOnOpen: sendOnOpen)));

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
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
      await ApiClient.sendEmailCode();
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
      final user = await ApiClient.verifyEmail(code);
      auth.updateUser(user);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.mint,
        content: Text('Email verified ✓',
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
    final email       = context.watch<AuthProvider>().user?.email ?? '';
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
                child: const Icon(Icons.mark_email_unread_rounded,
                  color: Colors.white, size: 34),
              ),
              const SizedBox(height: 24),
              Text('Check your email',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 24, fontWeight: FontWeight.w800, color: textPrimary)),
              const SizedBox(height: 8),
              Text.rich(
                TextSpan(children: [
                  const TextSpan(text: 'We sent a 6-digit code to\n'),
                  TextSpan(text: email,
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
                        : Text('Verify Email',
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
              Text("Can't find it? Check your spam folder.",
                style: GoogleFonts.dmSans(fontSize: 12, color: textMuted)),
            ],
          ),
        ),
      ),
    );
  }
}
