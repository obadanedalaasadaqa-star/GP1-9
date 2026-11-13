import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/offline_cache.dart';
import '../core/theme_provider.dart';
import '../screens/budgets_screen.dart';
import '../screens/verify_email_screen.dart';

/// Profile's "BUDGETS & ALERTS" card: a link to the Budgets screen and the two
/// email switches (budget alerts, weekly summary). Live in-app alerts are
/// always on; emails need a verified address.
class BudgetsAlertsCard extends StatefulWidget {
  const BudgetsAlertsCard({super.key});

  @override
  State<BudgetsAlertsCard> createState() => _BudgetsAlertsCardState();
}

class _BudgetsAlertsCardState extends State<BudgetsAlertsCard> {
  int? _budgetCount; // from the saved list; null = unknown

  // Values shown while their request runs (null = show the user's value).
  bool? _alertsPending;
  bool? _weeklyPending;

  @override
  void initState() {
    super.initState();
    _loadCount();
  }

  Future<void> _loadCount() async {
    final list = await OfflineCache.loadBudgets();
    if (mounted) setState(() => _budgetCount = list?.budgets.length);
  }

  Future<void> _openBudgets() async {
    await BudgetsScreen.open(context);
    _loadCount();
  }

  Future<void> _toggle({required bool weekly, required bool value}) async {
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => weekly ? _weeklyPending = value : _alertsPending = value);
    try {
      final updated = weekly
          ? await ApiClient.updateNotifications(weeklySummaryEmails: value)
          : await ApiClient.updateNotifications(budgetAlertEmails: value);
      auth.updateUser(updated);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't save the setting. $e")));
    } finally {
      if (mounted) setState(() => weekly ? _weeklyPending = null : _alertsPending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user        = context.watch<AuthProvider>().user!;
    final isDark      = context.watch<ThemeProvider>().isDark;
    final surface     = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border      = isDark ? AppColors.border  : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted   : AppColors.textMutedLight;
    final verified = user.emailVerified;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('BUDGETS & ALERTS', style: GoogleFonts.spaceGrotesk(
              fontSize: 10, fontWeight: FontWeight.w700,
              color: textMuted, letterSpacing: 2)),
          ),
          InkWell(
            key: const ValueKey('profile-budgets'),
            onTap: _openBudgets,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.savings_rounded, color: AppColors.gold, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('Monthly budgets', style: GoogleFonts.dmSans(
                      fontSize: 14, fontWeight: FontWeight.w500, color: textPrimary)),
                  ),
                  if (_budgetCount != null)
                    Text('$_budgetCount set', style: GoogleFonts.dmSans(
                      fontSize: 13, color: textMuted)),
                  Icon(Icons.chevron_right_rounded, color: textMuted),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.4)),
          _switchRow(
            key: const ValueKey('switch-budget-alerts'),
            title: 'Budget alert emails',
            subtitle: 'Email me at 80% and 100% of a budget',
            value: _alertsPending ?? user.budgetAlertEmails,
            enabled: verified && _alertsPending == null,
            onChanged: (v) => _toggle(weekly: false, value: v),
            textPrimary: textPrimary, textMuted: textMuted, border: border),
          _switchRow(
            key: const ValueKey('switch-weekly'),
            title: 'Weekly summary email',
            subtitle: "Every Sunday morning: last week's spending",
            value: _weeklyPending ?? user.weeklySummaryEmails,
            enabled: verified && _weeklyPending == null,
            onChanged: (v) => _toggle(weekly: true, value: v),
            textPrimary: textPrimary, textMuted: textMuted, border: border),
          if (!verified)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Verify your email to get these emails',
                      style: GoogleFonts.dmSans(fontSize: 12, color: textMuted)),
                  ),
                  TextButton(
                    onPressed: () => VerifyEmailScreen.open(context),
                    child: Text('Verify', style: GoogleFonts.dmSans(
                      fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.gold)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _switchRow({
    required Key key,
    required String title,
    required String subtitle,
    required bool value,
    required bool enabled,
    required ValueChanged<bool> onChanged,
    required Color textPrimary,
    required Color textMuted,
    required Color border,
  }) =>
    Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: GoogleFonts.dmSans(
                  fontSize: 14, fontWeight: FontWeight.w500, color: textPrimary)),
                const SizedBox(height: 2),
                Text(subtitle, style: GoogleFonts.dmSans(fontSize: 12, color: textMuted)),
              ],
            ),
          ),
          Switch(
            key: key,
            value: value,
            onChanged: enabled ? onChanged : null,
            activeThumbColor: AppColors.gold,
            activeTrackColor: AppColors.gold.withValues(alpha: 0.25),
            inactiveThumbColor: textMuted,
            inactiveTrackColor: border,
          ),
        ],
      ),
    );
}
