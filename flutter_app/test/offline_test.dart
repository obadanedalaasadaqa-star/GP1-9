import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:nexus_app/core/receipt_model.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

User user(String id) => User(
      id: id, email: '$id@nexus.test', name: 'Obada Test', firstName: 'Obada',
      lastName: 'Test', serialNumber: 'NXS-AAAAA-BBBBB', loyaltyPoints: 12,
      createdAt: DateTime.utc(2026, 1, 1));

Receipt receipt(String id, DateTime date) => Receipt(
      id: id, storeName: 'Carrefour', category: 'Supermarket',
      totalAmount: 5.5, items: ['Milk x1'], date: date, pointsEarned: 5);

Map<String, dynamic> receiptJson(String id, DateTime date) => receipt(id, date).toJson();

/// Runs [body] with every HTTP call answered by [handler].
Future<T> withHttp<T>(Future<http.Response> Function(http.Request) handler,
        Future<T> Function() body) =>
    http.runWithClient(body, () => MockClient(handler));

Future<http.Response> noInternet(http.Request _) async =>
    throw const SocketException('Failed host lookup');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final nov3 = DateTime.utc(2026, 11, 3);
  final oct5 = DateTime.utc(2026, 10, 5);
  final novStart = DateTime.utc(2026, 11, 1), decStart = DateTime.utc(2026, 12, 1);

  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  test('receipts and users survive a JSON round trip', () {
    final r = receipt('r1', nov3);
    final back = Receipt.fromJson(r.toJson());
    expect([back.id, back.storeName, back.totalAmount, back.items, back.date, back.pointsEarned],
        [r.id, r.storeName, r.totalAmount, r.items, r.date, r.pointsEarned]);
    final u = user('u1');
    final ub = User.fromJson(u.toJson());
    expect([ub.id, ub.serialNumber, ub.loyaltyPoints, ub.firstName, ub.createdAt],
        [u.id, u.serialNumber, u.loyaltyPoints, u.firstName, u.createdAt]);
  });

  test('online: receipts are returned and saved on the phone', () async {
    final res = await withHttp(
        (_) async => http.Response(jsonEncode([receiptJson('r1', nov3)]), 200),
        () => ApiClient.loadReceipts(from: novStart, to: decStart));
    expect(res.offline, isFalse);
    expect(res.receipts.single.id, 'r1');
    expect((await OfflineCache.loadReceipts(from: novStart, to: decStart))!.single.id, 'r1');
  });

  test('offline: the saved receipts for the period are shown', () async {
    await OfflineCache.saveReceipts([receipt('r1', nov3), receipt('r2', oct5)]);
    final res = await withHttp(noInternet,
        () => ApiClient.loadReceipts(from: novStart, to: decStart));
    expect(res.offline, isTrue);
    expect(res.savedAt, isNotNull);
    expect(res.receipts.map((r) => r.id), ['r1']);
  });

  test('offline with nothing saved: a friendly error, not the raw exception', () async {
    await expectLater(
      withHttp(noInternet, () => ApiClient.loadReceipts()),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', contains("Can't reach"))),
    );
  });

  test('a real server error (401) is not hidden by the cache', () async {
    await OfflineCache.saveReceipts([receipt('r1', nov3)]);
    await expectLater(
      withHttp((_) async => http.Response(jsonEncode({'error': 'Invalid or expired token.'}), 401),
          () => ApiClient.loadReceipts()),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
    );
  });

  test('a period fetch replaces the saved receipts in that period', () async {
    await OfflineCache.saveReceipts([receipt('gone', nov3), receipt('r2', oct5)]);
    await OfflineCache.saveReceipts([receipt('r1', nov3)], from: novStart, to: decStart);
    final all = await OfflineCache.loadReceipts();
    expect(all!.map((r) => r.id), ['r1', 'r2']);
  });

  test('another account signing in wipes the saved receipts', () async {
    await OfflineCache.saveUser(user('u1'));
    await OfflineCache.saveReceipts([receipt('r1', nov3)]);
    await OfflineCache.saveUser(user('u2'));
    expect(await OfflineCache.loadReceipts(), isNull);
  });

  Future<AuthProvider> start(Future<http.Response> Function(http.Request) handler) =>
      withHttp(handler, () async {
        final auth = AuthProvider();
        while (auth.loading) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        return auth;
      });

  test('app opens offline with the saved profile', () async {
    await OfflineCache.saveUser(user('u1'));
    final auth = await start(noInternet);
    expect(auth.isLoggedIn, isTrue);
    expect(auth.offline, isTrue);
    expect(auth.startupError, isNull);
    expect(auth.user!.loyaltyPoints, 12);
  });

  test('no saved profile and no internet: the Retry screen as before', () async {
    final auth = await start(noInternet);
    expect(auth.isLoggedIn, isFalse);
    expect(auth.startupError, isNotNull);
  });

  test('online startup saves the profile; logout clears everything', () async {
    final auth = await start((_) async => http.Response(jsonEncode(user('u1').toJson()), 200));
    expect(auth.offline, isFalse);
    expect((await OfflineCache.loadUser())!.id, 'u1');
    await OfflineCache.saveReceipts([receipt('r1', nov3)]);
    await auth.logout();
    expect(await OfflineCache.loadUser(), isNull);
    expect(await OfflineCache.loadReceipts(), isNull);
  });
}
