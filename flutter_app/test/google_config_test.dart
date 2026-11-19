import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/google_config.dart';

// Phase 12, A7 (S37): the client ID check and the loader never throw.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('A7 only a real-looking iOS client ID is valid (nothing trimmed)', () {
    const invalid = <String?>[
      null,
      '',
      'paste-client-id-here.apps.googleusercontent.com',
      r'$(GOOGLE_IOS_CLIENT_ID)',
      'x.apps.googleusercontent.com',
      '123-abc.apps.example.com',
      ' 123-abc.apps.googleusercontent.com',
      '123-abc.apps.googleusercontent.com ',
      '123-ABC.apps.googleusercontent.com',
      '123-abc.apps.googleusercontent.com\n',
    ];
    for (final id in invalid) {
      expect(isValidGoogleIosClientId(id), isFalse, reason: '$id');
    }
    expect(isValidGoogleIosClientId('123-abc.apps.googleusercontent.com'), isTrue);
  });

  test('A7 loadGoogleIosClientId: null on Android, without asking the channel', () async {
    var asked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('nexus/config'), (_) async {
      asked = true;
      return '123-abc.apps.googleusercontent.com';
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(await loadGoogleIosClientId(), isNull);
    expect(asked, isFalse);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nexus/config'), null);
  });

  test('A7 on iOS: the value as is; MissingPluginException or an error → null', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('nexus/config');
    // No handler: MissingPluginException.
    messenger.setMockMethodCallHandler(channel, null);
    expect(await loadGoogleIosClientId(), isNull);

    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'googleClientId');
      return ' 123-abc.apps.googleusercontent.com';
    });
    expect(await loadGoogleIosClientId(), ' 123-abc.apps.googleusercontent.com'); // not trimmed

    messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'x'));
    expect(await loadGoogleIosClientId(), isNull);
    messenger.setMockMethodCallHandler(channel, null);
  });
}
