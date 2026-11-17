import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/budget_models.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/money.dart';
import '../core/receipt_model.dart';
import 'budget_alert.dart';

/// Bottom sheet shown when a store sends the user a receipt (live, via the socket).
class NewReceiptSheet extends StatefulWidget {
  final Receipt receipt;
  final int pointsEarned;
  final VoidCallback onViewArchive;
  final VoidCallback onDone;

  /// Budget alerts caused by this receipt (they arrive just after it); each
  /// one shows as a banner above the buttons.
  final ValueListenable<List<BudgetAlert>>? alerts;

  const NewReceiptSheet({
    super.key,
    required this.receipt,
    required this.pointsEarned,
    required this.onViewArchive,
    required this.onDone,
    this.alerts,
  });

  static const maxItems = 4;

  @override
  State<NewReceiptSheet> createState() => _NewReceiptSheetState();
}

class _NewReceiptSheetState extends State<NewReceiptSheet> {
  @override
  void initState() {
    super.initState();
    HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    const ink = AppColors.ink;
    const muted = AppColors.textMutedLight;

    final r = widget.receipt;
    final catColor = CategoryColors.map[r.category] ?? AppColors.lime;
    final shown = r.items.take(NewReceiptSheet.maxItems).toList();
    final more = r.items.length - shown.length;

    return NxSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('NEW RECEIPT',
            textAlign: TextAlign.center,
            style: NxType.label(nx.muted)),
          const SizedBox(height: 14),

          // The receipt, printed on a slip
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 12, 8),
            child: Transform.rotate(
              angle: -0.017,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    decoration: BoxDecoration(boxShadow: [
                      BoxShadow(color: nx.shadow, offset: const Offset(5, 6)),
                    ]),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const ReceiptEdge(color: Colors.white, up: true),
                        Container(
                          color: Colors.white,
                          padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  NxIconTile(icon: categoryIcon(r.category),
                                    color: catColor, size: 40),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(r.storeName,
                                          style: NxType.display(20, color: ink,
                                            height: 1.1)),
                                        const SizedBox(height: 2),
                                        Text(r.category,
                                          style: NxType.mono(11.5, color: muted,
                                            letterSpacing: 0.5)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              if (shown.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                const DashedRule(color: ink),
                                const SizedBox(height: 10),
                                for (final item in shown)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 2),
                                    child: Text(item,
                                      style: NxType.mono(13, color: ink)),
                                  ),
                                if (more > 0)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text('and $more more',
                                      style: NxType.mono(11.5, color: muted)),
                                  ),
                              ],
                              const SizedBox(height: 10),
                              const DashedRule(color: ink),
                              const SizedBox(height: 10),
                              Text('${formatJd(r.totalAmount)} JD',
                                style: NxType.display(38, color: ink,
                                  letterSpacing: -1.5, height: 1)),
                            ],
                          ),
                        ),
                        const ReceiptEdge(color: Colors.white),
                      ],
                    ),
                  ),
                  Positioned(
                    right: -6, bottom: 22,
                    child: Transform.rotate(
                      angle: -0.2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.lime,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: ink, width: 2.5)),
                        child: Text('+${widget.pointsEarned} pts',
                          style: NxType.display(17, color: ink)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Budget alerts for this receipt
          if (widget.alerts != null)
            ValueListenableBuilder<List<BudgetAlert>>(
              valueListenable: widget.alerts!,
              builder: (_, alerts, _) => Column(
                children: [
                  for (final a in alerts) ...[
                    BudgetAlertBanner(alert: a),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),

          // Buttons
          ElevatedButton(
            onPressed: widget.onViewArchive,
            style: NxButtonStyle.solid(nx),
            child: const Text('View in Archive'),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: widget.onDone,
            child: Text('Done',
              style: NxType.body(15, color: nx.text, weight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
