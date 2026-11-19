import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Face ID is an iOS-only feature this phase (Android gets the Keychain-style
/// storage and nothing else). Tests set `debugDefaultTargetPlatformOverride`.
bool get isIosPlatform => defaultTargetPlatform == TargetPlatform.iOS;

enum BiometricKind { face, fingerprint, none }

/// Why biometrics can't be used right now. [unknown] means the phone didn't
/// say (a channel error, an `LAError` code we don't know): it never deletes
/// the saved session, the Keychain read decides instead.
enum BiometricReason { noHardware, notEnrolled, noPasscode, turnedOffForApp, lockout, unknown, notIos }

@immutable
class BiometricAvailability {
  final bool usable;
  final BiometricKind kind;
  final BiometricReason? reason;
  const BiometricAvailability({required this.usable, this.kind = BiometricKind.face, this.reason});

  const BiometricAvailability.usable([this.kind = BiometricKind.face])
      : usable = true,
        reason = null;
  const BiometricAvailability.unusable(BiometricReason this.reason, [this.kind = BiometricKind.face])
      : usable = false;

  static const notIos = BiometricAvailability.unusable(BiometricReason.notIos, BiometricKind.none);

  /// "Touch ID" on Touch ID phones, "Face ID" everywhere else.
  String get name => kind == BiometricKind.fingerprint ? 'Touch ID' : 'Face ID';
}

/// What a [BiometricService.confirm] prompt gave.
enum BioOutcome { success, cancelled, failed, lockout, notAvailable, error }

/// Face ID / Touch ID checks. Unlocking never uses [confirm]: reading the
/// protected Keychain item is the Face ID check, so the user sees one prompt.
abstract class BiometricService {
  Future<BiometricAvailability> availability();

  /// A Face ID prompt with no passcode fallback. Used to turn Face ID on
  /// (prove it works before the token moves) and off (S19).
  Future<BioOutcome> confirm(String reason);
}

/// [BiometricService] on `local_auth`, plus a small iOS channel
/// (`AppDelegate.swift`) that says *why* Face ID can't be used, which
/// `local_auth` doesn't expose.
class LocalAuthBiometricService implements BiometricService {
  static const _channel = MethodChannel('nexus/biometry');
  final _auth = LocalAuthentication();

  @override
  Future<BiometricAvailability> availability() async {
    if (!isIosPlatform) return BiometricAvailability.notIos;
    try {
      final status = await _channel.invokeMapMethod<String, Object?>('status');
      return availabilityFromStatus(status?['type'] as String?, status?['error'] as int?);
    } catch (_) {
      // Channel missing: fall back to what local_auth can tell.
      try {
        final enrolled = await _auth.getAvailableBiometrics();
        if (enrolled.contains(BiometricType.face)) return const BiometricAvailability.usable();
        if (enrolled.contains(BiometricType.fingerprint)) {
          return const BiometricAvailability.usable(BiometricKind.fingerprint);
        }
        if (!await _auth.isDeviceSupported()) {
          return const BiometricAvailability.unusable(BiometricReason.noPasscode);
        }
        // An empty list can also mean locked out or turned off for Nexus:
        // local_auth can't say which, so don't guess "not set up".
        return const BiometricAvailability.unusable(BiometricReason.unknown);
      } catch (_) {
        return const BiometricAvailability.unusable(BiometricReason.unknown);
      }
    }
  }

  @override
  Future<BioOutcome> confirm(String reason) async {
    try {
      final ok = await _auth.authenticate(localizedReason: reason, biometricOnly: true);
      return ok ? BioOutcome.success : BioOutcome.failed;
    } on LocalAuthException catch (e) {
      return bioOutcomeFor(e.code);
    } catch (_) {
      return BioOutcome.error;
    }
  }
}

/// The channel answers with the biometry type and the `LAError` code of
/// `canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` (null = usable).
@visibleForTesting
BiometricAvailability availabilityFromStatus(String? type, int? laError) {
  final kind = switch (type) {
    'face' => BiometricKind.face,
    'touch' => BiometricKind.fingerprint,
    _ => BiometricKind.none,
  };
  if (laError == null) {
    return kind == BiometricKind.none
        ? const BiometricAvailability.unusable(BiometricReason.noHardware, BiometricKind.none)
        : BiometricAvailability.usable(kind);
  }
  final shown = kind == BiometricKind.none ? BiometricKind.face : kind;
  return switch (laError) {
    -8 => BiometricAvailability.unusable(BiometricReason.lockout, shown), // biometryLockout
    -7 => BiometricAvailability.unusable(BiometricReason.notEnrolled, shown), // biometryNotEnrolled
    -5 => BiometricAvailability.unusable(BiometricReason.noPasscode, shown), // passcodeNotSet
    // biometryNotAvailable: with hardware it means "turned off for this app".
    // It is also returned while Face ID is briefly unavailable, so a cold
    // start doesn't act on it until the Keychain read fails too.
    -6 when kind != BiometricKind.none =>
      BiometricAvailability.unusable(BiometricReason.turnedOffForApp, kind),
    -6 => const BiometricAvailability.unusable(BiometricReason.noHardware, BiometricKind.none),
    _ => BiometricAvailability.unusable(BiometricReason.unknown, shown),
  };
}

@visibleForTesting
BioOutcome bioOutcomeFor(LocalAuthExceptionCode code) => switch (code) {
      LocalAuthExceptionCode.userCanceled ||
      LocalAuthExceptionCode.systemCanceled ||
      LocalAuthExceptionCode.timeout ||
      LocalAuthExceptionCode.userRequestedFallback =>
        BioOutcome.cancelled,
      LocalAuthExceptionCode.biometricLockout || LocalAuthExceptionCode.temporaryLockout => BioOutcome.lockout,
      LocalAuthExceptionCode.noBiometricsEnrolled ||
      LocalAuthExceptionCode.noBiometricHardware ||
      LocalAuthExceptionCode.noCredentialsSet ||
      LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable =>
        BioOutcome.notAvailable,
      _ => BioOutcome.error,
    };
