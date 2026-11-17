import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/ai_chat_session.dart';
import '../core/realtime_service.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/money.dart';
import '../core/receipt_model.dart';
import 'ai_screen.dart';

/// Full receipt: store, date and time, every item with its price, and the total.
/// Opened by tapping a receipt on Home or in the Archive.
class ReceiptDetailScreen extends StatelessWidget {
  final Receipt receipt;
  const ReceiptDetailScreen({super.key, required this.receipt});

  /// Push the receipt. The shell's AI chat session (if any) is passed on, so
  /// "Ask Nexus about this" continues the same chat.
  static Future<void> open(BuildContext context, Receipt receipt) {
    final realtime = context.read<RealtimeService?>();
    final session = context.read<AiChatSession?>();
    final screen = ReceiptDetailScreen(receipt: receipt);
    if (realtime == null && session == null) {
      return Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    }
    return Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MultiProvider(
        providers: [
          if (realtime != null)
            ChangeNotifierProvider<RealtimeService>.value(value: realtime),
          if (session != null)
            ChangeNotifierProvider<AiChatSession>.value(value: session),
        ],
        child: screen,
      ),
    ));
  }

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "Sun, 8 Nov 2026 · 23:39" in the phone's time zone.
  static String formatDateTime(DateTime d) {
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]} ${d.year} · $hh:$mm';
  }

  /// Unit prices keep the fils when there are any (7.995), else 2 decimals (1.25).
  static String formatUnitPrice(double v) {
    final fils = (v * 1000).round();
    return formatJd(v, decimals: fils % 10 == 0 ? 2 : 3);
  }

  static const _monthsUp = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
                            'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

  @override
  Widget build(BuildContext context) {
    final nx        = Nx.of(context);
    final catColor  = CategoryColors.of(receipt.category);
    final onPage    = catColor == AppColors.cobalt ? Colors.white : AppColors.ink;
    final lines     = receipt.lineItems;
    final itemCount = lines == null
        ? receipt.items.length
        : lines.fold<int>(0, (s, l) => s + l.qty);
    const ink   = AppColors.ink;
    const muted = AppColors.textMutedLight;
    final d = receipt.date;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: onPage == Colors.white ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
      backgroundColor: catColor,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ─────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Row(
                children: [
                  const NxBackButton(),
                  Expanded(
                    child: Text('Receipt',
                      textAlign: TextAlign.center,
                      style: NxType.mono(13, color: onPage,
                        weight: FontWeight.w500, letterSpacing: 1.5)),
                  ),
                  const SizedBox(width: 44),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 20, 26, 24),
                child: Transform.rotate(
                  angle: 0.0175,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        decoration: const BoxDecoration(boxShadow: [
                          BoxShadow(color: ink, offset: Offset(6, 8)),
                        ]),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const ReceiptEdge(color: Colors.white, up: true),
                            Container(
                              color: Colors.white,
                              padding: const EdgeInsets.fromLTRB(22, 16, 22, 18),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // ── Store ──────────────────────────────
                                  Row(
                                    children: [
                                      NxIconTile(
                                        icon: categoryIcon(receipt.category),
                                        color: catColor, size: 48, tilt: -5),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(receipt.storeName,
                                              style: NxType.display(24,
                                                color: ink, height: 1.05)),
                                            const SizedBox(height: 4),
                                            Text(
                                              '${receipt.category.toUpperCase()} · '
                                              '${_weekdays[d.weekday - 1].toUpperCase()} '
                                              '${d.day} ${_monthsUp[d.month - 1]}',
                                              style: NxType.mono(11, color: muted,
                                                letterSpacing: 0.5)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Text(formatDateTime(receipt.date),
                                    style: NxType.mono(12, color: ink)),
                                  const SizedBox(height: 2),
                                  Text('Receipt #${receipt.id.split('-').first.toUpperCase()}',
                                    style: NxType.mono(11, color: muted,
                                      letterSpacing: 0.5)),
                                  const SizedBox(height: 14),
                                  const DashedRule(color: ink),
                                  const SizedBox(height: 14),

                                  // ── Items ──────────────────────────────
                                  if (lines != null)
                                    for (final l in lines)
                                      _LineRow(
                                        name: l.name,
                                        detail: '${l.qty} × ${formatUnitPrice(l.unitPrice)} JD',
                                        amount: '${formatJd(l.lineTotal)} JD',
                                      )
                                  else ...[
                                    if (receipt.items.isEmpty)
                                      Text('No items listed.',
                                        style: NxType.mono(12.5, color: muted))
                                    else
                                      for (final item in receipt.items)
                                        _LineRow(name: item),
                                    const SizedBox(height: 4),
                                    Text('Item prices were not saved for this receipt.',
                                      style: NxType.body(12, color: muted)
                                        .copyWith(fontStyle: FontStyle.italic)),
                                  ],

                                  const SizedBox(height: 10),
                                  const DashedRule(color: ink),
                                  const SizedBox(height: 12),

                                  // ── Totals ─────────────────────────────
                                  Row(
                                    children: [
                                      Text('TOTAL · ', style: NxType.label(muted)),
                                      Text('$itemCount item${itemCount == 1 ? '' : 's'}',
                                        style: NxType.mono(11, color: muted,
                                          letterSpacing: 1)),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text('${formatJd(receipt.totalAmount)} JD',
                                        key: const ValueKey('receipt-total'),
                                        style: NxType.display(46, color: ink,
                                          letterSpacing: -2, height: 1)),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  SizedBox(
                                    height: 38,
                                    child: CustomPaint(
                                      painter: _BarcodePainter(receipt.id)),
                                  ),
                                  const SizedBox(height: 10),
                                  Text('SHUKRAN · SEE YOU SOON',
                                    textAlign: TextAlign.center,
                                    style: NxType.mono(11, color: muted,
                                      letterSpacing: 3)),
                                ],
                              ),
                            ),
                            const ReceiptEdge(color: Colors.white),
                          ],
                        ),
                      ),
                      if (receipt.pointsEarned > 0)
                        Positioned(
                          right: -14, bottom: 96,
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: ink, width: 3)),
                            child: NxStamp(
                              value: '+${receipt.pointsEarned}',
                              caption: 'POINTS',
                              color: ink, fill: AppColors.lime,
                              size: 92, tilt: -14),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),

            // ── Actions ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 16),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => AiScreen.open(context, tab: AiTab.ask,
                        draft: 'How much did I spend at ${receipt.storeName} this month?'),
                      style: NxButtonStyle.solid(nx, fill: ink, text: Colors.white),
                      child: const Text('Ask Nexus about this'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    style: NxButtonStyle.outline(nx, color: onPage),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

class _LineRow extends StatelessWidget {
  final String name;
  final String? detail;
  final String? amount;

  const _LineRow({required this.name, this.detail, this.amount});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Not Flexible: a flex child would reserve half the row and the
            // leader would stop short of the amount.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 190),
              child: Text(name,
                style: NxType.mono(13.5, color: AppColors.ink)),
            ),
            if (amount != null) ...[
              const SizedBox(width: 6),
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: DashedRule(color: AppColors.dotted, dash: 2, gap: 3),
                ),
              ),
              const SizedBox(width: 6),
              Text(amount!,
                style: NxType.mono(13.5, color: AppColors.ink,
                  weight: FontWeight.w500)),
            ],
          ],
        ),
        if (detail != null) ...[
          const SizedBox(height: 1),
          Text(detail!,
            style: NxType.mono(11, color: AppColors.textMutedLight)),
        ],
      ],
    ),
  );
}

/// Decorative barcode, the same for the same receipt.
class _BarcodePainter extends CustomPainter {
  final String seed;
  _BarcodePainter(this.seed);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = AppColors.ink;
    final codes = seed.codeUnits;
    var x = 0.0;
    var i = 0;
    while (x < size.width) {
      final c = codes.isEmpty ? 7 : codes[i % codes.length] + i;
      final bar = 1.0 + c % 3;
      final gap = 1.5 + (c ~/ 3) % 3;
      canvas.drawRect(
        Rect.fromLTWH(x, 0, bar.clamp(0, size.width - x), size.height), p);
      x += bar + gap;
      i++;
    }
  }

  @override
  bool shouldRepaint(_BarcodePainter old) => old.seed != seed;
}
