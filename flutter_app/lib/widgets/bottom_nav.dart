import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/constants.dart';

class NexusBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final VoidCallback onQrTap;

  const NexusBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.onQrTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 28, offset: const Offset(0, 8)),
          BoxShadow(
            color: AppColors.gold.withValues(alpha: 0.06),
            blurRadius: 20, spreadRadius: -4),
        ],
      ),
      child: Row(
        children: [
          _NavItem(index: 0, icon: Icons.home_rounded, label: 'Home',
            currentIndex: currentIndex, onTap: onTap),
          _NavItem(index: 1, icon: Icons.receipt_long_rounded, label: 'Archive',
            currentIndex: currentIndex, onTap: onTap),
          _CenterButton(onTap: onQrTap),
          _NavItem(index: 2, icon: Icons.insights_rounded, label: 'Trends',
            currentIndex: currentIndex, onTap: onTap),
          _NavItem(index: 3, icon: Icons.person_rounded, label: 'Profile',
            currentIndex: currentIndex, onTap: onTap),
        ],
      ),
    );
  }
}

// ── Individual tab item ───────────────────────────────────────────────────────

class _NavItem extends StatelessWidget {
  final int index;
  final IconData icon;
  final String label;
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _NavItem({
    required this.index,
    required this.icon,
    required this.label,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = currentIndex == index;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          decoration: BoxDecoration(
            color: active
                ? AppColors.gold.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: active ? 4 : 0,
                height: 3,
                margin: const EdgeInsets.only(bottom: 4),
                decoration: BoxDecoration(
                  color: AppColors.gold,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Icon(icon,
                size: 22,
                color: active ? AppColors.gold : AppColors.textMuted),
              const SizedBox(height: 3),
              Text(label,
                style: GoogleFonts.dmSans(
                  fontSize: 10, fontWeight: FontWeight.w600,
                  color: active ? AppColors.gold : AppColors.textMuted)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Center floating QR circle ─────────────────────────────────────────────────

class _CenterButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CenterButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56, height: 56,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          gradient: AppColors.goldGlow,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppColors.gold.withValues(alpha: 0.45),
              blurRadius: 20, spreadRadius: 2, offset: const Offset(0, 4)),
            BoxShadow(
              color: AppColors.mint.withValues(alpha: 0.25),
              blurRadius: 28, spreadRadius: 4),
          ],
        ),
        child: const Icon(Icons.qr_code_rounded, color: Colors.white, size: 26),
      ),
    );
  }
}
