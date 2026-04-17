import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/constants.dart';
import '../core/receipt_model.dart';
import '../core/theme_provider.dart';

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key});
  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  List<Receipt> _receipts = [];
  bool _loading = true;
  String? _error;

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
    setState(() { _loading = true; _error = null; });
    try {
      final receipts = await ApiClient.getReceipts();
      if (mounted) setState(() { _receipts = receipts; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark      = context.watch<ThemeProvider>().isDark;
    final bg          = isDark ? AppColors.bg      : AppColors.bgLight;
    final surface     = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border      = isDark ? AppColors.border  : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted   : AppColors.textMutedLight;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: _loading
            ? _buildLoading(bg)
            : _error != null
                ? _buildError(textPrimary, textMuted)
                : _receipts.isEmpty
                    ? _buildEmpty(textPrimary, textMuted)
                    : _buildContent(surface, border, textPrimary, textMuted),
      ),
    );
  }

  // ── Loading ────────────────────────────────────────────────────────────────

  Widget _buildLoading(Color bg) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ShaderMask(
          shaderCallback: (b) => AppColors.goldGlow.createShader(b),
          child: Text('ARCHIVE',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 14, fontWeight: FontWeight.w700,
              color: Colors.white, letterSpacing: 3)),
        ),
        const SizedBox(height: 20),
        const SizedBox(width: 22, height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2, color: AppColors.gold)),
      ],
    ),
  );

  // ── Error ──────────────────────────────────────────────────────────────────

  Widget _buildError(Color textPrimary, Color textMuted) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off_rounded, color: AppColors.alert, size: 40),
          const SizedBox(height: 16),
          Text('Could not load receipts',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 16, fontWeight: FontWeight.w700, color: textPrimary)),
          const SizedBox(height: 8),
          Text(_error ?? '', textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: _load,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                gradient: AppColors.goldGlow,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('Retry',
                style: GoogleFonts.spaceGrotesk(
                  fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ],
      ),
    ),
  );

  // ── Empty state ────────────────────────────────────────────────────────────

  Widget _buildEmpty(Color textPrimary, Color textMuted) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShaderMask(
            shaderCallback: (b) => AppColors.goldGlow.createShader(b),
            child: const Icon(Icons.receipt_long_rounded,
              size: 48, color: Colors.white),
          ),
          const SizedBox(height: 16),
          Text('No receipts yet',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 18, fontWeight: FontWeight.w700, color: textPrimary)),
          const SizedBox(height: 8),
          Text('Your receipts will appear here\nafter visiting a Nexus-enabled store.',
            textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(fontSize: 13, color: textMuted, height: 1.6)),
        ],
      ),
    ),
  );

  // ── Main content ───────────────────────────────────────────────────────────

  Widget _buildContent(Color surface, Color border,
      Color textPrimary, Color textMuted) {
    final totals = Receipt.totalsByCategory(_receipts);
    final maxAmt = totals.isEmpty ? 1.0
        : totals.values.reduce((a, b) => a > b ? a : b);

    final now = DateTime.now();
    final monthName = ['Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'][now.month - 1];

    return CustomScrollView(
      slivers: [
        // Header
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Archive',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 28, fontWeight: FontWeight.w800,
                        color: textPrimary, letterSpacing: -0.5)),
                    // Refresh button
                    GestureDetector(
                      onTap: _load,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.gold.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: AppColors.gold.withValues(alpha: 0.3)),
                        ),
                        child: const Icon(Icons.refresh_rounded,
                          color: AppColors.gold, size: 18),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text('${_receipts.length} receipt${_receipts.length == 1 ? '' : 's'} · synced from your account',
                  style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
                const SizedBox(height: 24),

                if (totals.isNotEmpty) ...[
                  // Chart card
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Spending by Category',
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 14, fontWeight: FontWeight.w700,
                                color: textPrimary)),
                            ShaderMask(
                              shaderCallback: (b) =>
                                AppColors.goldGlow.createShader(b),
                              child: Text('$monthName ${now.year}',
                                style: GoogleFonts.dmSans(
                                  fontSize: 12, fontWeight: FontWeight.w600,
                                  color: Colors.white)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        _BarChart(
                          totals: totals,
                          maxAmt: maxAmt,
                          categoryColors: _categoryColors,
                          textMuted: textMuted,
                        ),
                        const SizedBox(height: 16),
                        Divider(height: 1,
                          color: border.withValues(alpha: 0.6)),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 12, runSpacing: 8,
                          children: totals.entries.map((e) {
                            final color = _categoryColors[e.key]
                                ?? AppColors.textMuted;
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 8, height: 8,
                                  decoration: BoxDecoration(
                                    color: color, shape: BoxShape.circle)),
                                const SizedBox(width: 5),
                                Text('${e.key}  ${e.value.toStringAsFixed(0)} JD',
                                  style: GoogleFonts.dmSans(
                                    fontSize: 11, color: textMuted)),
                              ],
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                Text('RECEIPTS',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 11, fontWeight: FontWeight.w700,
                    color: textMuted, letterSpacing: 2)),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),

        // Receipt list
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => _ReceiptTile(
                receipt: _receipts[i],
                surface: surface,
                border: border,
                textPrimary: textPrimary,
                textMuted: textMuted,
                catColor: _categoryColors[_receipts[i].category]
                    ?? AppColors.textMuted,
              ),
              childCount: _receipts.length,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Bar chart ─────────────────────────────────────────────────────────────────

