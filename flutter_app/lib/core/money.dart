/// Formats a JD amount the same way on every screen.
/// Rounds to whole fils first (so float noise and adding order don't matter),
/// then to [decimals] places, half away from zero, using integer maths only.
/// So the Archive's own sum and the server's total always print the same text.
///
/// Snapping to fils first is on purpose: `formatJd(12.4999999, decimals: 0)`
/// prints `13` (12.4999999 is 12.500 JD in fils). Don't "fix" it.
String formatJd(double v, {int decimals = 2}) {
  assert(decimals >= 0 && decimals <= 3);
  final fils = (v * 1000).round();                 // int, e.g. 1205
  final unit = const [1000, 100, 10, 1][decimals]; // fils per shown step
  final q = (fils / unit).round();                 // x.5 is exact here, rounds away from 0
  return (q / const [1, 10, 100, 1000][decimals]).toStringAsFixed(decimals);
}
