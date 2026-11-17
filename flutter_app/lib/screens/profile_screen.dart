import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/money.dart';
import '../core/realtime_service.dart';
import '../core/theme_provider.dart';
import '../widgets/budgets_alerts_card.dart';
import '../widgets/security_card.dart';
import 'profile_edit_screens.dart';
import 'verify_email_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // Ends every session on the server, this one too, then logs out here. The
  // live connection is stopped first, so the server dropping it can't show
  // "session expired". No context is used after the first await.
  Future<void> _logoutAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out of all devices?'),
        content: const Text('Sign out on every device, including this one?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('logout-all-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign out', style: TextStyle(color: AppColors.alert))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final auth = context.read<AuthProvider>();
    final realtime = context.read<RealtimeService?>();
    final messenger = ScaffoldMessenger.of(context);

    realtime?.stop();
    try {
      await ApiClient.logoutAll();
      await auth.logout();
    } on ApiException catch (e) {
      // 401: the session is already gone (e.g. the answer was lost after the
      // server ended it), so just log out here.
      if (e.statusCode == 401) {
        await auth.logout();
        return;
      }
      _logoutAllFailed(realtime, messenger, e.toString());
    } catch (e) {
      _logoutAllFailed(realtime, messenger, e.toString());
    }
  }

  // Still signed in: reconnect (syncing what was pushed meanwhile) and say why.
  void _logoutAllFailed(RealtimeService? realtime, ScaffoldMessengerState messenger, String error) {
    if (realtime != null) {
      realtime.syncOnFirstConnect = true;
      realtime.start();
    }
    if (mounted) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't sign out of all devices. $error")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final user   = context.watch<AuthProvider>().user!;
    final isDark = context.watch<ThemeProvider>().isDark;
    final theme  = context.watch<ThemeProvider>();

    final bg      = isDark ? AppColors.bg      : AppColors.bgLight;
    final surface = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border  = isDark ? AppColors.border  : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted   : AppColors.textMutedLight;
    final nx          = Nx.of(context);

    final initials = user.name.isNotEmpty
        ? user.name.trim().split(' ').map((w) => w[0].toUpperCase()).take(2).join()
        : '?';

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Profile',
                style: NxType.display(40, color: textPrimary, letterSpacing: -1.8)),
              const SizedBox(height: 18),

              // Member card
              Padding(
                padding: const EdgeInsets.only(right: 6, bottom: 6),
                child: NxCard(
                  tilt: 2,
                  color: AppColors.cobalt,
                  borderColor: AppColors.ink,
                  shadowColor: isDark ? AppColors.lime : AppColors.ink,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('NEXUS', style: NxType.display(18,
                            color: Colors.white, letterSpacing: 1)),
                          const Spacer(),
                          Text('MEMBER SINCE ${_formatDate(user.createdAt).toUpperCase()}',
                            style: NxType.mono(12, color: AppColors.cobaltSoft,
                              letterSpacing: 1)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Container(
                            width: 56, height: 56,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.lime,
                              shape: BoxShape.circle,
                              border: Border.all(color: AppColors.ink, width: 2)),
                            child: Text(initials,
                              style: NxType.display(19, color: AppColors.ink,
                                letterSpacing: 0)),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_titleCase(user.name),
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: NxType.display(22, color: Colors.white)),
                                Text(user.email,
                                  maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: NxType.body(13.5, color: AppColors.cobaltSoft)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      DashedRule(color: Colors.white.withValues(alpha: 0.8),
                        thickness: 1.5),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: Text(user.serialNumber,
                              style: NxType.mono(13, color: Colors.white,
                                weight: FontWeight.w500)),
                          ),
                          Text('${formatPoints(user.loyaltyPoints)} pts',
                            style: NxType.display(20, color: AppColors.lime)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),

              // Appearance card (theme toggle)
              _card(
                surface: surface, border: border,
                children: [
                  _sectionTitle('APPEARANCE', textMuted),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Dark mode',
                            style: NxType.body(15, weight: FontWeight.w700,
                              color: textPrimary)),
                          const SizedBox(height: 2),
                          Text(isDark ? 'On, ink theme' : 'Off, paper theme',
                            style: NxType.body(12.5, color: textMuted)),
                        ],
                      ),
                      Switch(
                        value: isDark,
                        onChanged: (_) => theme.toggle(),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Budgets & alerts card (budgets link + email switches)
              const BudgetsAlertsCard(),
              const SizedBox(height: 14),

              // Sign-in security card (two-step sign-in switch)
              const SecurityCard(),
              const SizedBox(height: 14),

              // Account info card
              _card(
                surface: surface, border: border,
                children: [
                  _sectionTitle('ACCOUNT', textMuted),
                  // Email, serial, points and member-since are on the member
                  // card above; only the verification status lives here.
                  _emailStatusRow(user.emailVerified, textMuted: textMuted),
                  _linkRow('Edit name and email',
                    () => EditProfileScreen.open(context)),
                  const NxRowDivider(),
                  _linkRow('Change password',
                    () => ChangePasswordScreen.open(context)),
                ],
              ),
              const SizedBox(height: 14),

              // Sign out
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => context.read<AuthProvider>().logout(),
                  style: NxButtonStyle.outline(nx, color: nx.danger),
                  child: const Text('Sign Out'),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  key: const ValueKey('logout-all'),
                  onPressed: _logoutAll,
                  child: Text('Sign out of all devices',
                    style: NxType.body(13.5, weight: FontWeight.w700,
                      color: nx.danger)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }

  Widget _card({
    required Color surface,
    required Color border,
    required List<Widget> children,
  }) => NxProfileCard(children: children);

  Widget _emailStatusRow(bool verified, {required Color textMuted, bool last = false}) => Column(children: [
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Email status', style: NxType.body(14.5,
            weight: FontWeight.w700, color: Nx.of(context).text)),
          verified
              ? _chip(Icons.check_rounded, 'Verified', AppColors.teal)
              : GestureDetector(
                  onTap: () => VerifyEmailScreen.open(context),
                  child: _chip(Icons.error_outline_rounded,
                    'Not verified · Verify', AppColors.amber),
                ),
        ],
      ),
    ),
    if (!last) const NxRowDivider(),
  ]);

  Widget _chip(IconData icon, String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: AppColors.ink),
      const SizedBox(width: 5),
      Text(label, style: NxType.body(12.5,
        weight: FontWeight.w700, color: AppColors.ink)),
    ]),
  );

  /// A settings row that opens its own screen.
  Widget _linkRow(String label, VoidCallback onTap) {
    final nx = Nx.of(context);
    return Pressable(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: NxType.body(14.5,
                weight: FontWeight.w700, color: nx.text)),
            ),
            Icon(Icons.chevron_right_rounded, color: nx.text),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String t, Color textMuted) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(t, style: NxType.label(textMuted)),
  );

  /// "obada sadaqa" → "Obada Sadaqa" for display (the stored name is unchanged).
  static String _titleCase(String s) => s
      .split(' ')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');

  String _formatDate(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun',
                'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${m[d.month - 1]} ${d.year}';
  }
}
