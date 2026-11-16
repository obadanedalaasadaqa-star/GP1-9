// Words that say what a change is compared with, so "−43%" on Trends and
// "+8%" in the Report never look like they contradict each other.
import 'ai_models.dart';

/// Suffix of the Trends "This month" chip. While the month is in progress the
/// comparison is with the whole previous month: "vs all of October".
String trendsVsLabel({required String previousMonth, required bool monthInProgress}) =>
    monthInProgress ? 'vs all of $previousMonth' : 'vs $previousMonth';

/// The subtitle under the Report title: which dates the report compares with.
/// Presets compare with the same days N months earlier; a custom range with
/// the same number of days right before it.
String reportComparedWith(ReportRange range, ReportRange previous) {
  final why = switch (range.period) {
    '1m' => 'same days last month',
    '3m' => 'same days, 3 months earlier',
    '6m' => 'same days, 6 months earlier',
    '1y' => 'same days, a year earlier',
    _ => range.days == 1 ? 'the day before' : 'the ${range.days} days before',
  };
  return 'compared with ${previous.label} ($why)';
}
