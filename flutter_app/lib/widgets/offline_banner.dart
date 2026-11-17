import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/constants.dart';

/// "You're offline" strip shown above lists that come from the phone's cache.
class OfflineBanner extends StatelessWidget {
  final DateTime? savedAt;

  /// What is shown from the cache ("receipts", "trends").
  final String what;
  const OfflineBanner({super.key, this.savedAt, this.what = 'receipts'});

  /// "just now", "5 min ago", "2 h ago" or "3 d ago".
  static String ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final when = savedAt == null ? '' : ' · updated ${ago(savedAt!)}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.amber,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.ink, width: 2),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, color: AppColors.ink, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text("You're offline. Showing $what saved on this phone$when.",
              style: GoogleFonts.instrumentSans(fontSize: 12.5, fontWeight: FontWeight.w600,
                color: AppColors.ink, height: 1.35)),
          ),
        ],
      ),
    );
  }
}
