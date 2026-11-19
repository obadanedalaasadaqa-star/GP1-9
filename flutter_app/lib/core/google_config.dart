import 'package:flutter/services.dart';

import 'biometric_service.dart' show isIosPlatform;

/// Native channel (AppDelegate.swift) with one read-only method: the iOS
/// Google client ID that Xcode copied into Info.plist from the gitignored
/// `ios/Flutter/GoogleSignIn.xcconfig`. The ID is never in the Dart code.
const _channel = MethodChannel('nexus/config');

/// A real iOS client ID: digits, a dash, lowercase letters and digits, then
/// `.apps.googleusercontent.com`. Nothing is trimmed, so an empty value, the
/// example placeholder, an unexpanded `$(GOOGLE_IOS_CLIENT_ID)` or a value
/// with a stray space all count as "not configured".
final _clientIdPattern = RegExp(r'^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$');

/// True only for a value that looks like a real iOS client ID (S37).
bool isValidGoogleIosClientId(String? id) => id != null && _clientIdPattern.hasMatch(id);

/// The client ID from Info.plist, or null when not on iOS or when the channel
/// fails in any way (tests, an old build). Never throws, never trims.
Future<String?> loadGoogleIosClientId() async {
  if (!isIosPlatform) return null;
  try {
    return await _channel.invokeMethod<String>('googleClientId');
  } catch (_) {
    return null;
  }
}
