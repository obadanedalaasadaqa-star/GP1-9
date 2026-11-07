import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/receipt_model.dart';
import '../core/theme_provider.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Receipt> _receipts = [];
  bool _loading = true;

  static const _categoryColors = {
    'Supermarket': AppColors.blue,
    'Food':        AppColors.mint,
    'Pharmacy':    AppColors.violet,
    'Clothing':    AppColors.gold,
    'Electronics': AppColors.blueLight,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final receipts = await ApiClient.getReceipts();
      if (mounted) setState(() { _receipts = receipts; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Month totals
  double get _monthTotal {
    final now = DateTime.now();
    return _receipts
        .where((r) => r.date.year == now.year && r.date.month == now.month)
        .fold(0.0, (sum, r) => sum + r.totalAmount);
  }

  int get _monthCount {
    final now = DateTime.now();
    return _receipts
        .where((r) => r.date.year == now.year && r.date.month == now.month)
        .length;
  }

  // Today's receipts
  List<Receipt> get _todayReceipts {
    final now = DateTime.now();
    return _receipts
        .where((r) =>
            r.date.year == now.year &&
            r.date.month == now.month &&
            r.date.day == now.day)
        .toList();
  }

  // Recent activity (up to 5, excluding today)
  List<Receipt> get _recentReceipts {
    final now = DateTime.now();
    return _receipts
        .where((r) => !(r.date.year == now.year &&
            r.date.month == now.month &&
            r.date.day == now.day))
        .take(5)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final user       = context.watch<AuthProvider>().user;
    if (user == null) return const SizedBox.shrink();
    final isDark     = context.watch<ThemeProvider>().isDark;
    final firstName  = user.firstName;

    final bg          = isDark ? AppColors.bg      : AppColors.bgLight;
    final surface     = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border      = isDark ? AppColors.border  : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted   : AppColors.textMutedLight;

    final now = DateTime.now();
    final monthName = ['Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'][now.month - 1];

    return Scaffold(
      backgroundColor: bg,
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(-0.6, -0.9),
            radius: 1.3,
            colors: [
              AppColors.mint.withValues(alpha: isDark ? 0.05 : 0.03),
              bg,
            ],
          ),
        ),
        child: SafeArea(
          child: RefreshIndicator(
            color: AppColors.gold,
            backgroundColor: surface,
            onRefresh: _load,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  // ── Greeting row ──────────────────────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Good day,',
                            style: GoogleFonts.dmSans(
                              fontSize: 13, color: textMuted)),
                          const SizedBox(height: 2),
                          Text(firstName,
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 28, fontWeight: FontWeight.w800,
                              color: textPrimary, letterSpacing: -0.5)),
                        ],
                      ),
                      // Loyalty badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          gradient: AppColors.goldGlow,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.gold.withValues(alpha: 0.3),
                              blurRadius: 12, offset: const Offset(0, 4)),
                          ],
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.star_rounded,
                              color: Colors.white, size: 14),
                            const SizedBox(width: 5),
                            Text('${user.loyaltyPoints} pts',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 12, fontWeight: FontWeight.w700,
                                color: Colors.white)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('Your spending overview for $monthName ${now.year}',
                    style: GoogleFonts.dmSans(
                      fontSize: 13, color: textMuted)),
                  const SizedBox(height: 24),

                  // ── Active Wallet card ────────────────────────────────────
                  _WalletCard(
                    monthTotal: _monthTotal,
                    monthCount: _monthCount,
                    monthName: monthName,
                    year: now.year,
                    surface: surface,
                    border: border,
                    textPrimary: textPrimary,
                    textMuted: textMuted,
                    isDark: isDark,
                    loading: _loading,
                  ),
                  const SizedBox(height: 24),

                  // ── Today's receipts ──────────────────────────────────────
                  _SectionLabel(
                    label: "TODAY'S RECEIPTS",
                    textMuted: textMuted,
                  ),
                  const SizedBox(height: 12),

                  if (_loading)
                    _buildMiniLoader()
                  else if (_todayReceipts.isEmpty)
                    _buildTodayEmpty(surface, border, textPrimary, textMuted)
                  else
                    ..._todayReceipts.map((r) => _CompactReceiptTile(
                      receipt: r,
                      catColor: _categoryColors[r.category] ?? AppColors.textMuted,
                      surface: surface,
                      border: border,
                      textPrimary: textPrimary,
                      textMuted: textMuted,
                    )),

                  const SizedBox(height: 24),

                  // ── Recent activity ───────────────────────────────────────
                  _SectionLabel(
                    label: 'RECENT ACTIVITY',
                    textMuted: textMuted,
                  ),
                  const SizedBox(height: 12),

                  if (_loading)
                    _buildMiniLoader()
                  else if (_recentReceipts.isEmpty)
                    _buildRecentEmpty(surface, border, textPrimary, textMuted)
                  else
                    ..._recentReceipts.map((r) => _CompactReceiptTile(
                      receipt: r,
                      catColor: _categoryColors[r.category] ?? AppColors.textMuted,
                      surface: surface,
                      border: border,
                      textPrimary: textPrimary,
                      textMuted: textMuted,
                    )),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMiniLoader() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Center(
      child: SizedBox(
        width: 20, height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.gold,
        ),
      ),
    ),
  );

  Widget _buildTodayEmpty(Color surface, Color border,
      Color textPrimary, Color textMuted) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: AppColors.gold.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.receipt_long_rounded,
              color: AppColors.gold, size: 18),
          ),
          const SizedBox(width: 14),
          Text('No receipts today',
            style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
        ],
      ),
    );

  Widget _buildRecentEmpty(Color surface, Color border,
      Color textPrimary, Color textMuted) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: AppColors.blue.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.history_rounded,
              color: AppColors.blue, size: 18),
          ),
          const SizedBox(width: 14),
          Text('No recent activity',
            style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
        ],
      ),
    );
}

