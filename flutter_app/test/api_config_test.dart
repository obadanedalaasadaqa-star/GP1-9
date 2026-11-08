import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/constants.dart';

void main() {
  // Guards against committing a LAN address (http://192.168...) as the default.
  test('default baseUrl uses HTTPS and ends with /api', () {
    expect(AppConfig.baseUrl, startsWith('https://'));
    expect(AppConfig.baseUrl, endsWith('/api'));
  });

  test('socketUrl uses HTTPS and has no /api', () {
    expect(AppConfig.socketUrl, startsWith('https://'));
    expect(AppConfig.socketUrl, isNot(endsWith('/api')));
    expect(AppConfig.socketUrl, isNot(endsWith('/')));
  });
}
