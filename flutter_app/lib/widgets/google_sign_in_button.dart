import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/google_auth_service.dart';

/// "Continue with Google" (design.md section 0). A white (light) or paper
/// (dark) pill with Google's own G, a 2px ink outline and no hard shadow: it
/// is never the screen's one action. The only place the G may appear.
class GoogleSignInButton extends StatelessWidget {
  /// Null: disabled (another sign-in is running), the whole button at 50%.
  final VoidCallback? onPressed;

  /// Google's sheet is up, or Nexus is checking the token: a spinner in
  /// place of the G, the label stays, taps are ignored.
  final bool busy;

  const GoogleSignInButton({super.key, required this.onPressed, this.busy = false});

  static const label = 'Continue with Google';

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    // Google's light fill on the light sheet; its neutral fill (#F2F2F2,
    // within one step of paper) on the dark sheet. Each with the matching G.
    final fill = nx.dark ? AppColors.paper : Colors.white;
    final asset = nx.dark ? 'assets/brand/google_g_neutral.png' : 'assets/brand/google_g.png';
    final disabled = onPressed == null && !busy;
    final VoidCallback? onTap = disabled ? null : (busy ? () {} : onPressed);

    final button = OutlinedButton(
      key: const ValueKey('google-sign-in'),
      onPressed: onTap,
      style: NxButtonStyle.outline(nx, color: AppColors.ink).copyWith(
        backgroundColor: WidgetStateProperty.all(fill),
        foregroundColor: WidgetStateProperty.all(AppColors.ink),
        side: WidgetStateProperty.all(const BorderSide(color: AppColors.ink, width: 2)),
        // No Material overlay: it would darken the fill around the G's opaque
        // square. Press feedback is the Pressable scale (spec 1.8).
        overlayColor: WidgetStateProperty.all(Colors.transparent),
      ),
      child: Semantics(
        value: busy ? 'Waiting for Google' : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.ink))
            else
              ExcludeSemantics(child: Image.asset(asset, width: 20, height: 20)),
            const SizedBox(width: 10),
            Flexible(
              child: Text(label, maxLines: 2, textAlign: TextAlign.center,
                style: NxType.googleButton(AppColors.ink)),
            ),
          ],
        ),
      ),
    );

    // Its right edge lines up with the shadowed lime pill above it.
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Opacity(
        opacity: disabled ? 0.5 : 1,
        child: Pressable(
          onTap: onTap,
          child: SizedBox(width: double.infinity, child: button),
        ),
      ),
    );
  }
}

/// The banner for a failed Continue with Google (design.md 1.6): the text,
/// and whether it is the coral error tone (true) or the amber "use another
/// way" tone (false).
({String text, bool error}) googleNoticeFor(Object e) {
  if (e is GoogleAuthFailure) {
    return e.kind == GoogleFailureKind.network
        ? (text: "Couldn't reach Google. Check your connection and try again.", error: true)
        : (text: "Google sign-in didn't go through. Try again.", error: true);
  }
  if (e is ApiException) {
    final amber = e.statusCode == 503 ||
        e.code == 'google_email_unverified' ||
        e.code == 'other_google' ||
        e.code == 'email_taken';
    return (text: e.message, error: !amber);
  }
  return (text: "Sign-in didn't go through. Try again.", error: true);
}
