import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/constants.dart';
import '../core/money.dart';
import '../core/offline_cache.dart';
import '../core/realtime_service.dart';
import '../core/stats_model.dart';
import '../core/theme_provider.dart';
import '../core/trends.dart';
import '../widgets/offline_banner.dart';
import 'ai_screen.dart';

/// Trends tab: this month vs last month, the last 6 months, categories,
/// biggest store and average receipt. Uses the same month periods as the
/// Archive, so the totals always match.
class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key});
  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  SpendingStats? _stats;
  bool _loading = true;
  String? _error;
  bool _offline = false;     // showing stats saved on the phone
  DateTime? _savedAt;
  int _requestId = 0; // ignores responses older than the latest load
  ValueListenable<int>? _refreshTick; // live receipts / reconnect / resume

  static const _months = ['Jan','Feb','Mar','Apr','May','Jun',
                          'Jul','Aug','Sep','Oct','Nov','Dec'];
  static const _monthsLong = ['January','February','March','April','May','June',
                              'July','August','September','October','November','December'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_refreshTick == null) {
      _refreshTick = context.read<RealtimeService?>()?.refreshTick;
      _refreshTick?.addListener(_silentLoad);
    }
  }

  @override
  void dispose() {
    _refreshTick?.removeListener(_silentLoad);
    super.dispose();
  }

  void _silentLoad() => _load(silent: true);

  /// [silent]: background refresh (live receipt, reconnect, resume). It never
  /// shows a spinner or a message; a failure keeps what is on screen.
  /// User-started loads (opening the tab, refresh, Retry) show the saved stats
  /// at once if nothing is on screen yet, and refresh numbers in place.
  Future<void> _load({bool silent = false}) async {
    final id = ++_requestId;
    final bounds = monthBounds(DateTime.now()); // picks up a month rollover
    if (!silent && _stats == null) {
      final cached = await OfflineCache.loadStats();
      if (!mounted || id != _requestId) return;
      setState(() {
        if (cached != null && _stats == null) {
          _stats = cached; // shown without the banner until we know we're offline
          _loading = false;
        } else if (_stats == null) {
          _loading = true;
        }
        _error = null;
      });
    }
    try {
      final result = await ApiClient.loadStats(bounds);
      if (mounted && id == _requestId) {
        setState(() {
          _stats   = result.stats;
          _offline = result.offline;
          _savedAt = result.savedAt;
          _loading = false;
          _error   = null;
        });
      }
    } catch (e) {
      if (!mounted || id != _requestId) return;
      if (_stats == null) {
        // Nothing to show: the full error screen with Retry.
        setState(() { _error = e.toString(); _loading = false; });
      } else if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())));
      }
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
    final stats       = _stats;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildHeader(textPrimary)),
            if (_loading)
              SliverToBoxAdapter(child: _buildLoading())
            else if (_error != null || stats == null)
              SliverToBoxAdapter(child: _buildError(textPrimary, textMuted))
            else if (!stats.hasAnyReceipts)
              SliverToBoxAdapter(child: _buildEmpty(textPrimary, textMuted))
            else
              SliverToBoxAdapter(
                child: _buildContent(stats, surface, border, textPrimary, textMuted)),
          ],
        ),
      ),
    );
  }

  // ── Header: title, refresh, offline banner ─────────────────────────────────

  Widget _buildHeader(Color textPrimary) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Trends',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 28, fontWeight: FontWeight.w800,
                color: textPrimary, letterSpacing: -0.5)),
            Row(
              children: [
                // AI page
                Tooltip(
                  message: 'AI insights',
                  child: GestureDetector(
                    onTap: () => AiScreen.open(context),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.gold.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: AppColors.gold.withValues(alpha: 0.3)),
                      ),
                      child: const Icon(Icons.auto_awesome_rounded,
                        color: AppColors.gold, size: 18),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
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
          ],
        ),
        if (!_loading && _error == null && _offline) ...[
          const SizedBox(height: 14),
          OfflineBanner(savedAt: _savedAt, what: 'trends'),
        ],
      ],
    ),
  );

  // ── Loading ────────────────────────────────────────────────────────────────

  Widget _buildLoading() => const Padding(
    padding: EdgeInsets.only(top: 60),
    child: Center(
      child: SizedBox(width: 22, height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2, color: AppColors.gold)),
    ),
  );

  // ── Error ──────────────────────────────────────────────────────────────────

  Widget _buildError(Color textPrimary, Color textMuted) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
    child: Column(
      children: [
        const Icon(Icons.wifi_off_rounded, color: AppColors.alert, size: 40),
        const SizedBox(height: 16),
        Text('Could not load trends',
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
  );

  // ── Empty state ────────────────────────────────────────────────────────────

  Widget _buildEmpty(Color textPrimary, Color textMuted) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
    child: Column(
      children: [
        ShaderMask(
          shaderCallback: (b) => AppColors.goldGlow.createShader(b),
          child: const Icon(Icons.insights_rounded,
            size: 48, color: Colors.white),
        ),
        const SizedBox(height: 16),
        Text('No spending yet',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 18, fontWeight: FontWeight.w700, color: textPrimary)),
        const SizedBox(height: 8),
        Text('Your trends appear after your first Nexus receipt.',
          textAlign: TextAlign.center,
          style: GoogleFonts.dmSans(fontSize: 13, color: textMuted, height: 1.6)),
      ],
    ),
  );

  // ── Main content: 4 cards ──────────────────────────────────────────────────

  /// Spending up is red, down is mint (less spending is good); "—"/"0%" muted.
  static Color _changeColor(String change, Color textMuted) {
    if (change == '—' || change == '0%') return textMuted;
    return change.startsWith('−') ? AppColors.mint : AppColors.alert;
  }

  Widget _chip(String change, Color textMuted, {String? suffix}) {
    final color = _changeColor(change, textMuted);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(suffix == null ? change : '$change $suffix',
        style: GoogleFonts.dmSans(
          fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _card(Color surface, Color border, {required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
    decoration: BoxDecoration(
      color: surface,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: border),
    ),
    child: child,
  );

  Widget _cardTitle(String text, Color textPrimary) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Text(text,
      style: GoogleFonts.spaceGrotesk(
        fontSize: 14, fontWeight: FontWeight.w700, color: textPrimary)),
  );

  Widget _buildContent(SpendingStats stats, Color surface, Color border,
      Color textPrimary, Color textMuted) {
    final current  = stats.current;
    final previous = stats.previous;
    final now      = DateTime.now();
    final isNow    = !now.isBefore(current.from) && now.isBefore(current.to);
    final label    = isNow
        ? '${_monthsLong[current.from.month - 1]} so far'
        : '${_monthsLong[current.from.month - 1]} ${current.from.year}';
    final vs       = previous == null ? null : 'vs ${_monthsLong[previous.from.month - 1]}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. This month
          _card(surface, border, child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label.toUpperCase(),
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 11, fontWeight: FontWeight.w700,
                  color: textMuted, letterSpacing: 2)),
              const SizedBox(height: 10),
              Text('${formatJd(current.total)} JD',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 34, fontWeight: FontWeight.w800,
                  color: textPrimary, letterSpacing: -0.5)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10, runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (previous != null)
                    _chip(formatChange(percentChange(current.total, previous.total)),
                      textMuted, suffix: vs),
                  Text('${current.count} receipt${current.count == 1 ? '' : 's'}',
                    style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
                ],
              ),
            ],
          )),
          const SizedBox(height: 16),

          // 2. Last 6 months
          _card(surface, border, child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cardTitle('Last ${stats.periods.length} months', textPrimary),
              _MonthChart(periods: stats.periods, months: _months, textMuted: textMuted),
            ],
          )),
          const SizedBox(height: 16),

          // 3. By category
          _card(surface, border, child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cardTitle('By category', textPrimary),
              for (final c in categoryChanges(current, previous))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Container(
                        width: 10, height: 10,
                        decoration: BoxDecoration(
                          color: CategoryColors.of(c.category),
                          shape: BoxShape.circle)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(c.category,
                          style: GoogleFonts.dmSans(
                            fontSize: 14, fontWeight: FontWeight.w600,
                            color: textPrimary)),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('${formatJd(c.current)} JD',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 14, fontWeight: FontWeight.w700,
                              color: textPrimary)),
                          if (previous != null)
                            Text('${formatJd(c.previous)} JD',
                              style: GoogleFonts.dmSans(fontSize: 11, color: textMuted)),
                        ],
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 64,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _chip(formatChange(c.pct), textMuted)),
                      ),
                    ],
                  ),
                ),
            ],
          )),
          const SizedBox(height: 16),

          // 4. Highlights
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _card(surface, border, child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _tileTitle('Biggest store', textMuted),
                    Text(current.topStore?.storeName ?? '—',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 17, fontWeight: FontWeight.w800,
                        color: textPrimary)),
                    const SizedBox(height: 6),
                    Text(
                      current.topStore == null
                          ? 'No receipts this month'
                          : '${formatJd(current.topStore!.total)} JD · '
                            '${current.topStore!.count} visit${current.topStore!.count == 1 ? '' : 's'}',
                      style: GoogleFonts.dmSans(fontSize: 12, color: textMuted)),
                  ],
                ))),
                const SizedBox(width: 12),
                Expanded(child: _card(surface, border, child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _tileTitle('Average receipt', textMuted),
                    Text('${formatJd(current.average)} JD',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 17, fontWeight: FontWeight.w800,
                        color: textPrimary)),
                    const SizedBox(height: 8),
                    if (previous != null)
                      _chip(formatChange(percentChange(current.average, previous.average)),
                        textMuted, suffix: 'vs last month'),
                  ],
                ))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tileTitle(String text, Color textMuted) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(text.toUpperCase(),
      style: GoogleFonts.spaceGrotesk(
        fontSize: 10, fontWeight: FontWeight.w700,
        color: textMuted, letterSpacing: 1.5)),
  );
}

// ── Month bar chart ───────────────────────────────────────────────────────────

class _MonthChart extends StatelessWidget {
  final List<PeriodStats> periods;
  final List<String> months;
  final Color textMuted;

  const _MonthChart({
    required this.periods,
    required this.months,
    required this.textMuted,
  });

  @override
  Widget build(BuildContext context) {
    const chartHeight = 120.0;
    final maxAmt = periods.fold<double>(0, (m, p) => p.total > m ? p.total : m);

    return SizedBox(
      height: chartHeight + 36,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < periods.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(formatJd(periods[i].total, decimals: 0),
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 9, fontWeight: FontWeight.w700,
                        color: i == periods.length - 1 ? AppColors.gold : textMuted)),
                    const SizedBox(height: 4),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 600),
                      curve: Curves.easeOut,
                      height: maxAmt == 0 ? 0 : chartHeight * periods[i].total / maxAmt,
                      decoration: BoxDecoration(
                        gradient: i == periods.length - 1 ? AppColors.goldGlow : null,
                        color: i == periods.length - 1
                            ? null : AppColors.gold.withValues(alpha: 0.3),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(6)),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(months[periods[i].from.month - 1],
                      style: GoogleFonts.dmSans(fontSize: 9, color: textMuted)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
