import 'package:flutter/material.dart';

/// Closes the keyboard when the user taps anywhere no button or field claims.
///
/// Wrapped around the whole app (`NexusApp.appBuilder`), so it also covers
/// dialogs and bottom sheets. A tap on a button, field or toggle still goes to
/// that widget (the deepest tap wins), so the eye toggle keeps the keyboard up.
/// It only unfocuses: no state, no field text, no other side effect.
class DismissKeyboard extends StatelessWidget {
  final Widget child;
  const DismissKeyboard({super.key, required this.child});

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        // Keeps VoiceOver from reading the whole app as one button.
        excludeFromSemantics: true,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: child,
      );
}
