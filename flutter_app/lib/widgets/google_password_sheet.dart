import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/design.dart';
import '../core/google_sign_in_result.dart';
import '../core/login_challenge.dart';
import 'google_sign_in_button.dart';
import 'notice_banner.dart';

const _kUnreachable = "Can't reach the Nexus server. Check your connection and try again.";
const _kExpired = 'That took a while, so Google needs to check again. Tap Continue with Google.';

/// How the link sheet ended. Null (from [GooglePasswordSheet.show]) means
/// Cancel, a swipe down or back: the caller drops the held Google token.
sealed class GoogleLinkOutcome {
  const GoogleLinkOutcome();
}

/// Connected and signed in.
class GoogleLinkDone extends GoogleLinkOutcome {
  const GoogleLinkDone();
}

/// Two-step sign-in is on: the code screen finishes it.
class GoogleLinkChallenge extends GoogleLinkOutcome {
  final LoginChallenge challenge;
  const GoogleLinkChallenge(this.challenge);
}

/// The sheet closed with a banner for the sign-in tab.
class GoogleLinkNotice extends GoogleLinkOutcome {
  final String text;
  final bool error;
  const GoogleLinkNotice(this.text, {required this.error});
}

/// "Forgot password?": open Forgot password with the Google email.
class GoogleLinkForgot extends GoogleLinkOutcome {
  const GoogleLinkForgot();
}

/// "Connect Google to your account" (design.md section 2): the Google email
/// already has a Nexus account, so its password is needed once. The password
/// is only passed to AuthProvider, never kept.
class GooglePasswordSheet extends StatefulWidget {
  final String email;
  const GooglePasswordSheet({super.key, required this.email});

  static Future<GoogleLinkOutcome?> show(BuildContext context, {required String email}) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return showModalBottomSheet<GoogleLinkOutcome>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      sheetAnimationStyle: reduceMotion ? AnimationStyle.noAnimation : null,
      builder: (_) => GooglePasswordSheet(email: email),
    );
  }

  @override
  State<GooglePasswordSheet> createState() => _GooglePasswordSheetState();
}

class _GooglePasswordSheetState extends State<GooglePasswordSheet> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _focus = FocusNode();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _error = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final auth = context.read<AuthProvider>();
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final r = await auth.continueGoogleWithPassword(_password.text);
      if (!mounted) return;
      switch (r) {
        case null:
          navigator.pop(const GoogleLinkDone());
        case GoogleChallenge(:final challenge):
          navigator.pop(GoogleLinkChallenge(challenge));
        case GooglePasswordNeeded(:final message):
          // Wrong password: the sheet stays, the typed password too.
          setState(() {
            _busy = false;
            _error = message.isEmpty ? "That password doesn't match. Try again, or tap Forgot password." : message;
          });
          _focus.requestFocus();
        case GoogleTokenExpired():
          navigator.pop(const GoogleLinkNotice(_kExpired, error: false));
        case GoogleSession():
          navigator.pop(const GoogleLinkDone());
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (!e.fromServer || e.statusCode == 429) {
        // No connection, or the login limiter: stay, so it can be tried again.
        setState(() {
          _busy = false;
          _error = e.fromServer ? e.message : _kUnreachable;
        });
        return;
      }
      final n = googleNoticeFor(e);
      navigator.pop(GoogleLinkNotice(n.text, error: n.error));
    } catch (e) {
      if (!mounted) return;
      final n = googleNoticeFor(e);
      navigator.pop(GoogleLinkNotice(n.text, error: n.error));
    }
  }

  void _cancel() {
    if (_busy) return;
    Navigator.of(context).pop();
  }

  void _forgot() {
    if (_busy) return;
    Navigator.of(context).pop(const GoogleLinkForgot());
  }

  Widget _link(String text, Key key, VoidCallback onPressed, Nx nx) => TextButton(
    key: key,
    style: TextButton.styleFrom(
      minimumSize: const Size(44, 44),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    onPressed: _busy ? null : onPressed,
    child: Text(
      text,
      style: NxType.body(
        14,
        color: nx.text,
        weight: FontWeight.w700,
      ).copyWith(decoration: TextDecoration.underline, decorationColor: nx.text),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    return PopScope(
      canPop: !_busy,
      // While busy, a drag on the sheet is taken here, so it can't be swiped away.
      child: GestureDetector(
        onVerticalDragStart: _busy ? (_) {} : null,
        onVerticalDragUpdate: _busy ? (_) {} : null,
        onVerticalDragEnd: _busy ? (_) {} : null,
        // The button stays above the keyboard; large text scrolls.
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: NxSheet(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text('Connect Google to your account', style: NxType.display(24, color: nx.text)),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'This email already has a Nexus account. Enter its password once, '
                    'then Continue with Google signs you straight in.',
                    style: NxType.body(14.5, color: nx.muted, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('EMAIL', style: NxType.label(nx.muted)),
                  ),
                  Semantics(
                    label: widget.email,
                    excludeSemantics: true,
                    child: Text(
                      widget.email,
                      key: const ValueKey('google-link-email'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NxType.body(15.5, color: nx.text, weight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('PASSWORD', style: NxType.label(nx.muted)),
                  ),
                  TextFormField(
                    key: const ValueKey('google-link-password'),
                    controller: _password,
                    focusNode: _focus,
                    autofocus: true,
                    readOnly: _busy,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) => (v == null || v.isEmpty) ? 'Password is required' : null,
                    style: NxType.body(15.5, color: nx.text),
                    decoration: nxInput(
                      nx,
                      hint: '••••••••',
                      suffix: IconButton(
                        tooltip: _obscure ? 'Show password' : 'Hide password',
                        icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, color: nx.muted, size: 20),
                        onPressed: _busy ? null : () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  if (_error != null) ...[const SizedBox(height: 12), NxNoticeBanner(_error!, error: true)],
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      key: const ValueKey('google-link-submit'),
                      onPressed: _busy ? () {} : _submit,
                      style: NxButtonStyle.solid(nx),
                      child: _busy
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.5, color: nx.onButton),
                            )
                          : const Text('Connect Google'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _link('Cancel', const ValueKey('google-link-cancel'), _cancel, nx),
                      _link('Forgot password?', const ValueKey('google-link-forgot'), _forgot, nx),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
