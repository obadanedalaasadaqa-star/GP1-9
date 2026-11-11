import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/ai_models.dart';
import '../core/api_client.dart';
import '../core/constants.dart';
import '../core/offline_cache.dart';
import '../core/realtime_service.dart';
import '../core/theme_provider.dart';
import '../core/trends.dart';
import '../screens/ai_screen.dart';
import 'offline_banner.dart';

/// The AI insight for this month (same months as Trends). Full mode on the AI
/// page; [compact] is the teaser on Home that opens the page ([onOpen]).
/// Prints no amounts of its own: the server's text already uses formatJd's
/// strings.
class InsightCard extends StatefulWidget {
  final bool compact;
  final VoidCallback? onOpen;
  const InsightCard({super.key, this.compact = false, this.onOpen});

  @override
  State<InsightCard> createState() => InsightCardState();
}

class InsightCardState extends State<InsightCard> {
  Insight? _insight;
  bool _loading = false;
  bool _failed = false;       // nothing to show
  bool _offline = false;      // showing the insight saved on the phone
  bool _updateFailed = false; // slow server or server error, saved one shown
  DateTime? _savedAt;
  int _requestId = 0;         // ignores responses older than the latest load
  ValueListenable<int>? _refreshTick; // live receipts / reconnect / resume

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

  /// A user-started load (pull to refresh, "Try again"). Never throws.
  Future<void> reload() => _load();

