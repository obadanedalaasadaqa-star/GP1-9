import 'package:flutter/material.dart';
import '../core/budget_models.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/money.dart';

/// One monthly budget: category, "spent / limit JD", a progress bar and a
/// caption. Used by Trends and the Budgets screen.
class BudgetBar extends StatelessWidget {
  final BudgetStatus status;
  final VoidCallback? onTap;

  const BudgetBar({super.key, required this.status, this.onTap});

  /// Category colour under 80%, amber from 80%, coral from 100%.
  static Color colorFor(BudgetStatus s) => switch (s.level) {
        BudgetLevel.over => AppColors.coral,
        BudgetLevel.warning => AppColors.amber,
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
    final nx = Nx.of(context);
    final color = colorFor(status);
    final over = status.level == BudgetLevel.over;

    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(status.category,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: NxType.body(15.5, weight: FontWeight.w700, color: nx.text)),
              ),
              Text('${formatJd(status.spent)} / ${formatJd(status.limit)} JD',
                style: NxType.mono(12.5, color: nx.text, weight: FontWeight.w500)),
            ],
          ),
          const SizedBox(height: 8),
          // The outline is a foreground decoration, so the track keeps the
          // full width (the fill and track widths are what the tests read).
          Container(
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: nx.line, width: 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              // Full width on purpose: the Column gives loose width, so without
              // it the Stack took the fill's width and the empty track never
              // showed (a 0% bar was invisible, a 91% bar had no grey end).
              child: SizedBox(
                height: 18,
                width: double.infinity,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(
                        key: const ValueKey('budget-bar-track'),
                        color: nx.dark ? AppColors.ink : AppColors.paper)),
                    FractionallySizedBox(
                      key: const ValueKey('budget-bar-fill'),
                      widthFactor: fillOf(status),
                      heightFactor: 1,
                      child: over
                          ? CustomPaint(painter: _Stripes(color))
                          : ColoredBox(color: color),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(captionOf(status),
            style: NxType.mono(12,
              weight: status.level == BudgetLevel.ok ? FontWeight.w400 : FontWeight.w500,
              color: status.level == BudgetLevel.ok ? nx.muted
                  : (over ? nx.danger : (nx.dark ? AppColors.amber : AppColors.ink)))),
        ],
      ),
    );

    if (onTap == null) return content;
    return Pressable(onTap: onTap, child: content);
  }
}

/// Diagonal warning stripes for an over-budget bar.
class _Stripes extends CustomPainter {
  final Color color;
  _Stripes(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = color);
    final p = Paint()
      ..color = AppColors.ink.withValues(alpha: 0.35)
      ..strokeWidth = 3;
    for (double x = -size.height; x < size.width; x += 9) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(_Stripes old) => old.color != color;
}
