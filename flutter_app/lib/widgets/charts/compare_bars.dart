import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../core/constants.dart';
import '../../core/money.dart';
import '../../core/theme_provider.dart';
import 'bar_list.dart';

/// "New" for 'new', a real minus sign for '-8%'; other values unchanged.
String compareChangeText(String change) =>
    change == 'new' ? 'New' : change.startsWith('-') ? '−${change.substring(1)}' : change;

/// Two bars on the same scale: period A (gold) and period B (muted), with
/// optional values and a change chip (up is alert, down is mint, as on Trends).
class CompareBars extends StatelessWidget {
  final String aLabel;
  final double aValue;
  final String bLabel;
  final double bValue;
  final String? change;
  final bool showValues;
  final bool showChange;

  const CompareBars({
    super.key,
    required this.aLabel,
    required this.aValue,
    required this.bLabel,
    required this.bValue,
    this.change,
    this.showValues = true,
    this.showChange = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeProvider>().isDark;
    final textMuted = isDark ? AppColors.textMuted : AppColors.textMutedLight;
    final c = change;
    final chip = showChange && c != null && c != 'none';
    final text = chip ? compareChangeText(c) : '';
    final color = !chip || text == '0%'
        ? textMuted
        : text.startsWith('−') ? AppColors.mint : AppColors.alert;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BarList(
          showValues: showValues,
          items: [
            BarItem(aLabel, aValue, '${formatJd(aValue)} JD', color: AppColors.gold),
            BarItem(bLabel, bValue, '${formatJd(bValue)} JD', color: textMuted.withValues(alpha: 0.6)),
          ],
        ),
        if (chip) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(text,
              style: GoogleFonts.dmSans(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
          ),
        ],
      ],
    );
  }
}
