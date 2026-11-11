import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/ai_models.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:nexus_app/core/offline_cache.dart';
import 'package:nexus_app/core/trends.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

const readyJson = {
  'status': 'ready',
  'summary': 'You spent 287.99 JD so far this month.',
  'tip': 'Keep an eye on Electronics.',
  'createdAt': '2026-11-11T09:00:00.000Z',
  'cached': false,
};

Future<T> withHttp<T>(Future<http.Response> Function(http.Request) handler, Future<T> Function() body) =>
    http.runWithClient(body, () => MockClient(handler));

Future<http.Response> noInternet(http.Request _) async => throw const SocketException('Failed host lookup');

User user(String id) => User(
    id: id, email: '$id@nexus.test', name: 'A B', firstName: 'A', lastName: 'B',
    serialNumber: 'NXS-AAAAA-BBBBB', loyaltyPoints: 0, createdAt: DateTime.utc(2026, 1, 1));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));
  final bounds = monthBounds(DateTime.now());

  group('models', () {
    test('Insight.fromJson ready (local createdAt) and not_enough_data; round trip', () {
      final ready = Insight.fromJson(readyJson);
      expect(ready.status, InsightStatus.ready);
      expect(ready.summary, 'You spent 287.99 JD so far this month.');
      expect(ready.createdAt!.isUtc, isFalse);
      expect(ready.createdAt!.toUtc(), DateTime.utc(2026, 11, 11, 9));
      final again = Insight.fromJson(ready.toJson());
      expect(again.tip, ready.tip);
      expect(again.createdAt, ready.createdAt);

      final few = Insight.fromJson({'status': 'not_enough_data', 'receiptCount': 2, 'minReceipts': 3});
      expect(few.status, InsightStatus.notEnoughData);
      expect(Insight.fromJson(few.toJson()).receiptCount, 2);
    });

    test('an unknown status throws FormatException', () {
      expect(() => Insight.fromJson({'status': 'weird'}), throwsFormatException);
    });

    test('ChatMessage builds and gives the history item', () {
      const m = ChatMessage(role: ChatRole.user, text: 'Hi');
      expect(m.isError, isFalse);
      expect(m.toHistoryJson(), {'role': 'user', 'text': 'Hi'});
      expect(const ChatMessage(role: ChatRole.assistant, text: 'x').toHistoryJson()['role'], 'assistant');
    });
  });

  group('loadInsight', () {
    test('200 saves; path and bounds as Trends', () async {
      late Uri seen;
      final r = await withHttp((req) async {
        seen = req.url;
        return http.Response(jsonEncode(readyJson), 200);
      }, () => ApiClient.loadInsight(bounds));
      expect(seen.path.endsWith('/ai/insight'), isTrue);
      expect(seen.queryParameters['bounds'], bounds.map((b) => b.toUtc().toIso8601String()).join(','));
      expect(r.offline, isFalse);
      expect(r.stale, isFalse);
      expect((await OfflineCache.loadInsight())!.summary, readyJson['summary']);
    });

    test('no internet or an HTML 502: the saved insight, offline', () async {
      await withHttp((_) async => http.Response(jsonEncode(readyJson), 200), () => ApiClient.loadInsight(bounds));
      final off = await withHttp(noInternet, () => ApiClient.loadInsight(bounds));
      expect(off.offline, isTrue);
      expect(off.savedAt, isNotNull);
      expect(off.insight.summary, readyJson['summary']);
      final html = await withHttp((_) async => http.Response('<html>Bad gateway</html>', 502),
          () => ApiClient.loadInsight(bounds));
      expect(html.offline, isTrue);
    });

    test('JSON 502 and 401 are rethrown', () async {
      await withHttp((_) async => http.Response(jsonEncode(readyJson), 200), () => ApiClient.loadInsight(bounds));
      for (final code in [502, 401]) {
        await expectLater(
          withHttp((_) async => http.Response(jsonEncode({'error': 'Nope $code'}), code), () => ApiClient.loadInsight(bounds)),
          throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Nope $code')),
        );
      }
    });

    test('offline with nothing saved: the unreachable message', () async {
      await expectLater(
        withHttp(noInternet, () => ApiClient.loadInsight(bounds)),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', contains("Can't reach the Nexus server"))),
      );
    });

    test('slow server: saved insight with stale, or a 408 with nothing saved', () async {
      Future<http.Response> slow(http.Request _) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return http.Response(jsonEncode(readyJson), 200);
      }
      await expectLater(
        withHttp(slow, () => ApiClient.loadInsight(bounds, timeout: const Duration(milliseconds: 50))),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 408)),
      );
      await withHttp((_) async => http.Response(jsonEncode(readyJson), 200), () => ApiClient.loadInsight(bounds));
      final r = await withHttp(slow, () => ApiClient.loadInsight(bounds, timeout: const Duration(milliseconds: 50)));
      expect(r.stale, isTrue);
      expect(r.offline, isFalse);
    });
  });

  group('cache keys', () {
    Future<void> saveAll() async {
      await OfflineCache.saveInsight(Insight.fromJson(readyJson));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('nexus_cache_report', '{"key":"1m","report":{}}');
      await prefs.setString('nexus_cache_report_saved_at', DateTime.now().toIso8601String());
    }

    test('another account signing in removes insight and report', () async {
      await OfflineCache.saveUser(user('a'));
      await saveAll();
      await OfflineCache.saveUser(user('a'));
      expect(await OfflineCache.loadInsight(), isNotNull);
      await OfflineCache.saveUser(user('b'));
      expect(await OfflineCache.loadInsight(), isNull);
      final prefs = await SharedPreferences.getInstance();
      for (final k in ['nexus_cache_insight', 'nexus_cache_insight_saved_at', 'nexus_cache_report', 'nexus_cache_report_saved_at']) {
        expect(prefs.containsKey(k), isFalse, reason: k);
      }
    });

    test('clear() removes them too', () async {
      await saveAll();
      await OfflineCache.clear();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.contains('insight') || k.contains('report')), isEmpty);
    });
  });

  group('askAi', () {
    final history = [
      const ChatMessage(role: ChatRole.user, text: 'Hi'),
      const ChatMessage(role: ChatRole.assistant, text: 'Hello'),
    ];

    test('JSON body; 200 gives answer and remainingToday', () async {
      late Map<String, dynamic> body;
      late http.Request seen;
      final r = await withHttp((req) async {
        seen = req;
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'answer': 'So far 287.99 JD.', 'toolsUsed': [], 'remainingToday': 4}), 200);
      }, () => ApiClient.askAi('How much?', history));
      expect(seen.method, 'POST');
      expect(seen.url.path.endsWith('/ai/chat'), isTrue);
      expect(body['question'], 'How much?');
      expect(body['history'], [{'role': 'user', 'text': 'Hi'}, {'role': 'assistant', 'text': 'Hello'}]);
      expect(body['tzOffsetMinutes'], isA<int>());
      expect(body['tzOffsetMinutes'], DateTime.now().timeZoneOffset.inMinutes);
      expect(r.answer, 'So far 287.99 JD.');
      expect(r.remainingToday, 4);
    });

    test('JSON 429 rethrown with the server text; timeout 408; no internet not fromServer', () async {
      await expectLater(
        withHttp((_) async => http.Response(jsonEncode({'error': 'Too many questions.'}), 429),
            () => ApiClient.askAi('q', const [])),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', 'Too many questions.')
            .having((e) => e.statusCode, 'statusCode', 429)
            .having((e) => e.fromServer, 'fromServer', true)),
      );
      await expectLater(
        withHttp((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return http.Response('{}', 200);
        }, () => ApiClient.askAi('q', const [], timeout: const Duration(milliseconds: 50))),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 408)),
      );
      await expectLater(
        withHttp(noInternet, () => ApiClient.askAi('q', const [])),
        throwsA(isA<ApiException>().having((e) => e.fromServer, 'fromServer', false)),
      );
    });
  });
}
