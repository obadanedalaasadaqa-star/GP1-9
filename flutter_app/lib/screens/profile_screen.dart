import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/theme_provider.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _nameCtrl;
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  String? _status;
  String _msg = '';

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(
      text: context.read<AuthProvider>().user?.name ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final auth = context.read<AuthProvider>();
    if (_nameCtrl.text.trim() == auth.user?.name) return;

    setState(() { _loading = true; _status = null; });
    try {
      final updated = await ApiClient.updateName(_nameCtrl.text.trim());
      auth.updateUser(updated);
      setState(() { _status = 'success'; _msg = 'Profile updated.'; });
    } catch (e) {
      setState(() { _status = 'error'; _msg = e.toString(); });
    } finally {
      if (mounted) setState(() => _loading = false);
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
    final textDim     = isDark ? AppColors.textDim     : AppColors.textDimLight;

    final initials = user.name.isNotEmpty
        ? user.name.trim().split(' ').map((w) => w[0].toUpperCase()).take(2).join()
        : '?';

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Profile',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 28, fontWeight: FontWeight.w800,
                  color: textPrimary, letterSpacing: -0.5)),
              const SizedBox(height: 4),
              Text('Manage your Nexus account.',
                style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
              const SizedBox(height: 28),

              // Avatar + name hero
              Center(
                child: Column(
                  children: [
                    Container(
                      width: 80, height: 80,
                      decoration: BoxDecoration(
                        gradient: AppColors.goldGlow,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.gold.withValues(alpha: 0.4),
                            blurRadius: 24, spreadRadius: 2),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Text(initials,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 26, fontWeight: FontWeight.w800,
                          color: Colors.white)),
                    ),
                    const SizedBox(height: 12),
                    Text(user.name,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 18, fontWeight: FontWeight.w700,
                        color: textPrimary)),
                    const SizedBox(height: 2),
                    Text(user.email,
                      style: GoogleFonts.dmSans(
                        fontSize: 13, color: textMuted)),
                  ],
                ),
              ),
              const SizedBox(height: 28),

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
                          Text('Dark Mode',
                            style: GoogleFonts.dmSans(
                              fontSize: 14, fontWeight: FontWeight.w500,
                              color: textPrimary)),
                          const SizedBox(height: 2),
                          Text(isDark ? 'On — deep navy theme' : 'Off — light theme',
                            style: GoogleFonts.dmSans(
                              fontSize: 12, color: textMuted)),
                        ],
                      ),
                      Switch(
                        value: isDark,
                        onChanged: (_) => theme.toggle(),
                        activeThumbColor: AppColors.gold,
                        activeTrackColor: AppColors.gold.withValues(alpha: 0.25),
                        inactiveThumbColor: textMuted,
                        inactiveTrackColor: border,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Account info card
              _card(
                surface: surface, border: border,
                children: [
                  _sectionTitle('ACCOUNT INFO', textMuted),
                  _row('Email', user.email,
                    textMuted: textMuted, textPrimary: textPrimary, border: border),
                  _row('Serial Number', user.serialNumber,
                    textMuted: textMuted, textPrimary: textPrimary, border: border,
                    valueStyle: GoogleFonts.spaceGrotesk(
                      fontSize: 13, color: AppColors.gold,
                      letterSpacing: 1.5,
                      fontFeatures: [const FontFeature.tabularFigures()])),
                  _row('Loyalty Points', '${user.loyaltyPoints} pts',
                    textMuted: textMuted, textPrimary: textPrimary, border: border,
                    valueStyle: GoogleFonts.spaceGrotesk(
                      fontSize: 14, color: AppColors.mint,
                      fontWeight: FontWeight.w700)),
                  _row('Member Since', _formatDate(user.createdAt),
                    textMuted: textMuted, textPrimary: textPrimary, border: border,
                    last: true),
                ],
              ),
              const SizedBox(height: 14),

              // Edit name card
              _card(
                surface: surface, border: border,
                children: [
                  _sectionTitle('EDIT PROFILE', textMuted),
                  Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Display Name',
                          style: GoogleFonts.dmSans(
                            fontSize: 13, fontWeight: FontWeight.w500,
                            color: textDim)),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _nameCtrl,
                          style: GoogleFonts.dmSans(
                            color: textPrimary, fontSize: 15),
                          validator: (v) => (v?.trim().isEmpty ?? true)
                              ? 'Name required' : null,
                          decoration: InputDecoration(
                            hintText: 'Your name',
                            hintStyle: GoogleFonts.dmSans(color: textMuted),
                            filled: true,
                            fillColor: isDark
                                ? Colors.white.withValues(alpha: 0.04)
                                : Colors.black.withValues(alpha: 0.03),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(color: border)),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: AppColors.gold.withValues(alpha: 0.6))),
                            errorBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: AppColors.alert.withValues(alpha: 0.5))),
                            focusedErrorBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: AppColors.alert.withValues(alpha: 0.7))),
                          ),
                        ),

                        if (_status != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: (_status == 'success'
                                  ? AppColors.mint : AppColors.alert)
                                .withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: (_status == 'success'
                                    ? AppColors.mint : AppColors.alert)
                                  .withValues(alpha: 0.35)),
                            ),
                            child: Text(_msg, style: GoogleFonts.dmSans(
                              fontSize: 13,
                              color: _status == 'success'
                                  ? AppColors.mint : AppColors.alert)),
                          ),
                        ],

                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity, height: 48,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: AppColors.goldGlow,
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.gold.withValues(alpha: 0.25),
                                  blurRadius: 14, offset: const Offset(0, 5)),
                              ],
                            ),
                            child: ElevatedButton(
                              onPressed: _loading ? null : _save,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12))),
                              child: _loading
                                  ? const SizedBox(width: 18, height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                  : Text('Save Changes',
                                      style: GoogleFonts.spaceGrotesk(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14, color: Colors.white)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Sign out
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => context.read<AuthProvider>().logout(),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: BorderSide(
                      color: AppColors.alert.withValues(alpha: 0.4)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                    foregroundColor: AppColors.alert,
                  ),
                  child: Text('Sign Out',
                    style: GoogleFonts.spaceGrotesk(
                      fontWeight: FontWeight.w700, fontSize: 14)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card({
    required Color surface,
    required Color border,
    required List<Widget> children,
  }) =>
    Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );

  Widget _sectionTitle(String t, Color textMuted) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Text(t, style: GoogleFonts.spaceGrotesk(
      fontSize: 10, fontWeight: FontWeight.w700,
      color: textMuted, letterSpacing: 2)),
  );

  Widget _row(
    String label, String value, {
    required Color textMuted,
    required Color textPrimary,
    required Color border,
    TextStyle? valueStyle,
    bool last = false,
  }) =>
    Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: GoogleFonts.dmSans(
              fontSize: 13, color: textMuted)),
            Text(value, style: valueStyle ?? GoogleFonts.dmSans(
              fontSize: 14, color: textPrimary, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
      if (!last) Divider(height: 1,
        color: AppColors.border.withValues(alpha: 0.4)),
    ]);

  String _formatDate(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun',
                'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${m[d.month - 1]} ${d.year}';
  }
}
