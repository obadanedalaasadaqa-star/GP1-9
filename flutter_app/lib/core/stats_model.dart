// Spending totals from GET /api/user/stats (the Trends tab).

class CategoryStat {
  final String category;
  final double total;
  final int count;

  const CategoryStat({required this.category, required this.total, required this.count});

  factory CategoryStat.fromJson(Map<String, dynamic> json) => CategoryStat(
    category: json['category'] as String,
    total: (json['total'] as num).toDouble(),
    count: (json['count'] as num).toInt(),
  );

  Map<String, dynamic> toJson() => {'category': category, 'total': total, 'count': count};
}

class StoreStat {
  final String storeName;
  final double total;
  final int count;

  const StoreStat({required this.storeName, required this.total, required this.count});

  factory StoreStat.fromJson(Map<String, dynamic> json) => StoreStat(
    storeName: json['storeName'] as String,
    total: (json['total'] as num).toDouble(),
    count: (json['count'] as num).toInt(),
  );

  Map<String, dynamic> toJson() => {'storeName': storeName, 'total': total, 'count': count};
}

/// One period [from, to) with its totals. [from]/[to] are local times.
class PeriodStats {
  final DateTime from;
  final DateTime to;
  final double total;
  final int count;
  final double average;
  final List<CategoryStat> byCategory;
  final StoreStat? topStore;

  const PeriodStats({
    required this.from,
    required this.to,
    required this.total,
    required this.count,
    required this.average,
    this.byCategory = const [],
    this.topStore,
  });

  factory PeriodStats.fromJson(Map<String, dynamic> json) => PeriodStats(
    from: DateTime.parse(json['from'] as String).toLocal(),
    to: DateTime.parse(json['to'] as String).toLocal(),
    total: (json['total'] as num).toDouble(),
    count: (json['count'] as num).toInt(),
    average: (json['average'] as num).toDouble(),
    byCategory: (json['byCategory'] as List<dynamic>)
        .map((e) => CategoryStat.fromJson(e as Map<String, dynamic>))
        .toList(),
    topStore: json['topStore'] == null
        ? null
        : StoreStat.fromJson(json['topStore'] as Map<String, dynamic>),
  );

  Map<String, dynamic> toJson() => {
    'from': from.toUtc().toIso8601String(),
    'to': to.toUtc().toIso8601String(),
    'total': total,
    'count': count,
    'average': average,
    'byCategory': byCategory.map((c) => c.toJson()).toList(),
    'topStore': topStore?.toJson(),
  };
}

/// All periods, oldest first (the order the bounds were sent in).
class SpendingStats {
  final List<PeriodStats> periods;

  const SpendingStats(this.periods);

  /// The latest period (this month on Trends).
  PeriodStats get current => periods.last;

  /// The period before [current], or null with a single period.
  PeriodStats? get previous => periods.length > 1 ? periods[periods.length - 2] : null;

  bool get hasAnyReceipts => periods.any((p) => p.count > 0);

  factory SpendingStats.fromJson(Map<String, dynamic> json) => SpendingStats(
    (json['periods'] as List<dynamic>)
        .map((e) => PeriodStats.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  Map<String, dynamic> toJson() => {'periods': periods.map((p) => p.toJson()).toList()};
}
