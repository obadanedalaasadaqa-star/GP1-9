import 'package:nexus_app/core/budget_models.dart';

/// 'YYYY-MM' of [now] (local).
String monthKeyOf(DateTime now) =>
    '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';

/// A server-style budget row.
Map<String, dynamic> budgetJson(String category, double limit, double spent) {
  final percent = (spent * 1000 * 100 / (limit * 1000)).floor();
  return {
    'category': category,
    'limit': limit,
    'spent': spent,
    'remaining': spent >= limit ? 0 : limit - spent,
    'overBy': spent > limit ? spent - limit : 0,
    'percent': percent,
    'level': percent >= 100 ? 'over' : percent >= 80 ? 'warning' : 'ok',
  };
}

/// A /api/budgets answer for the month of [now] (or [month]).
Map<String, dynamic> budgetListJson({
  List<Map<String, dynamic>> budgets = const [],
  DateTime? now,
  String? month,
  String label = 'November 2026',
  List<String> categories = const ['Clothing', 'Electronics', 'Food', 'Pharmacy', 'Supermarket'],
}) {
  final n = now ?? DateTime.now();
  return {
    'month': month ?? monthKeyOf(n),
    'label': label,
    'from': DateTime(n.year, n.month).toUtc().toIso8601String(),
    'to': DateTime(n.year, n.month + 1).toUtc().toIso8601String(),
    'tzOffsetMinutes': 180,
    'budgets': budgets,
    'categories': categories,
  };
}

const alertJson = <String, dynamic>{
  'receiptId': 'r1',
  'category': 'Food',
  'level': 80,
  'percent': 85,
  'spent': 42.5,
  'limit': 50,
  'remaining': 7.5,
  'overBy': 0,
  'month': '2026-11',
  'monthLabel': 'November 2026',
};

BudgetAlert alert({String receiptId = 'r1', String category = 'Food', int level = 80, int percent = 85,
        double spent = 42.5, double limit = 50}) =>
    BudgetAlert.fromJson({
      ...alertJson,
      'receiptId': receiptId,
      'category': category,
      'level': level,
      'percent': percent,
      'spent': spent,
      'limit': limit,
      'remaining': spent >= limit ? 0 : limit - spent,
      'overBy': spent > limit ? spent - limit : 0,
    });
