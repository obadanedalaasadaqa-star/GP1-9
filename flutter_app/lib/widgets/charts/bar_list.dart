import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../core/constants.dart';
import '../../core/theme_provider.dart';
import 'chart_anim.dart';

/// One horizontal bar: [label] on the left, [valueText] on the right (printed
/// exactly as given). [value2] adds a second, muted bar in the same row.
class BarItem {
  final String label;
  final double value;
  final String valueText;
  final Color? color;
  final double? value2;

  const BarItem(this.label, this.value, this.valueText, {this.color, this.value2});
}

/// Horizontal bars that grow left to right once, item 0 at the top. The
/// bars are an fl_chart BarChart turned a quarter; every text is a plain
/// Text next to it, so the chart itself paints no text.
class BarList extends StatelessWidget {
  static const rowHeight = 28.0;

  final List<BarItem> items;
  final int? maxBars;
  final bool showValues;

  const BarList({super.key, required this.items, this.maxBars, this.showValues = true});

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeProvider>().isDark;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted = isDark ? AppColors.textMuted : AppColors.textMutedLight;
    final track = isDark ? AppColors.border : AppColors.borderLight;
    final shown = maxBars == null ? items : items.take(maxBars!).toList();
    if (shown.isEmpty) return const SizedBox.shrink();

    // The scale comes from the final values, so the bars really grow.
    var maxY = 0.0;
    for (final i in shown) {
      maxY = math.max(maxY, math.max(i.value, i.value2 ?? 0));
    }
    if (maxY <= 0) maxY = 1;
    final height = shown.length * rowHeight;

    Widget column(List<Widget> cells, CrossAxisAlignment align) =>
        Column(crossAxisAlignment: align, children: cells);
    Widget cell(Widget child, Alignment alignment) =>
        SizedBox(height: rowHeight, child: Align(alignment: alignment, child: child));

    final chart = ChartGrow(
      dataKey: Object.hashAll(shown.map((i) => Object.hash(i.label, i.value, i.value2))),
      builder: (context, t) => BarChart(
        BarChartData(
          rotationQuarterTurns: 1,
          alignment: BarChartAlignment.spaceAround,
          minY: 0,
          maxY: maxY,
          titlesData: const FlTitlesData(show: false),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          barTouchData: BarTouchData(enabled: false),
          barGroups: [
            for (var k = 0; k < shown.length; k++)
              BarChartGroupData(
                x: k,
                barsSpace: 3,
                barRods: [
                  BarChartRodData(
                    toY: shown[k].value * t,
                    width: shown[k].value2 == null ? 12 : 8,
                    color: shown[k].color ?? AppColors.gold,
                    borderRadius: BorderRadius.circular(4),
                    backDrawRodData: BackgroundBarChartRodData(
                      show: shown[k].value2 == null, toY: maxY, color: track),
                  ),
                  if (shown[k].value2 != null)
                    BarChartRodData(
                      toY: shown[k].value2! * t,
                      width: 8,
                      color: textMuted.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(4),
                    ),
                ],
              ),
          ],
        ),
        duration: Duration.zero,
      ),
    );

    return Semantics(
      label: shown.map((i) => '${i.label} ${i.valueText}').join(', '),
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                flex: 2,
                child: column([
                  for (final i in shown)
                    cell(Text(i.label, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.dmSans(fontSize: 12.5, color: textPrimary)),
                      Alignment.centerLeft),
                ], CrossAxisAlignment.start),
              ),
              const SizedBox(width: 8),
              Expanded(flex: 3, child: chart),
              if (showValues) ...[
                const SizedBox(width: 8),
                column([
                  for (final i in shown)
                    cell(Text(i.valueText,
                        style: GoogleFonts.dmSans(
                          fontSize: 12.5, fontWeight: FontWeight.w600, color: textPrimary)),
                      Alignment.centerRight),
                ], CrossAxisAlignment.end),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
