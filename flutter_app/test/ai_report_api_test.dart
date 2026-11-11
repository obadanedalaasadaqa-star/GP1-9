import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/ai_models.dart';
import 'package:nexus_app/core/api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/report_json.dart';

Future<T> withHttp<T>(Future<http.Response> Function(http.Request) handler, Future<T> Function() body) =>
    http.runWithClient(body, () => MockClient(handler));

Future<http.Response> noInternet(http.Request _) async => throw const SocketException('down');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));
  const oneMonth = ReportRequest(ReportPeriod.oneMonth);

  test('SpendingReport.fromJson and a round trip', () {
    final r = SpendingReport.fromJson(reportJson());
    expect(r.range.label, '1 – 11 Nov 2026');
    expect(r.totals.total, 287.99);
    expect(r.totals.receipts, 7);
    expect(r.comparison.changePercent, isNull);
    expect(r.comparison.changeLabel, 'New');
    expect(r.byCategory.first.sharePercent, 31);
    expect(r.byMonth.single.partial, isTrue);
    expect(r.biggestReceipts.single.date.isUtc, isFalse);
    expect(r.ai.status, ReportAiStatus.ready);
    expect(r.ai.tips, ['Plan big purchases.']);
    final again = SpendingReport.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
    expect(jsonEncode(again.toJson()), jsonEncode(r.toJson()));

    expect(SpendingReport.fromJson(reportJson(ai: {'status': 'unavailable', 'error': 'x'})).ai.error, 'x');
    expect(SpendingReport.fromJson(reportJson(ai: {'status': 'not_enough_data', 'receiptCount': 1, 'minReceipts': 3}))
        .ai.status, ReportAiStatus.notEnoughData);
  });

  test('ReportRequest.toQuery and cacheKey', () {
    expect(oneMonth.toQuery(180), {'period': '1m', 'tzOffsetMinutes': '180'});
    expect(oneMonth.cacheKey, '1m');
    final custom = ReportRequest(ReportPeriod.custom, from: DateTime(2026, 9, 1), to: DateTime(2026, 10, 15));
    expect(custom.toQuery(180), {'period': 'custom', 'from': '2026-09-01', 'to': '2026-10-15', 'tzOffsetMinutes': '180'});
    expect(custom.cacheKey, 'custom:2026-09-01:2026-10-15');
  });

  test('loadReport: 200 saves under its key; offline same key; other key unreachable; JSON 400 rethrown', () async {
    late Uri seen;
    final fresh = await withHttp((req) async {
      seen = req.url;
      return utf8Json(reportJson());
    }, () => ApiClient.loadReport(oneMonth));
    expect(seen.path.endsWith('/ai/report'), isTrue);
    expect(seen.queryParameters['period'], '1m');
    expect(fresh.offline, isFalse);

    final off = await withHttp(noInternet, () => ApiClient.loadReport(oneMonth));
    expect(off.offline, isTrue);
    expect(off.report.totals.total, 287.99);

    await expectLater(withHttp(noInternet, () => ApiClient.loadReport(const ReportRequest(ReportPeriod.threeMonths))),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', contains("Can't reach"))));

    await expectLater(
      withHttp((_) async => http.Response(jsonEncode({'error': 'Reports can cover at most 2 years.'}), 400),
          () => ApiClient.loadReport(oneMonth)),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Reports can cover at most 2 years.')),
    );
  });

  test('emailReport returns the message; 403 rethrown with the server text', () async {
    late Map<String, dynamic> body;
    final msg = await withHttp((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'message': 'Report sent to u1@nexus.test.'}), 200);
    }, () => ApiClient.emailReport(oneMonth));
    expect(msg, 'Report sent to u1@nexus.test.');
    expect(body['period'], '1m');
    expect(body['tzOffsetMinutes'], isA<int>());

    await expectLater(
      withHttp((_) async => http.Response(jsonEncode({'error': 'Verify your email first to get reports by email.'}), 403),
          () => ApiClient.emailReport(oneMonth)),
      throwsA(isA<ApiException>()
          .having((e) => e.message, 'message', 'Verify your email first to get reports by email.')
          .having((e) => e.statusCode, 'statusCode', 403)),
    );
  });

  test('emailReport waits as long as a report (60 s), not the 15 s default', () async {
    expect(ApiClient.emailReportTimeout, const Duration(seconds: 60));
    Future<http.Response> slow(http.Request _) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return http.Response(jsonEncode({'message': 'Report sent.'}), 200);
    }

    await expectLater(
      withHttp(slow, () => ApiClient.emailReport(oneMonth, timeout: const Duration(milliseconds: 50))),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('Check your inbox'))),
    );
    expect(await withHttp(slow, () => ApiClient.emailReport(oneMonth)), 'Report sent.');
  });
}
