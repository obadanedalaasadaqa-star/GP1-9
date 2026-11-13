import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/budget_models.dart';
import '../core/constants.dart';
import '../core/theme_provider.dart';

/// "Food budget: 85% used" strip. Gold at 80%, alert red at 100%.
class BudgetAlertBanner extends StatelessWidget {
  final BudgetAlert alert;
  const BudgetAlertBanner({super.key, required this.alert});

  static Color colorFor(BudgetAlert a) => a.isOver ? AppColors.alert : AppColors.gold;

  @override
  Widget build(BuildContext context) {
    final color = colorFor(alert);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(alert.isOver ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
            color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(alert.title,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 14, fontWeight: FontWeight.w700, color: color)),
                const SizedBox(height: 2),
                Text(alert.detail,
                  style: GoogleFonts.dmSans(fontSize: 12, color: color, height: 1.35)),
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
    final isDark    = context.watch<ThemeProvider>().isDark;
    final surface   = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border    = isDark ? AppColors.border  : AppColors.borderLight;
    final textMuted = isDark ? AppColors.textMuted : AppColors.textMutedLight;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 24),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: textMuted.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 20),
          ShaderMask(
            shaderCallback: (b) => AppColors.goldGlow.createShader(b),
            child: Text('BUDGET ALERT',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: Colors.white, letterSpacing: 2.5)),
          ),
          const SizedBox(height: 18),
          BudgetAlertBanner(alert: widget.alert),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity, height: 50,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppColors.goldGlow,
                borderRadius: BorderRadius.circular(14),
              ),
              child: ElevatedButton(
                onPressed: widget.onViewBudgets,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14))),
                child: Text('View budgets',
                  style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.w700,
                    fontSize: 15, color: Colors.white)),
              ),
            ),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: widget.onDone,
            child: Text('OK',
              style: GoogleFonts.dmSans(fontSize: 14, color: textMuted)),
          ),
        ],
      ),
    );
  }
}