  /// [silent]: background refresh; keeps what is shown and shows no spinner.
  /// A user-started load shows the saved insight at once if nothing is shown.
  Future<void> _load({bool silent = false}) async {
    final id = ++_requestId;
    final bounds = monthBounds(DateTime.now());
    try {
      if (!silent && _insight == null) {
        final cached = await OfflineCache.loadInsight();
        if (!mounted || id != _requestId) return;
        setState(() {
          if (cached != null && _insight == null) {
            _insight = cached; // shown without the banner until we know we're offline
          } else if (_insight == null) {
            _loading = true;
          }
          _failed = false;
        });
      }
      final result = await ApiClient.loadInsight(bounds);
      if (!mounted || id != _requestId) return;
      setState(() {
        _insight = result.insight;
        _offline = result.offline;
        _updateFailed = result.stale;
        _savedAt = result.savedAt;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _loading = false;
        if (_insight == null) {
          _failed = true;
        } else {
          _updateFailed = true;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeProvider>().isDark;
    final c = _Colors(isDark);
    return widget.compact ? _buildCompact(c) : _buildFull(c);
  }

  // ── Full mode (AI page) ────────────────────────────────────────────────────

  Widget _buildFull(_Colors c) {
    final insight = _insight;
    final Widget body;
    if (insight == null && (_loading || !_failed)) {
      body = Row(children: [
        const SizedBox(width: 18, height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold)),
        const SizedBox(width: 12),
        Text('Reading your spending…', style: GoogleFonts.dmSans(fontSize: 13.5, color: c.muted)),
      ]);
    } else if (insight == null) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text("Couldn't load your insight.", style: GoogleFonts.dmSans(fontSize: 14, color: c.primary)),
        const SizedBox(height: 6),
        TextButton(
          onPressed: reload,
          style: TextButton.styleFrom(foregroundColor: AppColors.gold, padding: EdgeInsets.zero),
          child: const Text('Try again'),
        ),
      ]);
    } else if (insight.status == InsightStatus.notEnoughData) {
      body = Text(
        'Your first insight appears after ${insight.minReceipts} receipts. '
        'You have ${insight.receiptCount} so far.',
        style: GoogleFonts.dmSans(fontSize: 14, color: c.primary, height: 1.5));
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(insight.summary, style: GoogleFonts.dmSans(fontSize: 14.5, color: c.primary, height: 1.55)),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.lightbulb_rounded, color: AppColors.mint, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(insight.tip,
            style: GoogleFonts.dmSans(fontSize: 13.5, color: c.primary, height: 1.5))),
        ]),
        const SizedBox(height: 14),
        Text(
          insight.createdAt == null
              ? 'AI-generated'
              : 'AI-generated · updated ${OfflineBanner.ago(insight.createdAt!)}',
          style: GoogleFonts.dmSans(fontSize: 11.5, color: c.muted)),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_offline && insight != null) ...[
        OfflineBanner(savedAt: _savedAt, what: 'insight'),
        const SizedBox(height: 12),
      ],
      _frame(c, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(c, 'This month'),
        const SizedBox(height: 14),
        body,
        if (_updateFailed && !_offline && insight != null) ...[
          const SizedBox(height: 10),
          Text("Couldn't update the insight right now.",
            style: GoogleFonts.dmSans(fontSize: 12, color: c.muted)),
        ],
      ])),
    ]);
  }

  // ── Compact mode (Home teaser) ─────────────────────────────────────────────

  Widget _buildCompact(_Colors c) {
    final insight = _insight;
    final Widget line;
    if (insight == null && (_loading || !_failed)) {
      line = const Align(alignment: Alignment.centerLeft,
        child: SizedBox(width: 16, height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold)));
    } else if (insight == null) {
      line = Text("Couldn't load your insight.", style: GoogleFonts.dmSans(fontSize: 13, color: c.muted));
    } else if (insight.status == InsightStatus.notEnoughData) {
      line = Text('Your first insight appears after ${insight.minReceipts} receipts.',
        maxLines: 2, overflow: TextOverflow.ellipsis,
        style: GoogleFonts.dmSans(fontSize: 13, color: c.muted));
    } else {
      line = Text(insight.summary, maxLines: 3, overflow: TextOverflow.ellipsis,
        style: GoogleFonts.dmSans(fontSize: 13.5, color: c.primary, height: 1.45));
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: widget.onOpen,
        child: _frame(c, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: _title(c, 'AI insight')),
            Icon(Icons.chevron_right_rounded, color: c.muted),
          ]),
          const SizedBox(height: 10),
          line,
          if (_offline && insight != null) ...[
            const SizedBox(height: 8),
            Text('Offline · saved insight', style: GoogleFonts.dmSans(fontSize: 11.5, color: c.muted)),
          ],
          const SizedBox(height: 12),
          Row(children: [
            _chip(c, 'Open', Icons.open_in_new_rounded, widget.onOpen),
            const SizedBox(width: 8),
            _chip(c, 'Ask AI', Icons.chat_bubble_outline_rounded,
              () => AiScreen.open(context, tab: AiTab.ask)),
          ]),
        ])),
      ),
    );
  }

  // ── Pieces ─────────────────────────────────────────────────────────────────

  Widget _frame(_Colors c, {required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
    decoration: BoxDecoration(
      color: c.surface,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: c.border),
    ),
    child: child,
  );

  Widget _title(_Colors c, String text) => Row(children: [
    ShaderMask(
      shaderCallback: (b) => AppColors.goldGlow.createShader(b),
      child: const Icon(Icons.auto_awesome_rounded, size: 18, color: Colors.white),
    ),
    const SizedBox(width: 8),
    Text(text, style: GoogleFonts.spaceGrotesk(fontSize: 14, fontWeight: FontWeight.w700, color: c.primary)),
  ]);

  // A plain pill instead of ActionChip: ActionChip clipped the "Open" label
  // (seen in the Simulator), this sizes itself to the text.
  Widget _chip(_Colors c, String label, IconData icon, VoidCallback? onTap) => Material(
    color: AppColors.gold.withValues(alpha: 0.08),
    shape: StadiumBorder(side: BorderSide(color: AppColors.gold.withValues(alpha: 0.3))),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: AppColors.gold),
          const SizedBox(width: 6),
          Text(label, style: GoogleFonts.dmSans(fontSize: 12, fontWeight: FontWeight.w600, color: c.primary)),
        ]),
      ),
    ),
  );
}

class _Colors {
  final Color surface, border, primary, muted;
  _Colors(bool isDark)
      : surface = isDark ? AppColors.surface : AppColors.surfaceLight,
        border = isDark ? AppColors.border : AppColors.borderLight,
        primary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight,
        muted = isDark ? AppColors.textMuted : AppColors.textMutedLight;
}
