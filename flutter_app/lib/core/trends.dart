import 'period.dart';
import 'stats_model.dart';

/// [months] + 1 local-midnight month starts, oldest first, ending with the
/// end of the current month. Built from [Period] so Trends asks for exactly
/// the periods the Archive's "Month" filter uses.
List<DateTime> monthBounds(DateTime now, {int months = 6}) {
  final current = Period.containing(PeriodType.month, now);
  return [
    for (var k = months - 1; k >= 0; k--) current.shift(-k).start,
    current.end,
  ];
}

/// % change from [previous] to [current]. Null when both are 0,
/// infinity when spending starts from 0.
double? percentChange(double current, double previous) {
  if (previous == 0) return current == 0 ? null : double.infinity;
  return (current - previous) / previous * 100;
}

/// "—", "New", "+12%", "−8%" or "0%" (whole numbers, real minus sign).
String formatChange(double? pct) {
  if (pct == null) return '—';
  if (pct.isInfinite) return 'New';
  final n = pct.round();
  if (n > 0) return '+$n%';
  if (n < 0) return '−${-n}%';
  return '0%';
}

/// One category on Trends: this month, last month and the change.
class CategoryChange {
  final String category;
  final double current;
  final double previous;
  final double? pct;

  const CategoryChange(this.category, this.current, this.previous, this.pct);
}

/// Every category in either month (a category that drops to 0 still shows,
/// at −100%), sorted by this month desc, then last month desc, then name.
List<CategoryChange> categoryChanges(PeriodStats current, PeriodStats? previous) {
  final now = {for (final c in current.byCategory) c.category: c.total};
  final before = {for (final c in previous?.byCategory ?? <CategoryStat>[]) c.category: c.total};
  final list = [
    for (final name in {...now.keys, ...before.keys})
      CategoryChange(name, now[name] ?? 0, before[name] ?? 0,
          percentChange(now[name] ?? 0, before[name] ?? 0)),
  ];
  list.sort((a, b) {
    final byCurrent = b.current.compareTo(a.current);
    if (byCurrent != 0) return byCurrent;
    final byPrevious = b.previous.compareTo(a.previous);
    if (byPrevious != 0) return byPrevious;
    return a.category.compareTo(b.category);
  });
  return list;
}
