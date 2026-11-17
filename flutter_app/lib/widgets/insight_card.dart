import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/ai_models.dart';
import '../core/api_client.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/offline_cache.dart';
import '../core/realtime_service.dart';
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
    final nx = Nx.of(context);
    return widget.compact ? _buildCompact(nx) : _buildFull(nx);
  }

  // ── Full mode (AI page) ────────────────────────────────────────────────────

  Widget _buildFull(Nx nx) {
    const ink = AppColors.ink;
    const muted = AppColors.textMutedLight;
    final insight = _insight;
    final Widget body;
    if (insight == null && (_loading || !_failed)) {
      body = Row(children: [
        const SizedBox(width: 18, height: 18,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.cobalt)),
        const SizedBox(width: 12),
        Text('Reading your spending…', style: NxType.body(14, color: muted)),
      ]);
    } else if (insight == null) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text("Couldn't load your insight.",
          style: NxType.display(18, color: ink, weight: FontWeight.w700)),
        const SizedBox(height: 6),
        TextButton(
          onPressed: reload,
          style: TextButton.styleFrom(foregroundColor: AppColors.cobalt, padding: EdgeInsets.zero),
          child: const Text('Try again'),
        ),
      ]);
    } else if (insight.status == InsightStatus.notEnoughData) {
      body = Text(
        'Your first insight appears after ${insight.minReceipts} receipts. '
        'You have ${insight.receiptCount} so far.',
        style: NxType.display(19, color: ink, weight: FontWeight.w700, height: 1.25,
          letterSpacing: -0.3));
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(insight.summary,
          style: NxType.display(20, color: ink, weight: FontWeight.w700,
            height: 1.25, letterSpacing: -0.3)),
        const SizedBox(height: 14),
        const DashedRule(color: ink),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(6)),
            child: Text('TIP', style: NxType.mono(10.5, color: Colors.white,
              weight: FontWeight.w500, letterSpacing: 1)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(insight.tip,
            style: NxType.body(14, color: ink, height: 1.45))),
        ]),
        const SizedBox(height: 14),
        Text(
          insight.createdAt == null
              ? 'AI-generated'
              : 'AI-generated · updated ${OfflineBanner.ago(insight.createdAt!)}',
          style: NxType.mono(11, color: muted)),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_offline && insight != null) ...[
        OfflineBanner(savedAt: _savedAt, what: 'insight'),
        const SizedBox(height: 12),
      ],
      Padding(
        padding: const EdgeInsets.only(right: 6, bottom: 6),
        child: NxCard(
          tilt: -1,
          color: Colors.white,
          borderColor: ink,
          shadowColor: nx.dark ? AppColors.lime : ink,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('This month', style: NxType.label(muted)),
            const SizedBox(height: 10),
            body,
            if (_updateFailed && !_offline && insight != null) ...[
              const SizedBox(height: 10),
              Text("Couldn't update the insight right now.",
                style: NxType.body(12, color: muted)),
            ],
          ]),
        ),
      ),
    ]);
  }

  // ── Compact mode (Home teaser) ─────────────────────────────────────────────

  Widget _buildCompact(Nx nx) {
    const ink = AppColors.ink;
    final insight = _insight;
    final Widget line;
    if (insight == null && (_loading || !_failed)) {
      line = const Align(alignment: Alignment.centerLeft,
        child: SizedBox(width: 16, height: 16,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: ink)));
    } else if (insight == null) {
      line = Text("Couldn't load your insight.", style: NxType.body(13.5, color: ink));
    } else if (insight.status == InsightStatus.notEnoughData) {
      line = Text('Your first insight appears after ${insight.minReceipts} receipts.',
        maxLines: 2, overflow: TextOverflow.ellipsis,
        style: NxType.display(16, color: ink, weight: FontWeight.w700,
          height: 1.2, letterSpacing: -0.2));
    } else {
      line = Text(insight.summary, maxLines: 3, overflow: TextOverflow.ellipsis,
        style: NxType.display(16, color: ink, weight: FontWeight.w700,
          height: 1.2, letterSpacing: -0.2));
    }

    return NxCard(
      color: AppColors.pink,
      borderColor: ink,
      shadow: 0,
      padding: const EdgeInsets.fromLTRB(16, 13, 14, 14),
      onTap: widget.onOpen,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('AI insight', style: NxType.mono(11, color: ink, letterSpacing: 1.5)),
              const SizedBox(height: 4),
              line,
              if (_offline && insight != null) ...[
                const SizedBox(height: 6),
                Text('Offline · saved insight', style: NxType.mono(11, color: ink)),
              ],
            ]),
          ),
          const SizedBox(width: 12),
          Container(
            width: 36, height: 36,
            decoration: const BoxDecoration(color: ink, shape: BoxShape.circle),
            child: const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 18),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          _chip('Open', Icons.open_in_new_rounded, widget.onOpen),
          const SizedBox(width: 8),
          _chip('Ask AI', Icons.chat_bubble_outline_rounded,
            () => AiScreen.open(context, tab: AiTab.ask)),
        ]),
      ]),
    );
  }

  // ── Pieces ─────────────────────────────────────────────────────────────────

  // A plain pill instead of ActionChip: ActionChip clipped the "Open" label
  // (seen in the Simulator), this sizes itself to the text.
  Widget _chip(String label, IconData icon, VoidCallback? onTap) => Pressable(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.ink, width: 2),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: AppColors.ink),
        const SizedBox(width: 6),
        Text(label, style: NxType.body(12.5, color: AppColors.ink, weight: FontWeight.w700)),
      ]),
    ),
  );
}
