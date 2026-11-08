import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/constants.dart';

/// "You're offline" strip shown above lists that come from the phone's cache.
class OfflineBanner extends StatelessWidget {
  final DateTime? savedAt;
  const OfflineBanner({super.key, this.savedAt});

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final when = savedAt == null ? '' : ' · updated ${_ago(savedAt!)}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, color: AppColors.gold, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text("You're offline. Showing receipts saved on this phone$when.",
              style: GoogleFonts.dmSans(fontSize: 12.5, color: AppColors.gold, height: 1.35)),
          ),
        ],
      ),
    );
  }
}
