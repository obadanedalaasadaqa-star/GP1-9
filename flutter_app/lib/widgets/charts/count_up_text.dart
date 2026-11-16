import 'package:flutter/material.dart';
import '../../core/money.dart';
import 'chart_anim.dart';

/// An amount that counts up from 0 once. The last frame prints exactly
/// `formatJd(value)` + [suffix]; with reduce motion on, it shows at once.
class CountUpText extends StatelessWidget {
  final double value;
  final int decimals;
  final String suffix;
  final TextStyle? style;

  const CountUpText(this.value, {super.key, this.decimals = 2, this.suffix = ' JD', this.style});

  String _text(double v) => '${formatJd(v, decimals: decimals)}$suffix';

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return Text(_text(value), style: style);
    return TweenAnimationBuilder<double>(
      key: ValueKey(value),
      tween: Tween(begin: 0, end: 1),
      duration: kChartAnimation,
      curve: kChartCurve,
      builder: (context, t, _) => Text(_text(t >= 1 ? value : value * t), style: style),
    );
  }
}
