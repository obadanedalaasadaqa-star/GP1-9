import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/auth_provider.dart';
import '../core/biometric_service.dart';
import '../core/design.dart';
import 'face_id_glyph.dart';
import 'notice_banner.dart';

/// "Use Face ID next time?": offered once after a password sign-in. Opened
/// by the tab shell on its first frame.
class BiometricOfferSheet extends StatefulWidget {
  const BiometricOfferSheet({super.key});

  /// Shows the sheet; on success, closes it and shows the "Face ID is on"
  /// snackbar. Swiping it away is "Not now" this time only (no flag).
  static Future<void> show(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      sheetAnimationStyle: reduceMotion ? AnimationStyle.noAnimation : null,
      builder: (_) => const BiometricOfferSheet(),
    );
  }

  @override
  State<BiometricOfferSheet> createState() => _BiometricOfferSheetState();
}

class _BiometricOfferSheetState extends State<BiometricOfferSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _enable() async {
    if (_busy) return;
    final auth = context.read<AuthProvider>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final name = auth.biometricName;
    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await auth.enableBiometrics();
    if (!mounted) return;
    if (outcome == BioOutcome.success) {
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('$name is on. Next time, just look at your iPhone.')));
      return;
    }
    setState(() {
      _busy = false;
      _error = outcome == BioOutcome.lockout
          ? '$name is locked. Unlock your iPhone, then turn it on in Profile.'
          : "$name didn't go through. Try again, or choose Not now.";
    });
  }

  void _later() {
    if (_busy) return;
    context.read<AuthProvider>().declineBiometricOffer();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final name = context.read<AuthProvider>().biometricName;
    final touch = name == 'Touch ID';
    return PopScope(
      canPop: !_busy,
      // While the prompt is up, a drag on the sheet is taken here, so the
      // sheet can't be swiped away.
      child: GestureDetector(
        onVerticalDragStart: _busy ? (_) {} : null,
        onVerticalDragUpdate: _busy ? (_) {} : null,
        onVerticalDragEnd: _busy ? (_) {} : null,
        child: NxSheet(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              touch
                  ? ExcludeSemantics(child: Icon(Icons.fingerprint, size: 56, color: nx.text))
                  : FaceIdGlyph(size: 56, color: nx.text),
              const SizedBox(height: 14),
              Semantics(
                header: true,
                child: Text('Use $name next time?', style: NxType.display(24, color: nx.text)),
              ),
              const SizedBox(height: 6),
              Text(
                'Open Nexus with a glance instead of your password. '
                '$name unlocks the sign-in saved on this iPhone. '
                '${touch ? 'Nexus never sees your fingerprint.' : 'Nexus never sees your face.'}',
                style: NxType.body(14.5, color: nx.muted, height: 1.4),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                NxNoticeBanner(_error!, error: true),
              ],
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const ValueKey('bio-offer-enable'),
                  onPressed: _busy ? () {} : _enable,
                  style: NxButtonStyle.solid(nx),
                  child: _busy
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: nx.onButton))
                      : Text('Use $name'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  key: const ValueKey('bio-offer-later'),
                  onPressed: _busy ? () {} : _later,
                  style: NxButtonStyle.outline(nx),
                  child: const Text('Not now'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
