import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/login_challenge.dart';

/// Enter the 6-digit code emailed to the user.
/// [sendOnOpen]: request a fresh code when the screen opens (false when the
/// backend has just sent one, e.g. right after registering or changing email).
/// [login]: two-step sign-in mode. The code is a sign-in code for this
/// challenge, and the right one logs the user in (see [openLogin]).
class VerifyEmailScreen extends StatefulWidget {
  final bool sendOnOpen;
  final LoginChallenge? login;
  const VerifyEmailScreen({super.key, this.sendOnOpen = true, this.login});

  static Future<void> open(BuildContext context, {bool sendOnOpen = true}) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VerifyEmailScreen(sendOnOpen: sendOnOpen)));

  /// "Confirm it's you" after a correct password on an account with two-step
  /// sign-in on. Asks for a code when it opens.
  static Future<void> openLogin(BuildContext context, LoginChallenge c) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VerifyEmailScreen(login: c)));

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

  /// Login mode: the challenge was rejected (expired, or the password changed),
  /// so the only way on is back to the login form.
  bool _expired = false;

  bool get _loginMode => widget.login != null;

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
      final login = widget.login;
      if (login == null) {
        await ApiClient.sendEmailCode();
      } else {
        await ApiClient.sendLoginCode(login.challengeToken);
      }
      _codeCtrl.clear();
      setState(() => _info = 'A new code is on its way.');
      _startCooldown(_resendSeconds);
    } on ApiException catch (e) {
      // 429: a code was sent recently — wait out the remaining seconds
      final wait = RegExp(r'(\d+)s').firstMatch(e.message)?.group(1);
      if (e.statusCode == 429 && wait != null) {
        _startCooldown(int.parse(wait));
      } else {
        setState(() {
          _error = e.message;
          if (_loginMode && e.statusCode == 401) _expired = true;
        });
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
    final login = widget.login;
    final navigator = Navigator.of(context);
    try {
      if (login != null) {
        final session = await ApiClient.verifyLogin(login.challengeToken, code);
        // The app shell replaces the login form under this route, so the pop
        // shows the dashboard. If the user tapped Cancel while waiting, this
        // route is already gone: popping again would pop the app shell.
        await auth.completeLogin(session.token, session.user);
        if (mounted) navigator.pop();
        return;
      }
      final user = await ApiClient.verifyEmail(code);
      auth.updateUser(user);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: AppColors.teal,
        content: Text('Email verified ✓',
          style: NxType.body(14, color: AppColors.ink, weight: FontWeight.w700)),
      ));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      _codeCtrl.clear();
      setState(() {
        _error = e.toString();
        if (_loginMode && e is ApiException && e.statusCode == 401) _expired = true;
      });
      _focus.requestFocus();
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nx          = Nx.of(context);
    final login       = widget.login;
    final email       = login?.email ?? context.watch<AuthProvider>().user?.email ?? '';
    final pageBg      = nx.dark ? AppColors.ink : AppColors.pageVerify;
    final onPage      = nx.dark ? Colors.white : AppColors.ink;
    const ink         = AppColors.ink;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
      backgroundColor: pageBg,
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44, height: 44,
                    decoration: const BoxDecoration(color: ink, shape: BoxShape.circle),
                    child: Icon(
                      login != null ? Icons.lock_outline_rounded : Icons.mark_email_unread_outlined,
                      color: Colors.white, size: 22),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    // Email mode: skip for now (verify later from Profile).
                    // Login mode: back to the login form, which keeps what was typed.
                    child: Text(login != null ? 'Cancel' : 'Verify later',
                      style: NxType.body(15, color: onPage, weight: FontWeight.w700)
                        .copyWith(decoration: TextDecoration.underline,
                          decorationColor: onPage)),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Text(login != null ? "Confirm it's you" : 'Check your email',
                style: NxType.display(44, color: onPage, letterSpacing: -2, height: 1)),
              const SizedBox(height: 12),
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: login != null
                      ? 'We sent a sign-in code to\n'
                      : 'We sent a 6-digit code to\n'),
                  TextSpan(text: email,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
                style: NxType.body(15, color: onPage, height: 1.45),
              ),
              const SizedBox(height: 26),

              // Code boxes on a slip: one hidden text field drives six boxes
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Transform.rotate(
                  angle: 0.012,
                  child: DecoratedBox(
                    decoration: BoxDecoration(boxShadow: [
                      BoxShadow(color: nx.dark ? AppColors.lime : ink,
                        offset: const Offset(5, 6)),
                    ]),
                    child: Column(
                      children: [
                        const ReceiptEdge(color: Colors.white, up: true),
                        Container(
                          color: Colors.white,
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('YOUR CODE', style: NxType.label(AppColors.textMutedLight)),
                              const SizedBox(height: 10),
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
                                        children: List.generate(_codeLength, (i) {
                                          final text = _codeCtrl.text;
                                          final filled = i < text.length;
                                          final active = _focus.hasFocus && i == text.length;
                                          return Expanded(
                                            child: Container(
                                              height: 58,
                                              margin: EdgeInsets.only(right: i < _codeLength - 1 ? 7 : 0),
                                              alignment: Alignment.center,
                                              decoration: BoxDecoration(
                                                color: filled ? AppColors.lime : Colors.white,
                                                borderRadius: BorderRadius.circular(14),
                                                border: Border.all(
                                                  width: active ? 3 : 2,
                                                  color: _error != null
                                                      ? AppColors.danger
                                                      : active ? AppColors.cobalt : ink),
                                              ),
                                              child: Text(filled ? text[i] : '',
                                                style: NxType.mono(24, color: ink,
                                                  weight: FontWeight.w500)),
                                            ),
                                          );
                                        }),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const ReceiptEdge(color: Colors.white),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              if (_error != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.coral,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: ink, width: 2)),
                  child: Text(_error!,
                    style: NxType.body(13.5, color: ink, weight: FontWeight.w600)),
                )
              else if (_info != null)
                Text(_info!,
                  style: NxType.body(14, color: onPage, weight: FontWeight.w700)),
              const SizedBox(height: 26),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _expired
                      ? () => Navigator.of(context).pop()
                      : _verifying ? null : _verify,
                  style: NxButtonStyle.solid(nx,
                    fill: nx.dark ? AppColors.lime : ink,
                    text: nx.dark ? ink : Colors.white, height: 56),
                  child: _verifying
                      ? SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: nx.dark ? ink : Colors.white))
                      : Text(_expired ? 'Back to login' : login != null ? 'Sign in' : 'Verify Email'),
                ),
              ),
              const SizedBox(height: 12),

              Center(
                child: Column(
                  children: [
                    if (!_expired) TextButton(
                      onPressed: (_cooldown > 0 || _sending) ? null : _resend,
                      child: Text(
                        _sending
                            ? 'Sending…'
                            : _cooldown > 0 ? 'Resend code in ${_cooldown}s' : 'Resend code',
                        style: NxType.mono(13.5, color: onPage,
                          weight: (_cooldown > 0 || _sending) ? FontWeight.w400 : FontWeight.w500)),
                    ),
                    const SizedBox(height: 2),
                    Text("Can't find it? Check your spam folder.",
                      style: NxType.body(12.5, color: onPage)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }
}
