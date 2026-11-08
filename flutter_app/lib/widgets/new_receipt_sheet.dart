import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/constants.dart';
import '../core/receipt_model.dart';
import '../core/theme_provider.dart';

/// Bottom sheet shown when a store sends the user a receipt (live, via the socket).
class NewReceiptSheet extends StatefulWidget {
  final Receipt receipt;
  final int pointsEarned;
  final VoidCallback onViewArchive;
  final VoidCallback onDone;

  const NewReceiptSheet({
    super.key,
    required this.receipt,
    required this.pointsEarned,
    required this.onViewArchive,
    required this.onDone,
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
    final isDark      = context.watch<ThemeProvider>().isDark;
    final surface     = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border      = isDark ? AppColors.border  : AppColors.borderLight;
    final textMuted   = isDark ? AppColors.textMuted : AppColors.textMutedLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;

    final r = widget.receipt;
    final catColor = CategoryColors.map[r.category] ?? AppColors.gold;
    final shown = r.items.take(NewReceiptSheet.maxItems).toList();
    final more = r.items.length - shown.length;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 24),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: textMuted.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 20),
          ShaderMask(
            shaderCallback: (b) => AppColors.goldGlow.createShader(b),
            child: Text('NEW RECEIPT',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: Colors.white, letterSpacing: 2.5)),
          ),
          const SizedBox(height: 16),

          // Store + category
          Text(r.storeName,
            textAlign: TextAlign.center,
            style: GoogleFonts.spaceGrotesk(
              fontSize: 20, fontWeight: FontWeight.w700, color: textPrimary)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: catColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(99)),
            child: Text(r.category,
              style: GoogleFonts.dmSans(
                fontSize: 11, fontWeight: FontWeight.w700, color: catColor)),
          ),
          const SizedBox(height: 18),

          // Total + points
          Text('${r.totalAmount.toStringAsFixed(2)} JD',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 40, fontWeight: FontWeight.w800,
              color: textPrimary, letterSpacing: -1)),
          const SizedBox(height: 4),
          Text('+${widget.pointsEarned} pts',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.mint)),
          const SizedBox(height: 18),

          // Items
          if (shown.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: border)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in shown)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(item,
                        style: GoogleFonts.dmSans(fontSize: 13, color: textPrimary)),
                    ),
                  if (more > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('and $more more',
                        style: GoogleFonts.dmSans(fontSize: 12, color: textMuted)),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 20),

          // Buttons
          SizedBox(
            width: double.infinity, height: 50,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppColors.goldGlow,
                borderRadius: BorderRadius.circular(14),
              ),
              child: ElevatedButton(
                onPressed: widget.onViewArchive,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14))),
                child: Text('View in Archive',
                  style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.w700,
                    fontSize: 15, color: Colors.white)),
              ),
            ),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: widget.onDone,
            child: Text('Done',
              style: GoogleFonts.dmSans(fontSize: 14, color: textMuted)),
          ),
        ],
      ),
    );
  }
}
