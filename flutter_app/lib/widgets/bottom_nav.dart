import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/design.dart';

/// Floating pill nav: ink on paper, cobalt on ink, with the lime QR button
/// raised out of the middle.
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
    final nx = Nx.of(context);
    final barColor = nx.dark ? AppColors.cobalt : AppColors.ink;
    final idle = nx.dark ? Colors.white : AppColors.textMuted;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: SizedBox(
          height: 96,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              Container(
                height: 68,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: BorderRadius.circular(34),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.ink.withValues(alpha: 0.35),
                      blurRadius: 24, offset: const Offset(0, 10)),
                  ],
                ),
                child: Row(
                  children: [
                    _NavItem(index: 0, icon: Icons.home_outlined, label: 'Home',
                      currentIndex: currentIndex, onTap: onTap, idle: idle),
                    _NavItem(index: 1, icon: Icons.receipt_long_outlined,
                      label: 'Archive', currentIndex: currentIndex,
                      onTap: onTap, idle: idle),
                    const SizedBox(width: 76),
                    _NavItem(index: 2, icon: Icons.bar_chart_rounded,
                      label: 'Trends', currentIndex: currentIndex,
                      onTap: onTap, idle: idle),
                    _NavItem(index: 3, icon: Icons.person_outline_rounded,
                      label: 'Profile', currentIndex: currentIndex,
                      onTap: onTap, idle: idle),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                child: _CenterButton(onTap: onQrTap),
              ),
            ],
          ),
        ),
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
  final Color idle;

  const _NavItem({
    required this.index,
    required this.icon,
    required this.label,
    required this.currentIndex,
    required this.onTap,
    required this.idle,
  });

  @override
  Widget build(BuildContext context) {
    final active = currentIndex == index;
    final color = active ? AppColors.lime : idle;
    return Expanded(
      child: Semantics(
        selected: active,
        button: true,
        child: Pressable(
          onTap: () => onTap(index),
          child: SizedBox(
            height: 56,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 23, color: color),
                const SizedBox(height: 3),
                Text(label,
                  style: NxType.body(11, color: color,
                    weight: active ? FontWeight.w700 : FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Center raised QR button ─────────────────────────────────────────────────

class _CenterButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CenterButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Show my code',
      child: Pressable(
        onTap: onTap,
        child: Container(
          width: 66, height: 66,
          decoration: BoxDecoration(
            color: AppColors.lime,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.ink, width: 4),
          ),
          child: const Icon(Icons.qr_code_rounded,
            color: AppColors.ink, size: 30),
        ),
      ),
    );
  }
}
