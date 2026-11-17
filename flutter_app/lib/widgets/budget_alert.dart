import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/budget_models.dart';
import '../core/constants.dart';
import '../core/design.dart';

/// "Food budget: 85% used" strip. Amber at 80%, coral at 100%.
class BudgetAlertBanner extends StatelessWidget {
  final BudgetAlert alert;
  const BudgetAlertBanner({super.key, required this.alert});

  static Color colorFor(BudgetAlert a) => a.isOver ? AppColors.alert : AppColors.amber;

  @override
  Widget build(BuildContext context) {
    final color = colorFor(alert);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.ink, width: 2),
      ),
      child: Row(
        children: [
          Icon(alert.isOver ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
            color: AppColors.ink, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(alert.title,
                  style: NxType.display(16, color: AppColors.ink,
                    weight: FontWeight.w700, letterSpacing: -0.2)),
                const SizedBox(height: 2),
                Text(alert.detail,
                  style: NxType.body(13, color: AppColors.ink, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet for a budget alert that arrives when no matching "New
/// receipt" sheet is open. Same frame as NewReceiptSheet.
class BudgetAlertSheet extends StatefulWidget {
  final BudgetAlert alert;
  final VoidCallback onViewBudgets;
  final VoidCallback onDone;

  const BudgetAlertSheet({
    super.key,
    required this.alert,
    required this.onViewBudgets,
    required this.onDone,
  });

  @override
  State<BudgetAlertSheet> createState() => _BudgetAlertSheetState();
}

class _BudgetAlertSheetState extends State<BudgetAlertSheet> {
  @override
  void initState() {
    super.initState();
    HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    return NxSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('BUDGET ALERT',
            textAlign: TextAlign.center,
            style: NxType.label(nx.muted)),
          const SizedBox(height: 16),
          BudgetAlertBanner(alert: widget.alert),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: widget.onViewBudgets,
            style: NxButtonStyle.solid(nx),
            child: const Text('View budgets'),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: widget.onDone,
            child: Text('OK',
              style: NxType.body(15, color: nx.text, weight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
