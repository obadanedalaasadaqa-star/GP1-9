import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/budget_models.dart';
import 'package:nexus_app/core/user_model.dart';

import 'support/budget_fixtures.dart';

void main() {
  test('BudgetList JSON round trip', () {
    final json = budgetListJson(
      budgets: [budgetJson('Food', 50, 42.5), budgetJson('Pharmacy', 10, 2)],
      now: DateTime(2026, 11, 13),
    );
    final list = BudgetList.fromJson(json);
    expect(list.month, '2026-11');
    expect(list.label, 'November 2026');
    expect(list.budgets.first.level, BudgetLevel.warning);
    expect(list.budgets.first.percent, 85);
    final again = BudgetList.fromJson(list.toJson());
    expect(again.toJson(), list.toJson());
    expect(again.from, list.from);
    expect(again.forCategory('Pharmacy')!.spent, 2);
    expect(again.forCategory('Clothing'), isNull);
    expect(again.unbudgeted, ['Clothing', 'Electronics', 'Supermarket']);
  });

  test('unknown level is ok', () {
    expect(BudgetLevel.parse('weird'), BudgetLevel.ok);
    expect(BudgetLevel.parse(null), BudgetLevel.ok);
    expect(BudgetLevel.parse('over'), BudgetLevel.over);
  });

  test('isMonthOf compares the local month', () {
    final list = BudgetList.fromJson(budgetListJson(month: '2026-11'));
    expect(list.isMonthOf(DateTime(2026, 11, 30, 23, 59)), isTrue);
    expect(list.isMonthOf(DateTime(2026, 12, 1)), isFalse);
    expect(list.isMonthOf(DateTime(2025, 11, 1)), isFalse);
  });

  test('BudgetAlert title and detail for 80 and 100 (formatJd)', () {
    final a80 = BudgetAlert.fromJson(alertJson);
    expect(a80.title, 'Food budget: 85% used');
    expect(a80.detail, '42.50 of 50.00 JD used in November 2026');
    expect(a80.isOver, isFalse);

    final a100 = alert(level: 100, percent: 102, spent: 51.205, limit: 50);
    expect(a100.title, 'Over your Food budget');
    expect(a100.detail, '51.21 of 50.00 JD used in November 2026');
    expect(a100.isOver, isTrue);
  });

  group('User email settings', () {
    final base = {
      'id': 'u1', 'email': 'a@nexus.test', 'name': 'A B', 'firstName': 'A', 'lastName': 'B',
      'serialNumber': 'NXS-AAAAA-BBBBB', 'loyaltyPoints': 3, 'createdAt': '2026-01-01T00:00:00.000Z',
    };

    test('missing keys (older cached users) use the defaults', () {
      final u = User.fromJson(base);
      expect(u.budgetAlertEmails, isTrue);
      expect(u.weeklySummaryEmails, isFalse);
    });

    test('toJson round trip and copyWith', () {
      final u = User.fromJson({...base, 'budgetAlertEmails': false, 'weeklySummaryEmails': true});
      final again = User.fromJson(u.toJson());
      expect(again.budgetAlertEmails, isFalse);
      expect(again.weeklySummaryEmails, isTrue);
      final changed = again.copyWith(budgetAlertEmails: true);
      expect(changed.budgetAlertEmails, isTrue);
      expect(changed.weeklySummaryEmails, isTrue);
      expect(again.copyWith(loyaltyPoints: 9).budgetAlertEmails, isFalse);
    });
  });
}
