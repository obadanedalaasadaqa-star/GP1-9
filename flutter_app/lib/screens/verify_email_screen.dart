import 'package:flutter/material.dart';
import 'verify_code_screen.dart';

/// Opens the code screen in email mode. Kept so the existing callers don't
/// change; the screen itself lives in verify_code_screen.dart.
class VerifyEmailScreen {
  VerifyEmailScreen._();

  static Future<void> open(BuildContext context, {bool sendOnOpen = true}) =>
      VerifyCodeScreen.openEmail(context, sendOnOpen: sendOnOpen);
}
