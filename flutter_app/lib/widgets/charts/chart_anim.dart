import 'package:flutter/material.dart';

/// How long every chart grows. Keep it at most 800 ms and never repeat it:
/// report_view_test.dart waits a fixed 20 x 50 ms (1 s), not pumpAndSettle,
/// so a slower animation would leave in-between text on screen.
const kChartAnimation = Duration(milliseconds: 600);
const kChartCurve = Curves.easeOutCubic;

/// The one animation source for the fl_chart wrappers: [builder] gets t from
/// 0 to 1 once per [dataKey] (new data replays it). The wrappers scale their
/// values by t and give fl_chart `duration: Duration.zero`, so fl_chart's own
/// animation never runs. With reduce motion on, t is 1 at once.
class ChartGrow extends StatelessWidget {
  final Object dataKey;
  final Widget Function(BuildContext context, double t) builder;

  const ChartGrow({super.key, required this.dataKey, required this.builder});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return builder(context, 1.0);
    return TweenAnimationBuilder<double>(
      key: ValueKey(dataKey),
      tween: Tween(begin: 0, end: 1),
      duration: kChartAnimation,
      curve: kChartCurve,
      builder: (context, t, _) => builder(context, t),
    );
  }
}
