import 'dart:async';

import 'package:nexus_app/core/secure_store.dart';
import 'package:nexus_app/core/token_store.dart';

/// In-memory [SecureStore] for tests: scripted Face ID answers, counters and
/// "throw on X" switches. Never touches a platform channel.
class MemorySecureStore implements SecureStore {
  String? plain;
  String? protected;

  /// The next [readProtected] answer (used once). Null: the real behaviour
  /// (the token, or "invalidated" when there is none).
  ProtectedStatus? nextProtectedResult;

  /// Holds [readProtected] until completed (a Face ID prompt that's up).
  Completer<void>? holdProtected;

  int readPlainCount = 0;
  int readProtectedCount = 0;
  int writePlainCount = 0;
  int writeProtectedCount = 0;
  int protectedExistsCount = 0;

  /// Every write and delete, in order: 'writePlain', 'deleteProtected', ...
  final ops = <String>[];

  bool throwOnWritePlain = false;
  bool throwOnReadPlain = false;
  bool throwOnDeletePlain = false;
  bool throwOnWriteProtected = false;

  @override
  Future<String?> readPlain() async {
    readPlainCount++;
    if (throwOnReadPlain) throw StateError('readPlain');
    return plain;
  }

  @override
  Future<void> writePlain(String token) async {
    ops.add('writePlain');
    writePlainCount++;
    if (throwOnWritePlain) throw StateError('writePlain');
    plain = token;
  }

  @override
  Future<void> deletePlain() async {
    ops.add('deletePlain');
    if (throwOnDeletePlain) throw StateError('deletePlain');
    plain = null;
  }

  @override
  Future<ProtectedRead> readProtected() async {
    readProtectedCount++;
    // Taken before the hold: the plugin runs Keychain calls on one serial
    // queue, so a write issued while the prompt is up lands after this read.
    final token = protected;
    final hold = holdProtected;
    if (hold != null) await hold.future;
    final scripted = nextProtectedResult;
    nextProtectedResult = null;
    if (scripted != null && scripted != ProtectedStatus.success) return ProtectedRead(scripted);
    return token == null ? const ProtectedRead(ProtectedStatus.invalidated) : ProtectedRead.success(token);
  }

  @override
  Future<void> writeProtected(String token) async {
    // Delete then write, like the Keychain store. Models a write refused
    // while the phone is locked (-25308): the old item is already gone.
    ops.add('deleteProtected');
    protected = null;
    ops.add('writeProtected');
    writeProtectedCount++;
    if (throwOnWriteProtected) throw StateError('writeProtected');
    protected = token;
  }

  @override
  Future<void> deleteProtected() async {
    ops.add('deleteProtected');
    protected = null;
  }

  @override
  Future<bool> protectedExists() async {
    protectedExistsCount++;
    return protected != null;
  }

  @override
  Future<void> wipeAll() async {
    ops.add('wipeAll');
    plain = null;
    protected = null;
  }
}

/// The fake store the current test runs with (set by flutter_test_config).
MemorySecureStore get fakeStore => TokenStore.store as MemorySecureStore;
