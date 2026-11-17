import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../core/constants.dart';
import '../../core/theme_provider.dart';
import 'chart_anim.dart';

/// One column: [topLabel] above it, [label] (short month) below it.
/// [highlight] (the month in progress) is cobalt (lime on ink).
class ColumnItem {
  final String label;
  final double value;
  final String topLabel;
  final bool highlight;

  const ColumnItem(this.label, this.value, this.topLabel, {this.highlight = false});
}

/// Vertical columns that grow once. Over 12 columns, each is 28 px wide and
/// the chart scrolls sideways. Labels are plain Text rows above and below
/// the chart, one cell per column, shrunk to fit instead of overflowing.
class ColumnChart extends StatelessWidget {
  static const columnWidth = 28.0;
  static const chartHeight = 110.0;

  final List<ColumnItem> items;

  const ColumnChart({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final isDark = context.watch<ThemeProvider>().isDark;
    final textMuted = isDark ? AppColors.textMuted : AppColors.textMutedLight;
    var maxY = items.fold<double>(0, (m, i) => math.max(m, i.value));
    if (maxY <= 0) maxY = 1;
    final scrolls = items.length > 12;

    Widget content(double width) {
      final cellWidth = width / items.length;
      Widget labels(String Function(ColumnItem) text, double fontSize, {bool bold = false}) => Row(
        children: [
          for (final i in items)
            SizedBox(
              width: cellWidth,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(text(i), maxLines: 1,
                  style: GoogleFonts.instrumentSans(
                    fontSize: fontSize,
                    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                    color: i.highlight ? (Theme.of(context).brightness == Brightness.dark ? AppColors.lime : AppColors.cobalt) : textMuted)),
              ),
            ),
        ],
      );
      return SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            labels((i) => i.topLabel, 9.5, bold: true),
            const SizedBox(height: 4),
            SizedBox(
              height: chartHeight,
              child: ChartGrow(
                dataKey: Object.hashAll(items.map((i) => Object.hash(i.label, i.value))),
                builder: (context, t) => BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceAround,
                    minY: 0,
                    maxY: maxY,
                    titlesData: const FlTitlesData(show: false),
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                    barTouchData: BarTouchData(enabled: false),
                    barGroups: [
                      for (var k = 0; k < items.length; k++)
                        BarChartGroupData(x: k, barRods: [
                          BarChartRodData(
                            toY: items[k].value * t,
                            width: math.min(cellWidth * 0.6, 18),
                            color: items[k].highlight
                                ? (Theme.of(context).brightness == Brightness.dark ? AppColors.lime : AppColors.cobalt)
                                : AppColors.lavender,
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
                          ),
                        ]),
                    ],
                  ),
                  duration: Duration.zero,
                ),
              ),
            ),
            const SizedBox(height: 6),
            labels((i) => i.label, 9.5),
          ],
        ),
      );
    }

    return Semantics(
      label: items.map((i) => '${i.label} ${i.topLabel}').join(', '),
      child: ExcludeSemantics(
        child: scrolls
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: content(items.length * columnWidth),
              )
            : LayoutBuilder(builder: (context, c) => content(c.maxWidth)),
      ),
    );
  }
}
