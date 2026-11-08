import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/period.dart';
import 'package:nexus_app/core/stats_model.dart';
import 'package:nexus_app/core/trends.dart';

PeriodStats period(DateTime from, {double total = 0, int count = 0,
    List<CategoryStat> cats = const [], StoreStat? top}) =>
  PeriodStats(
    from: from,
    to: DateTime(from.year, from.month + 1),
    total: total,
    count: count,
    average: count == 0 ? 0 : total / count,
    byCategory: cats,
    topStore: top,
  );

void main() {
  group('monthBounds (done-when, app side)', () {
    // The Archive's "Month" periods for the same 6 months.
    List<DateTime> archiveMonths(DateTime now) {
      final current = Period.containing(PeriodType.month, now);
      return [
        for (var k = 5; k >= 1; k--) current.shift(-k).start,
        current.start,
        current.end,
      ];
    }

    for (final now in [
      DateTime(2026, 11, 8, 14),
      DateTime(2027, 1, 15),
      DateTime(2026, 3, 31, 23, 59),
    ]) {
      test('matches the Archive for $now', () {
        expect(monthBounds(now), archiveMonths(now));
      });
    }

    test('8 Nov 2026 gives 1 Jun ... 1 Dec 2026', () {
      expect(monthBounds(DateTime(2026, 11, 8)), [
        for (var m = 6; m <= 12; m++) DateTime(2026, m),
      ]);
    });

    test('15 Jan 2027 crosses the year: Aug 2026 to Feb 2027', () {
      final b = monthBounds(DateTime(2027, 1, 15));
      expect(b.first, DateTime(2026, 8));
      expect(b.last, DateTime(2027, 2));
      expect(b, hasLength(7));
    });
  });

  test('percentChange', () {
    expect(percentChange(0, 0), isNull);
    expect(percentChange(5, 0), double.infinity);
    expect(percentChange(110, 100), closeTo(10, 1e-9));
    expect(percentChange(50, 100), -50);
    expect(percentChange(0, 40), -100);
  });

  test('formatChange', () {
    expect(formatChange(null), '—');
    expect(formatChange(double.infinity), 'New');
    expect(formatChange(10), '+10%');
    expect(formatChange(-50), '−50%');
    expect(formatChange(0), '0%');
    expect(formatChange(0.3), '0%');
    expect(formatChange(12.6), '+13%');
  });

  test('categoryChanges: union, −100% for a missing category, sorted', () {
    final cur = period(DateTime(2026, 11), total: 30, count: 3, cats: const [
      CategoryStat(category: 'Food', total: 10, count: 1),
      CategoryStat(category: 'Supermarket', total: 20, count: 2),
    ]);
    final prev = period(DateTime(2026, 10), total: 45, count: 3, cats: const [
      CategoryStat(category: 'Food', total: 5, count: 1),
      CategoryStat(category: 'Pharmacy', total: 30, count: 1),
      CategoryStat(category: 'Clothing', total: 10, count: 1),
    ]);
    final list = categoryChanges(cur, prev);
    expect(list.map((c) => c.category),
        ['Supermarket', 'Food', 'Pharmacy', 'Clothing']);
    expect(list[0].pct, double.infinity);
    expect(list[1].pct, 100);
    expect(list[2].current, 0);
    expect(list[2].pct, -100);

    // Without a previous period every category is "New".
    expect(categoryChanges(cur, null).every((c) => c.pct == double.infinity), isTrue);
  });

  group('SpendingStats', () {
    final stats = SpendingStats([
      period(DateTime(2026, 10)),
      period(DateTime(2026, 11), total: 1.205, count: 2,
        cats: const [CategoryStat(category: 'Food', total: 1.205, count: 2)],
        top: const StoreStat(storeName: 'KFC', total: 1.205, count: 2)),
    ]);

    test('current, previous and hasAnyReceipts', () {
      expect(stats.current.from, DateTime(2026, 11));
      expect(stats.previous!.from, DateTime(2026, 10));
      expect(stats.hasAnyReceipts, isTrue);
      expect(SpendingStats([period(DateTime(2026, 11))]).previous, isNull);
      expect(SpendingStats([period(DateTime(2026, 11))]).hasAnyReceipts, isFalse);
    });

    test('JSON round trip keeps every value', () {
      final back = SpendingStats.fromJson(stats.toJson());
      expect(back.toJson(), stats.toJson());
      expect(back.current.from, DateTime(2026, 11));
      expect(back.current.topStore!.storeName, 'KFC');
      expect(back.previous!.topStore, isNull);
      expect(back.current.byCategory.single.total, 1.205);
    });

    test('parses the server shape (UTC strings become local times)', () {
      final s = SpendingStats.fromJson({
        'periods': [{
          'from': '2026-10-31T21:00:00.000Z', 'to': '2026-11-30T21:00:00.000Z',
          'total': 287.99, 'count': 7, 'average': 41.141,
          'byCategory': [{'category': 'Electronics', 'total': 89.99, 'count': 1}],
          'topStore': {'storeName': 'iStore', 'total': 89.99, 'count': 1},
        }],
      });
      expect(s.current.from, DateTime.utc(2026, 10, 31, 21).toLocal());
      expect(s.current.from.isUtc, isFalse);
      expect(s.current.count, 7);
      expect(s.current.topStore!.total, 89.99);
    });
  });
}