class _BarChart extends StatelessWidget {
  final Map<String, double> totals;
  final double maxAmt;
  final Map<String, Color> categoryColors;
  final Color textMuted;

  const _BarChart({
    required this.totals,
    required this.maxAmt,
    required this.categoryColors,
    required this.textMuted,
  });

  @override
  Widget build(BuildContext context) {
    const chartHeight = 120.0;
    final entries = totals.entries.toList();

    return SizedBox(
      height: chartHeight + 36,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: entries.map((e) {
          final frac  = e.value / maxAmt;
          final color = categoryColors[e.key] ?? AppColors.textMuted;
          final barH  = chartHeight * frac;
          final abbr  = e.key.length > 4 ? e.key.substring(0, 4) : e.key;

          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(e.value.toStringAsFixed(0),
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 9, fontWeight: FontWeight.w700, color: color)),
                  const SizedBox(height: 4),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOut,
                    height: barH,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          color.withValues(alpha: 0.5),
                          color,
                        ],
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                      ),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(6)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(abbr,
                    style: GoogleFonts.dmSans(fontSize: 9, color: textMuted)),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Receipt tile ──────────────────────────────────────────────────────────────

class _ReceiptTile extends StatelessWidget {
  final Receipt receipt;
  final Color surface;
  final Color border;
  final Color textPrimary;
  final Color textMuted;
  final Color catColor;

  const _ReceiptTile({
    required this.receipt,
    required this.surface,
    required this.border,
    required this.textPrimary,
    required this.textMuted,
    required this.catColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          // Category icon circle
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: catColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(_catIcon(receipt.category), color: catColor, size: 20),
          ),
          const SizedBox(width: 14),

          // Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(receipt.storeName,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 14, fontWeight: FontWeight.w700,
                    color: textPrimary)),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: catColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(receipt.category,
                        style: GoogleFonts.dmSans(
                          fontSize: 10, fontWeight: FontWeight.w600,
                          color: catColor)),
                    ),
                    const SizedBox(width: 8),
                    Text(_formatDate(receipt.date),
                      style: GoogleFonts.dmSans(fontSize: 11, color: textMuted)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(receipt.items.take(3).join(' · '),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.dmSans(fontSize: 11, color: textMuted)),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // Amount
          Text('${receipt.totalAmount.toStringAsFixed(2)} JD',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 15, fontWeight: FontWeight.w800, color: catColor)),
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
    return '${d.day} ${m[d.month - 1]}';
  }
}
