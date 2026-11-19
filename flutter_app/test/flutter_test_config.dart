import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/token_store.dart';

import 'support/fake_biometric_service.dart';
import 'support/fake_secure_store.dart';

/// Runs before every test file: each test starts with an empty fake Keychain,
/// fake Face ID and a token store that loads on first use (so a test's own
/// `SharedPreferences.setMockInitialValues({'nexus_token': ...})` in setUp
/// is picked up through the migration path).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() => TokenStore.resetForTest(store: MemorySecureStore(), biometrics: FakeBiometricService()));
  await testMain();
}
