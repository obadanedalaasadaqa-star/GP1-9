import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../core/chat_chart.dart';
import '../../core/constants.dart';
import '../../core/money.dart';
import '../../core/theme_provider.dart';
import 'bar_list.dart';
import 'column_chart.dart';
import 'compare_bars.dart';

/// A quantity without trailing zeros: 12, 1.5, 0.125.
String formatQty(double n) {
  if (n == n.roundToDouble()) return n.toStringAsFixed(0);
  var s = n.toStringAsFixed(3);
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
}

/// "89.99 JD", "6×" or "1.5 pcs".
String chartValueText(double v, ChartUnit unit) => switch (unit) {
      ChartUnit.jd => '${formatJd(v)} JD',
      ChartUnit.times => '${v.round()}×',
      ChartUnit.items => '${formatQty(v)} pcs',
    };

/// The chart under an Ask AI answer: a muted title, then bars, columns or a
/// comparison. Everything it shows comes from the server's chart object.
class ChatChartView extends StatelessWidget {
  final ChatChart chart;

  const ChatChartView({super.key, required this.chart});

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeProvider>().isDark;
    final textMuted = isDark ? AppColors.textMuted : AppColors.textMutedLight;
    final c = chart;

    final Widget body = switch (c.kind) {
      ChartKind.bars => BarList(items: [
          for (final i in c.items)
            BarItem(i.label, i.value,
              i.note == null ? chartValueText(i.value, c.unit) : '${chartValueText(i.value, c.unit)} · ${i.note}'),
        ]),
      ChartKind.columns => ColumnChart(items: [
          for (final i in c.items)
            ColumnItem(i.label, i.value,
              c.unit == ChartUnit.jd ? formatJd(i.value, decimals: 0) : chartValueText(i.value, c.unit)),
        ]),
      ChartKind.compare => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CompareBars(
              aLabel: c.a!.label, aValue: c.a!.value,
              bLabel: c.b!.label, bValue: c.b!.value,
              change: c.change,
            ),
            if (c.pairs.isNotEmpty) ...[
              const SizedBox(height: 10),
              BarList(items: [
                for (final p in c.pairs)
                  BarItem(p.label, p.a, '${formatJd(p.a)} / ${formatJd(p.b)}', value2: p.b),
              ]),
            ],
          ],
        ),
    };

    return Padding(
      key: const ValueKey('chat-chart'),
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(c.title,
            style: GoogleFonts.dmSans(fontSize: 11.5, fontWeight: FontWeight.w600, color: textMuted)),
          const SizedBox(height: 8),
          body,
        ],
      ),
    );
  }
}
