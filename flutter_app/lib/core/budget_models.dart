// Monthly budgets from /api/budgets and live budget alerts (socket 'budget:alert').
import 'money.dart';

/// How full a budget is: under 80%, 80-99%, or 100% and over.
enum BudgetLevel {
  ok,
  warning,
  over;

  /// 'ok' | 'warning' | 'over'; anything else is [ok].
  static BudgetLevel parse(Object? raw) => switch (raw) {
        'warning' => BudgetLevel.warning,
        'over' => BudgetLevel.over,
        _ => BudgetLevel.ok,
      };
}

/// One budget bar: what was spent this month against the monthly [limit].
class BudgetStatus {
  final String category;
  final double limit;
  final double spent;
  final double remaining;
  final double overBy;

  /// Whole percent, can be over 100.
  final int percent;
  final BudgetLevel level;

  const BudgetStatus({
    required this.category,
    required this.limit,
    required this.spent,
    required this.remaining,
    required this.overBy,
    required this.percent,
    required this.level,
  });

  factory BudgetStatus.fromJson(Map<String, dynamic> json) => BudgetStatus(
    category: json['category'] as String,
    limit: (json['limit'] as num).toDouble(),
    spent: (json['spent'] as num).toDouble(),
    remaining: (json['remaining'] as num).toDouble(),
    overBy: (json['overBy'] as num).toDouble(),
    percent: (json['percent'] as num).toInt(),
    level: BudgetLevel.parse(json['level']),
  );

  Map<String, dynamic> toJson() => {
    'category': category,
    'limit': limit,
    'spent': spent,
    'remaining': remaining,
    'overBy': overBy,
    'percent': percent,
    'level': level.name,
  };
}

/// The answer of every /api/budgets route: this month's budgets (highest
/// percent first) and the categories the picker offers.
class BudgetList {
  /// 'YYYY-MM' in the user's time zone.
  final String month;

  /// 'November 2026'.
  final String label;
  final DateTime from;
  final DateTime to;
  final List<BudgetStatus> budgets;
  final List<String> categories;

  const BudgetList({
    required this.month,
    required this.label,
    required this.from,
    required this.to,
    this.budgets = const [],
    this.categories = const [],
  });

  factory BudgetList.fromJson(Map<String, dynamic> json) => BudgetList(
    month: json['month'] as String,
    label: json['label'] as String,
    from: DateTime.parse(json['from'] as String).toLocal(),
    to: DateTime.parse(json['to'] as String).toLocal(),
    budgets: (json['budgets'] as List<dynamic>? ?? const [])
        .map((e) => BudgetStatus.fromJson(e as Map<String, dynamic>))
        .toList(),
    categories: (json['categories'] as List<dynamic>? ?? const []).cast<String>(),
  );

  Map<String, dynamic> toJson() => {
    'month': month,
    'label': label,
    'from': from.toUtc().toIso8601String(),
    'to': to.toUtc().toIso8601String(),
    'budgets': budgets.map((b) => b.toJson()).toList(),
    'categories': categories,
  };

  BudgetStatus? forCategory(String category) {
    for (final b in budgets) {
      if (b.category == category) return b;
    }
    return null;
  }

  /// Categories that don't have a budget yet (for the "Add budget" picker).
  List<String> get unbudgeted =>
      categories.where((c) => forCategory(c) == null).toList();

  /// True when this list is for the local month of [now], so a list saved
  /// last month is never shown as "this month".
  bool isMonthOf(DateTime now) =>
      month == '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
}

/// A live budget alert: a store receipt took [category] to 80% or 100%.
class BudgetAlert {
  final String receiptId;
  final String category;

  /// 80 or 100.
  final int level;
  final int percent;
  final double spent;
  final double limit;
  final double remaining;
  final double overBy;
  final String monthLabel;

  const BudgetAlert({
    required this.receiptId,
    required this.category,
    required this.level,
    required this.percent,
    required this.spent,
    required this.limit,
    required this.remaining,
    required this.overBy,
    required this.monthLabel,
  });

  factory BudgetAlert.fromJson(Map<String, dynamic> json) => BudgetAlert(
    receiptId: json['receiptId'] as String,
    category: json['category'] as String,
    level: (json['level'] as num).toInt(),
    percent: (json['percent'] as num).toInt(),
    spent: (json['spent'] as num).toDouble(),
    limit: (json['limit'] as num).toDouble(),
    remaining: (json['remaining'] as num).toDouble(),
    overBy: (json['overBy'] as num).toDouble(),
    monthLabel: json['monthLabel'] as String,
  );

  bool get isOver => level >= 100;

  /// 'Food budget: 85% used' or 'Over your Food budget'.
  String get title => isOver ? 'Over your $category budget' : '$category budget: $percent% used';

  /// '42.50 of 50.00 JD used in November 2026'.
  String get detail => '${formatJd(spent)} of ${formatJd(limit)} JD used in $monthLabel';
}
