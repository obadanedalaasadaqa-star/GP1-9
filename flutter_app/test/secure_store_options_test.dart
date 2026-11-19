import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:nexus_app/core/biometric_service.dart';
import 'package:nexus_app/core/secure_store.dart';

void main() {
  test('X1 (S1) both Keychain items stay on this phone only', () {
    const plain = KeychainSecureStore.plainOptions;
    const protected = KeychainSecureStore.protectedOptions;

    expect(plain.accessibility, KeychainAccessibility.first_unlock_this_device);
    expect(plain.accessControlFlags, isEmpty);
    expect(plain.synchronizable, isFalse);
    expect(plain.groupId, isNull);

    expect(protected.accessibility, KeychainAccessibility.passcode);
    expect(protected.accessControlFlags, [AccessControlFlag.biometryCurrentSet]);
    expect(protected.synchronizable, isFalse);
    expect(protected.groupId, isNull);
    expect(protected.useSecureEnclave, isFalse);
  });

  test('Keychain OSStatus codes map to read outcomes (unknown is error)', () {
    expect(protectedStatusFor(-128), ProtectedStatus.cancelled);
    expect(protectedStatusFor(-25293), ProtectedStatus.failed);
    expect(protectedStatusFor(-25300), ProtectedStatus.invalidated);
    expect(protectedStatusFor(-25291), ProtectedStatus.notAvailable);
    expect(protectedStatusFor(-25308), ProtectedStatus.error);
    expect(protectedStatusFor(null), ProtectedStatus.error);
    expect(protectedStatusFor('x'), ProtectedStatus.error);
  });

  test('the iOS status channel answer maps to availability reasons', () {
    expect(availabilityFromStatus('face', null).usable, isTrue);
    expect(availabilityFromStatus('touch', null).kind, BiometricKind.fingerprint);
    expect(availabilityFromStatus('touch', null).name, 'Touch ID');
    expect(availabilityFromStatus('face', -8).reason, BiometricReason.lockout);
    expect(availabilityFromStatus('face', -7).reason, BiometricReason.notEnrolled);
    expect(availabilityFromStatus('face', -5).reason, BiometricReason.noPasscode);
    expect(availabilityFromStatus('face', -6).reason, BiometricReason.turnedOffForApp);
    expect(availabilityFromStatus('none', -6).reason, BiometricReason.noHardware);
    expect(availabilityFromStatus('none', null).usable, isFalse);
    // Codes we don't know are "unknown", never "no hardware" (it deletes).
    expect(availabilityFromStatus('face', -99).reason, BiometricReason.unknown);
    expect(availabilityFromStatus('face', -99).kind, BiometricKind.face);
    expect(availabilityFromStatus('touch', -1).reason, BiometricReason.unknown);
    expect(availabilityFromStatus('none', -99).reason, BiometricReason.unknown);
  });

  test('local_auth errors map to confirm outcomes', () {
    expect(bioOutcomeFor(LocalAuthExceptionCode.userCanceled), BioOutcome.cancelled);
    expect(bioOutcomeFor(LocalAuthExceptionCode.systemCanceled), BioOutcome.cancelled);
    expect(bioOutcomeFor(LocalAuthExceptionCode.biometricLockout), BioOutcome.lockout);
    expect(bioOutcomeFor(LocalAuthExceptionCode.temporaryLockout), BioOutcome.lockout);
    expect(bioOutcomeFor(LocalAuthExceptionCode.noBiometricsEnrolled), BioOutcome.notAvailable);
    expect(bioOutcomeFor(LocalAuthExceptionCode.unknownError), BioOutcome.error);
  });

  test('off iOS, availability is notIos (S21)', () async {
    expect(isIosPlatform, isFalse); // flutter test runs as Android by default
    expect((await LocalAuthBiometricService().availability()).reason, BiometricReason.notIos);
  });
}
