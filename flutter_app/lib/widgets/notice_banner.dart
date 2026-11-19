import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/design.dart';

/// Amber notice: the sign-in error banner's shape for warnings that are not
/// the user's mistake ("Your session ended", "Face ID changed").
/// With [error] it is the coral error banner instead (ink on coral reads at
/// 4.68:1 on any ground, including the dark sheet surface).
class NxNoticeBanner extends StatelessWidget {
  final String text;
  final bool error;
  const NxNoticeBanner(this.text, {super.key, this.error = false});

  @override
  Widget build(BuildContext context) => Container(
        key: ValueKey(error ? 'error-banner' : 'notice-banner'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: error ? AppColors.coral : AppColors.amber,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.ink, width: 2),
        ),
        child: Row(children: [
          Icon(error ? Icons.error_outline : Icons.info_outline, color: AppColors.ink, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: NxType.body(13.5, weight: FontWeight.w600, color: AppColors.ink)),
          ),
        ]),
      );
}
