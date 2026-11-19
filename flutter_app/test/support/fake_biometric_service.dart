import 'dart:async';

import 'package:nexus_app/core/biometric_service.dart';
import 'package:nexus_app/core/token_store.dart';

/// Scripted Face ID for tests. Usable Face ID by default (the iOS paths are
/// still gated by the platform, which tests set to iOS explicitly).
class FakeBiometricService implements BiometricService {
  BiometricAvailability current = const BiometricAvailability.usable();
  BioOutcome nextConfirm = BioOutcome.success;

  /// Holds [confirm] until completed (the prompt is up).
  Completer<void>? holdConfirm;
  int confirmCount = 0;
  final reasons = <String>[];

  @override
  Future<BiometricAvailability> availability() async => current;

  @override
  Future<BioOutcome> confirm(String reason) async {
    confirmCount++;
    reasons.add(reason);
    final hold = holdConfirm;
    if (hold != null) await hold.future;
    return nextConfirm;
  }
}

/// The fake biometrics the current test runs with (set by flutter_test_config).
FakeBiometricService get fakeBiometrics => TokenStore.biometrics as FakeBiometricService;