// ── Active Wallet Card ────────────────────────────────────────────────────────

class _WalletCard extends StatelessWidget {
  final double monthTotal;
  final int    monthCount;
  final String monthName;
  final int    year;
  final Color  surface;
  final Color  border;
  final Color  textPrimary;
  final Color  textMuted;
  final bool   isDark;
  final bool   loading;

  const _WalletCard({
    required this.monthTotal,
    required this.monthCount,
    required this.monthName,
    required this.year,
    required this.surface,
    required this.border,
    required this.textPrimary,
    required this.textMuted,
    required this.isDark,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 22),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            color: AppColors.gold.withValues(alpha: isDark ? 0.08 : 0.05),
            blurRadius: 28, offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // Header row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      gradient: AppColors.goldGlow,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.account_balance_wallet_rounded,
                      color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Text('Active Wallet',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 14, fontWeight: FontWeight.w700,
                      color: textPrimary)),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.gold.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: AppColors.gold.withValues(alpha: 0.25)),
                ),
                child: Text('$monthName $year',
                  style: GoogleFonts.dmSans(
                    fontSize: 11, fontWeight: FontWeight.w600,
                    color: AppColors.gold)),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Amount
          loading
              ? Container(
                  width: 140, height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.gold.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                )
              : ShaderMask(
                  shaderCallback: (b) => AppColors.goldGlow.createShader(b),
                  child: Text(
                    '${monthTotal.toStringAsFixed(2)} JD',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 38, fontWeight: FontWeight.w800,
                      color: Colors.white, letterSpacing: -1),
                  ),
                ),
          const SizedBox(height: 8),

          // Subtitle
          loading
              ? Container(
                  width: 100, height: 16,
                  decoration: BoxDecoration(
                    color: AppColors.gold.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(4),
                  ),
                )
              : Text(
                  monthCount == 0
                      ? 'No receipts this month'
                      : 'across $monthCount receipt${monthCount == 1 ? '' : 's'} this month',
                  style: GoogleFonts.dmSans(
                    fontSize: 13, color: textMuted)),
        ],
      ),
    );
  }
}

// ── Section label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  final Color  textMuted;
  const _SectionLabel({required this.label, required this.textMuted});

  @override
  Widget build(BuildContext context) =>
    Text(label,
      style: GoogleFonts.spaceGrotesk(
        fontSize: 11, fontWeight: FontWeight.w700,
        color: textMuted, letterSpacing: 2));
}

// ── Compact receipt tile ──────────────────────────────────────────────────────

class _CompactReceiptTile extends StatelessWidget {
  final Receipt receipt;
  final Color   catColor;
  final Color   surface;
  final Color   border;
  final Color   textPrimary;
  final Color   textMuted;

  const _CompactReceiptTile({
    required this.receipt,
    required this.catColor,
    required this.surface,
    required this.border,
    required this.textPrimary,
    required this.textMuted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          // Icon circle
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: catColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(_catIcon(receipt.category), color: catColor, size: 18),
          ),
          const SizedBox(width: 12),

          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(receipt.storeName,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 13, fontWeight: FontWeight.w700,
                    color: textPrimary)),
                const SizedBox(height: 2),
                Text(_formatDate(receipt.date),
                  style: GoogleFonts.dmSans(
                    fontSize: 11, color: textMuted)),
              ],
            ),
          ),

          // Amount
          Text('${receipt.totalAmount.toStringAsFixed(2)} JD',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 14, fontWeight: FontWeight.w800,
              color: catColor)),
        ],
      ),
    );
  }

  IconData _catIcon(String cat) {
    switch (cat) {
      case 'Supermarket': return Icons.shopping_cart_rounded;
      case 'Food':        return Icons.restaurant_rounded;
      case 'Pharmacy':    return Icons.local_pharmacy_rounded;
      case 'Clothing':    return Icons.checkroom_rounded;
      case 'Electronics': return Icons.devices_rounded;
      default:            return Icons.receipt_long_rounded;
    }
  }

  String _formatDate(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun',
                'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }
}
