import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/period.dart';

void main() {
  // Saturday 7 Nov 2026, mid-afternoon
  final now = DateTime(2026, 11, 7, 15, 30);

  group('Period.containing', () {
    test('day covers midnight to midnight', () {
      final p = Period.containing(PeriodType.day, now);
      expect(p.start, DateTime(2026, 11, 7));
      expect(p.end, DateTime(2026, 11, 8));
    });

    test('week runs Sunday to Saturday', () {
      final p = Period.containing(PeriodType.week, now);
      expect(p.start, DateTime(2026, 11, 1)); // Sunday
      expect(p.lastDay, DateTime(2026, 11, 7)); // Saturday
    });

    test('week containing a Sunday starts that Sunday', () {
      final p = Period.containing(PeriodType.week, DateTime(2026, 11, 8));
      expect(p.start, DateTime(2026, 11, 8));
    });

    test('month and year', () {
      final m = Period.containing(PeriodType.month, now);
      expect(m.start, DateTime(2026, 11, 1));
      expect(m.end, DateTime(2026, 12, 1));
      final y = Period.containing(PeriodType.year, now);
      expect(y.start, DateTime(2026));
      expect(y.end, DateTime(2027));
    });
  });

  group('Period.shift', () {
    test('day back crosses month boundary', () {
      final p = Period.containing(PeriodType.day, DateTime(2026, 11, 1)).shift(-1);
      expect(p.start, DateTime(2026, 10, 31));
    });

    test('week back by one', () {
      final p = Period.containing(PeriodType.week, now).shift(-1);
      expect(p.start, DateTime(2026, 10, 25));
      expect(p.end, DateTime(2026, 11, 1));
    });

    test('month back crosses year boundary', () {
      final p = Period.containing(PeriodType.month, DateTime(2026, 1, 15)).shift(-1);
      expect(p.start, DateTime(2025, 12, 1));
      expect(p.end, DateTime(2026, 1, 1));
    });

    test('custom range does not move', () {
      final p = Period.custom(DateTime(2026, 5, 1), DateTime(2026, 6, 30));
      expect(p.shift(-1).start, p.start);
    });
  });

  group('Period.isLatest', () {
    test('current periods are latest, past ones are not', () {
      for (final t in [PeriodType.day, PeriodType.week, PeriodType.month, PeriodType.year]) {
        final p = Period.containing(t, now);
        expect(p.isLatest(now), isTrue, reason: '$t');
        expect(p.shift(-1).isLatest(now), isFalse, reason: '$t');
      }
    });
  });

  group('Period.custom', () {
    test('includes both the first and last day', () {
      final p = Period.custom(DateTime(2026, 5, 31, 18), DateTime(2026, 6, 23, 9));
      expect(p.start, DateTime(2026, 5, 31));
      expect(p.end, DateTime(2026, 6, 24));
    });
  });

  group('Period.label', () {
    test('day labels', () {
      final today = Period.containing(PeriodType.day, now);
      expect(today.label(now), 'Today');
      expect(today.shift(-1).label(now), 'Yesterday');
      expect(today.shift(-2).label(now), 'Thu, 5 Nov 2026');
    });

    test('week, month, year labels', () {
      expect(Period.containing(PeriodType.week, now).label(now), '1 – 7 Nov 2026');
      expect(Period.containing(PeriodType.week, DateTime(2026, 12, 1)).label(now),
        '29 Nov – 5 Dec 2026');
      expect(Period.containing(PeriodType.month, now).label(now), 'November 2026');
      expect(Period.containing(PeriodType.year, now).label(now), '2026');
    });

    test('custom range spanning years', () {
      final p = Period.custom(DateTime(2025, 12, 28), DateTime(2026, 1, 3));
      expect(p.label(now), '28 Dec 2025 – 3 Jan 2026');
    });
  });
}
