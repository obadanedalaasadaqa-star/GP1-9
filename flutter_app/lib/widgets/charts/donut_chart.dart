import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants.dart';
import '../../core/theme_provider.dart';
import 'chart_anim.dart';

class DonutSlice {
  final String label;
  final double value;
  final Color color;

  const DonutSlice(this.label, this.value, this.color);
}

/// The slices as drawn: slices under 2% of the total become one "Other"
/// slice (drawing only; the legend still lists every category).
List<DonutSlice> donutSlices(List<DonutSlice> slices) {
  final total = slices.fold<double>(0, (s, x) => s + x.value);
  if (slices.length <= 1 || total <= 0) return slices;
  final big = <DonutSlice>[];
  var other = 0.0;
  var smallCount = 0;
  for (final s in slices) {
    if (s.value / total < 0.02) {
      other += s.value;
      smallCount++;
    } else {
      big.add(s);
    }
  }
  if (smallCount == 0) return slices;
  return [...big, DonutSlice('Other', other, AppColors.textMuted)];
}

/// A donut that sweeps in once, with [center] over the hole. It prints no
/// text of its own.
class DonutChart extends StatelessWidget {
  static const size = 150.0;

  final List<DonutSlice> slices;
  final Widget center;

  const DonutChart({super.key, required this.slices, required this.center});

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeProvider>().isDark;
    final ring = isDark ? AppColors.border : AppColors.borderLight;
    final drawn = donutSlices(slices);
    final total = drawn.fold<double>(0, (s, x) => s + x.value);

    return Semantics(
      label: slices.map((s) => s.label).join(', '),
      child: ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              ChartGrow(
                dataKey: Object.hashAll(slices.map((s) => Object.hash(s.label, s.value))),
                builder: (context, t) => PieChart(
                  PieChartData(
                    centerSpaceRadius: 46,
                    sectionsSpace: 2,
                    startDegreeOffset: -90,
                    pieTouchData: PieTouchData(enabled: false),
                    borderData: FlBorderData(show: false),
                    sections: total <= 0
                        ? [PieChartSectionData(value: 1, color: ring, radius: 20, showTitle: false)]
                        : [
                            for (final s in drawn)
                              PieChartSectionData(
                                value: s.value * t, color: s.color, radius: 20, showTitle: false),
                            // Fills the rest of the circle while the donut sweeps in.
                            if (t < 1)
                              PieChartSectionData(
                                value: total * (1 - t), color: Colors.transparent,
                                radius: 20, showTitle: false),
                          ],
                  ),
                  duration: Duration.zero,
                ),
              ),
              center,
            ],
          ),
        ),
      ),
    );
  }
}
