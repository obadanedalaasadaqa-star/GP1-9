import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/constants.dart';
import '../core/money.dart';
import '../core/receipt_model.dart';
import '../core/theme_provider.dart';

/// Full receipt: store, date and time, every item with its price, and the total.
/// Opened by tapping a receipt on Home or in the Archive.
class ReceiptDetailScreen extends StatelessWidget {
  final Receipt receipt;
  const ReceiptDetailScreen({super.key, required this.receipt});

  static Future<void> open(BuildContext context, Receipt receipt) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ReceiptDetailScreen(receipt: receipt),
      ));

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

  static IconData _catIcon(String cat) {
    switch (cat) {
      case 'Supermarket': return Icons.shopping_cart_rounded;
      case 'Food':        return Icons.restaurant_rounded;
      case 'Pharmacy':    return Icons.local_pharmacy_rounded;
      case 'Clothing':    return Icons.checkroom_rounded;
      case 'Electronics': return Icons.devices_rounded;
      default:            return Icons.receipt_long_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark      = context.watch<ThemeProvider>().isDark;
    final bg          = isDark ? AppColors.bg      : AppColors.bgLight;
    final surface     = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border      = isDark ? AppColors.border  : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted   : AppColors.textMutedLight;
    final catColor    = CategoryColors.of(receipt.category);
    final lines       = receipt.lineItems;
    final itemCount   = lines == null
        ? receipt.items.length
        : lines.fold<int>(0, (s, l) => s + l.qty);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: textPrimary),
        title: Text('Receipt',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 18, fontWeight: FontWeight.w700, color: textPrimary)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          child: Container(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: border),
            ),
            padding: const EdgeInsets.fromLTRB(22, 26, 22, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Store ──────────────────────────────────────────────
                Center(
                  child: Container(
                    width: 56, height: 56,
                    decoration: BoxDecoration(
                      color: catColor.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(_catIcon(receipt.category), color: catColor, size: 26),
                  ),
                ),
                const SizedBox(height: 12),
                Text(receipt.storeName,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 22, fontWeight: FontWeight.w800, color: textPrimary)),
                const SizedBox(height: 8),
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: catColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(receipt.category,
                      style: GoogleFonts.dmSans(
                        fontSize: 12, fontWeight: FontWeight.w600, color: catColor)),
                  ),
                ),
                const SizedBox(height: 10),
                Text(formatDateTime(receipt.date),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
                const SizedBox(height: 2),
                Text('Receipt #${receipt.id.split('-').first.toUpperCase()}',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.dmSans(
                    fontSize: 11, color: textMuted, letterSpacing: 0.5)),

                const SizedBox(height: 20),
                _DashedLine(color: textMuted.withValues(alpha: 0.35)),
                const SizedBox(height: 16),

                // ── Items ──────────────────────────────────────────────
                Text('ITEMS',
                  style: GoogleFonts.dmSans(
                    fontSize: 11, fontWeight: FontWeight.w700,
                    letterSpacing: 1.6, color: textMuted)),
                const SizedBox(height: 10),
                if (lines != null)
                  for (final l in lines)
                    _LineRow(
                      name: l.name,
                      detail: '${l.qty} × ${formatUnitPrice(l.unitPrice)} JD',
                      amount: '${formatJd(l.lineTotal)} JD',
                      textPrimary: textPrimary, textMuted: textMuted,
                    )
                else ...[
                  if (receipt.items.isEmpty)
                    Text('No items listed.',
                      style: GoogleFonts.dmSans(fontSize: 13, color: textMuted))
                  else
                    for (final item in receipt.items)
                      _LineRow(name: item, textPrimary: textPrimary, textMuted: textMuted),
                  const SizedBox(height: 4),
                  Text('Item prices were not saved for this receipt.',
                    style: GoogleFonts.dmSans(
                      fontSize: 11, fontStyle: FontStyle.italic, color: textMuted)),
                ],

                const SizedBox(height: 12),
                _DashedLine(color: textMuted.withValues(alpha: 0.35)),
                const SizedBox(height: 14),

                // ── Totals ─────────────────────────────────────────────
                Row(
                  children: [
                    Text('$itemCount item${itemCount == 1 ? '' : 's'}',
                      style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('TOTAL',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 16, fontWeight: FontWeight.w800,
                        letterSpacing: 1, color: textPrimary)),
                    const Spacer(),
                    Text('${formatJd(receipt.totalAmount)} JD',
                      key: const ValueKey('receipt-total'),
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 28, fontWeight: FontWeight.w800, color: textPrimary)),
                  ],
                ),
                if (receipt.pointsEarned > 0) ...[
                  const SizedBox(height: 14),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: AppColors.mint.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.star_rounded, color: AppColors.mint, size: 16),
                          const SizedBox(width: 6),
                          Text('+${receipt.pointsEarned} pts earned',
                            style: GoogleFonts.dmSans(
                              fontSize: 13, fontWeight: FontWeight.w700,
                              color: AppColors.mint)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
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
  final Color textPrimary;
  final Color textMuted;

  const _LineRow({
    required this.name,
    this.detail,
    this.amount,
    required this.textPrimary,
    required this.textMuted,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                style: GoogleFonts.dmSans(
                  fontSize: 14, fontWeight: FontWeight.w600, color: textPrimary)),
              if (detail != null) ...[
                const SizedBox(height: 2),
                Text(detail!,
                  style: GoogleFonts.dmSans(fontSize: 12, color: textMuted)),
              ],
            ],
          ),
        ),
        if (amount != null) ...[
          const SizedBox(width: 12),
          Text(amount!,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 14, fontWeight: FontWeight.w700, color: textPrimary)),
        ],
      ],
    ),
  );
}

/// The torn-paper dashed rule between receipt sections.
class _DashedLine extends StatelessWidget {
  final Color color;
  const _DashedLine({required this.color});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      const dash = 6.0, gap = 4.0;
      final n = (c.maxWidth / (dash + gap)).floor();
      return Row(
        children: List.generate(n, (_) => Padding(
          padding: const EdgeInsets.only(right: gap),
          child: SizedBox(width: dash, height: 1.5,
            child: DecoratedBox(decoration: BoxDecoration(color: color))),
        )),
      );
    },
  );
}
