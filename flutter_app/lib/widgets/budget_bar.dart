import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/budget_models.dart';
import '../core/constants.dart';
import '../core/money.dart';
import '../core/theme_provider.dart';

/// One monthly budget: category, "spent / limit JD", a progress bar and a
/// caption. Used by Trends and the Budgets screen.
class BudgetBar extends StatelessWidget {
  final BudgetStatus status;
  final VoidCallback? onTap;

  const BudgetBar({super.key, required this.status, this.onTap});

  /// Category colour under 80%, gold from 80%, alert red from 100%.
  static Color colorFor(BudgetStatus s) => switch (s.level) {
        BudgetLevel.over => AppColors.alert,
        BudgetLevel.warning => AppColors.gold,
        BudgetLevel.ok => CategoryColors.of(s.category),
      };

  /// Share of the bar that is filled, 0 to 1 (over 100% stays full).
  static double fillOf(BudgetStatus s) =>
      s.limit <= 0 ? 0 : (s.spent / s.limit).clamp(0.0, 1.0);

  /// "85% · 7.50 JD left" or "Over by 3.20 JD".
  static String captionOf(BudgetStatus s) => s.overBy > 0
      ? 'Over by ${formatJd(s.overBy)} JD'
      : '${s.percent}% · ${formatJd(s.remaining)} JD left';

  @override
  Widget build(BuildContext context) {
    final isDark      = context.watch<ThemeProvider>().isDark;
    final border      = isDark ? AppColors.border : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted : AppColors.textMutedLight;
    final color = colorFor(status);

    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10, height: 10,
                decoration: BoxDecoration(
                  color: CategoryColors.of(status.category),
                  shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(status.category,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.dmSans(
                    fontSize: 14, fontWeight: FontWeight.w600, color: textPrimary)),
              ),
              Text('${formatJd(status.spent)} / ${formatJd(status.limit)} JD',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 13, fontWeight: FontWeight.w700, color: textPrimary)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: SizedBox(
              height: 8,
              child: Stack(
                children: [
                  Positioned.fill(child: ColoredBox(color: border)),
                  FractionallySizedBox(
                    key: const ValueKey('budget-bar-fill'),
                    widthFactor: fillOf(status),
                    heightFactor: 1,
                    child: ColoredBox(color: color),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(captionOf(status),
            style: GoogleFonts.dmSans(
              fontSize: 12,
              fontWeight: status.level == BudgetLevel.ok ? FontWeight.w400 : FontWeight.w700,
              color: status.level == BudgetLevel.ok ? textMuted : color)),
        ],
      ),
    );

    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: content,
    );
  }
}
