import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/constants.dart';
import '../core/validators.dart';

/// Live strength bar + requirement checklist for a password field.
/// Rebuilds as [controller] changes; hidden while the field is empty.
class PasswordMeter extends StatelessWidget {
  final TextEditingController controller;
  final Color textMuted;
  final Color track;

  const PasswordMeter({
    super.key,
    required this.controller,
    required this.textMuted,
    required this.track,
  });

  static const _levels = {
    PasswordStrength.weak:   (1, 'Weak',   AppColors.alert),
    PasswordStrength.fair:   (2, 'Fair',   AppColors.gold),
    PasswordStrength.good:   (3, 'Good',   AppColors.blueLight),
    PasswordStrength.strong: (4, 'Strong', AppColors.mint),
  };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final password = value.text;
        if (password.isEmpty) return const SizedBox.shrink();
        final (filled, label, color) = _levels[passwordStrength(password)]!;

        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Four-segment strength bar + label
              Row(
                children: [
                  for (var i = 0; i < 4; i++) ...[
                    Expanded(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        height: 5,
                        decoration: BoxDecoration(
                          color: i < filled ? color : track,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    if (i < 3) const SizedBox(width: 5),
                  ],
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 48,
                    child: Text(label,
                      textAlign: TextAlign.right,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 12, fontWeight: FontWeight.w700, color: color)),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Requirement checklist
              for (final rule in passwordRules)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(
                        rule.test(password)
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 14,
                        color: rule.test(password) ? AppColors.mint : textMuted,
                      ),
                      const SizedBox(width: 8),
                      Text(rule.label,
                        style: GoogleFonts.dmSans(
                          fontSize: 12,
                          color: rule.test(password) ? AppColors.mint : textMuted)),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
