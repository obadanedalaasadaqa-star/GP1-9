import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/ai_models.dart';
import 'package:nexus_app/core/comparison_labels.dart';

ReportRange range(String period, {int days = 16}) =>
    ReportRange(period: period, from: '2026-11-01', to: '2026-11-16', label: '1 – 16 Nov 2026', days: days);

const previous = ReportRange(period: '', from: '2026-10-01', to: '2026-10-16', label: '1 – 16 Oct 2026', days: 0);

void main() {
  group('trendsVsLabel', () {
    test('month in progress: vs all of the previous month', () {
      expect(trendsVsLabel(previousMonth: 'October', monthInProgress: true), 'vs all of October');
    });
    test('finished month: vs the previous month', () {
      expect(trendsVsLabel(previousMonth: 'October', monthInProgress: false), 'vs October');
    });
  });

  group('reportComparedWith', () {
    test('1m: same days last month', () {
      expect(reportComparedWith(range('1m'), previous),
          'compared with 1 – 16 Oct 2026 (same days last month)');
    });
    test('3m and 6m: same days, N months earlier', () {
      expect(reportComparedWith(range('3m'), previous),
          'compared with 1 – 16 Oct 2026 (same days, 3 months earlier)');
      expect(reportComparedWith(range('6m'), previous),
          'compared with 1 – 16 Oct 2026 (same days, 6 months earlier)');
    });
    test('1y: same days, a year earlier', () {
      expect(reportComparedWith(range('1y'), previous),
          'compared with 1 – 16 Oct 2026 (same days, a year earlier)');
    });
    test('custom 16 days: the 16 days before', () {
      expect(reportComparedWith(range('custom'), previous),
          'compared with 1 – 16 Oct 2026 (the 16 days before)');
    });
    test('custom 1 day: the day before', () {
      expect(reportComparedWith(range('custom', days: 1), previous),
          'compared with 1 – 16 Oct 2026 (the day before)');
    });
  });
}
