enum PeriodType { day, week, month, year, custom }

/// A time window for filtering receipts: [start] inclusive, [end] exclusive,
/// both at local midnight. Weeks run Sunday → Saturday.
class Period {
  final PeriodType type;
  final DateTime start;
  final DateTime end;

  const Period._(this.type, this.start, this.end);

  static const _months = ['Jan','Feb','Mar','Apr','May','Jun',
                          'Jul','Aug','Sep','Oct','Nov','Dec'];
  static const _monthsLong = ['January','February','March','April','May','June',
                              'July','August','September','October','November','December'];
  static const _weekdays = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

  /// The period of [type] that contains [date] (custom falls back to the month).
  factory Period.containing(PeriodType type, DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    switch (type) {
      case PeriodType.day:
        return Period._(type, d, DateTime(d.year, d.month, d.day + 1));
      case PeriodType.week:
        final s = DateTime(d.year, d.month, d.day - d.weekday % 7);
        return Period._(type, s, DateTime(s.year, s.month, s.day + 7));
      case PeriodType.month:
      case PeriodType.custom:
        return Period._(PeriodType.month,
          DateTime(d.year, d.month), DateTime(d.year, d.month + 1));
      case PeriodType.year:
        return Period._(type, DateTime(d.year), DateTime(d.year + 1));
    }
  }

  /// A custom range covering [first] through [last], both days included.
  factory Period.custom(DateTime first, DateTime last) => Period._(
    PeriodType.custom,
    DateTime(first.year, first.month, first.day),
    DateTime(last.year, last.month, last.day + 1),
  );

  /// The same kind of period moved [steps] forward (or back if negative).
  /// Custom ranges are not navigable and are returned unchanged.
  Period shift(int steps) {
    switch (type) {
      case PeriodType.day:
        return Period.containing(type,
          DateTime(start.year, start.month, start.day + steps));
      case PeriodType.week:
        return Period.containing(type,
          DateTime(start.year, start.month, start.day + 7 * steps));
      case PeriodType.month:
        return Period.containing(type,
          DateTime(start.year, start.month + steps));
      case PeriodType.year:
        return Period.containing(type, DateTime(start.year + steps));
      case PeriodType.custom:
        return this;
    }
  }

  /// The last day included in the period.
  DateTime get lastDay => DateTime(end.year, end.month, end.day - 1);

  /// Whether the next period would start in the future relative to [now].
  bool isLatest(DateTime now) => end.isAfter(now);

  String label(DateTime now) {
    switch (type) {
      case PeriodType.day:
        final today = DateTime(now.year, now.month, now.day);
        if (start == today) return 'Today';
        if (start == DateTime(today.year, today.month, today.day - 1)) {
          return 'Yesterday';
        }
        return '${_weekdays[start.weekday - 1]}, ${_short(start)} ${start.year}';
      case PeriodType.week:
      case PeriodType.custom:
        return _range(start, lastDay);
      case PeriodType.month:
        return '${_monthsLong[start.month - 1]} ${start.year}';
      case PeriodType.year:
        return '${start.year}';
    }
  }

  static String _short(DateTime d) => '${d.day} ${_months[d.month - 1]}';

  // "1 – 7 Nov 2026", "29 Nov – 5 Dec 2026", "28 Dec 2025 – 3 Jan 2026"
  static String _range(DateTime a, DateTime b) {
    if (a == b) return '${_short(a)} ${a.year}';
    if (a.year != b.year) return '${_short(a)} ${a.year} – ${_short(b)} ${b.year}';
    if (a.month != b.month) return '${_short(a)} – ${_short(b)} ${b.year}';
    return '${a.day} – ${_short(b)} ${b.year}';
  }
}
