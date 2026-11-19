import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What reading the Face ID protected token gave.
enum ProtectedStatus {
  success,
  /// The user cancelled the Face ID sheet (or the system did).
  cancelled,
  /// Face ID didn't match.
  failed,
  /// Too many tries: iOS has locked Face ID until the phone is unlocked.
  lockout,
  /// The enrolled faces changed (or the item is gone), so it can never be read.
  invalidated,
  /// Face ID is turned off for Nexus in iOS Settings.
  notAvailable,
  /// Anything else.
  error,
}

/// The result of [SecureStore.readProtected]. Only [ProtectedStatus.success]
/// carries a token.
@immutable
class ProtectedRead {
  final ProtectedStatus status;
  final String? token;
  const ProtectedRead(this.status) : token = null;
  const ProtectedRead.success(String this.token) : status = ProtectedStatus.success;
}

/// The phone's Keychain, behind an interface so tests never touch a
/// platform channel.
///
/// - The plain item holds the session token while Face ID is off.
/// - The protected item holds it while Face ID is on. iOS releases it only
///   after a Face ID match (it shows the prompt itself), with no passcode
///   fallback.
abstract class SecureStore {
  Future<String?> readPlain();
  Future<void> writePlain(String token);
  Future<void> deletePlain();

  /// Shows the Face ID prompt. A missing item reads as
  /// [ProtectedStatus.invalidated] (the faces changed or it was removed).
  Future<ProtectedRead> readProtected();

  /// Deletes first, then adds: adding never needs Face ID, updating might.
  /// Throws if the write fails (for example while the phone is locked).
  Future<void> writeProtected(String token);
  Future<void> deleteProtected();

  /// An existence check with no prompt (used to check a write).
  Future<bool> protectedExists();

  /// Removes both items (a reinstall must never bring an old session back).
  Future<void> wipeAll();
}

/// [SecureStore] on the iOS Keychain (and the plugin's Android storage, where
/// only the plain item is ever used).
class KeychainSecureStore implements SecureStore {
  static const _plainKey = 'nexus_token';
  static const _protectedKey = 'nexus_token_bio';

  /// Readable after the first unlock since boot, so token rotation and socket
  /// reconnects work in the background. This device only, no iCloud sync.
  @visibleForTesting
  static const plainOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    synchronizable: false,
  );

  /// Needs a device passcode and the currently enrolled faces. This device
  /// only, no iCloud sync, no access group.
  @visibleForTesting
  static const protectedOptions = IOSOptions(
    accessibility: KeychainAccessibility.passcode,
    accessControlFlags: [AccessControlFlag.biometryCurrentSet],
    synchronizable: false,
  );

  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> readPlain() => _storage.read(key: _plainKey, iOptions: plainOptions);

  @override
  Future<void> writePlain(String token) =>
      _storage.write(key: _plainKey, value: token, iOptions: plainOptions);

  @override
  Future<void> deletePlain() => _storage.delete(key: _plainKey, iOptions: plainOptions);

  @override
  Future<ProtectedRead> readProtected() async {
    try {
      final token = await _storage.read(key: _protectedKey, iOptions: protectedOptions);
      // The plugin answers "not found" with null.
      if (token == null) return const ProtectedRead(ProtectedStatus.invalidated);
      return ProtectedRead.success(token);
    } on PlatformException catch (e) {
      // Only the OSStatus code is looked at: the message and details are
      // never printed (S13).
      return ProtectedRead(protectedStatusFor(e.details));
    } catch (_) {
      return const ProtectedRead(ProtectedStatus.error);
    }
  }

  @override
  Future<void> writeProtected(String token) async {
    await _storage.delete(key: _protectedKey, iOptions: protectedOptions);
    await _storage.write(key: _protectedKey, value: token, iOptions: protectedOptions);
  }

  @override
  Future<void> deleteProtected() => _storage.delete(key: _protectedKey, iOptions: protectedOptions);

  @override
  Future<bool> protectedExists() =>
      _storage.containsKey(key: _protectedKey, iOptions: protectedOptions);

  @override
  Future<void> wipeAll() async {
    await deletePlain();
    await deleteProtected();
  }
}

/// Maps a Keychain OSStatus (the plugin's `details`) to a [ProtectedStatus].
@visibleForTesting
ProtectedStatus protectedStatusFor(Object? osStatus) {
  switch (osStatus) {
    case -128: // errSecUserCanceled
      return ProtectedStatus.cancelled;
    case -25293: // errSecAuthFailed
      return ProtectedStatus.failed;
    case -25300: // errSecItemNotFound
      return ProtectedStatus.invalidated;
    case -25291: // errSecNotAvailable
      return ProtectedStatus.notAvailable;
    default:
      return ProtectedStatus.error;
  }
}
