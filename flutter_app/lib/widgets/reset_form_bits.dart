import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/constants.dart';
import '../core/design.dart';

/// Shared pieces of the two forgot-password screens: the edit-screen frame
/// (`nx.bg` ground, back button, big title, intro) and the error banner,
/// which matches the one on the sign-in sheet.

class ResetFrame extends StatelessWidget {
  final String title;
  final Widget intro;
  final String backTooltip;
  final List<Widget> children;

  const ResetFrame({
    super.key,
    required this.title,
    required this.intro,
    required this.children,
    this.backTooltip = 'Back',
  });

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: nx.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: nx.bg,
        body: SafeArea(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NxBackButton(tooltip: backTooltip),
                const SizedBox(height: 18),
                Text(title, style: NxType.display(36, color: nx.text, height: 1.05)),
                const SizedBox(height: 8),
                intro,
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Field label in the till-slip style (uppercase, 8 above the field).
class ResetLabel extends StatelessWidget {
  final String text;
  const ResetLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text.toUpperCase(), style: NxType.label(Nx.of(context).muted)),
      );
}

/// Coral banner with an ink border and icon (same as the sign-in sheet).
class ResetErrorBanner extends StatelessWidget {
  final String message;
  const ResetErrorBanner(this.message, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: AppColors.coral,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.ink, width: 2),
        ),
        child: Row(children: [
          const Icon(Icons.error_outline, color: AppColors.ink, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message,
            style: NxType.body(13.5, weight: FontWeight.w600, color: AppColors.ink))),
        ]),
      );
}

/// The one action of the screen: a solid 54 pill with a spinner while busy.
class ResetButton extends StatelessWidget {
  final String label;
  final bool loading;
  final VoidCallback onPressed;
  const ResetButton({super.key, required this.label, required this.loading, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: NxButtonStyle.solid(nx),
        child: loading
            ? SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: nx.onButton))
            : Text(label),
      ),
    );
  }
}
