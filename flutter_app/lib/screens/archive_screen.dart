import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/money.dart';
import '../core/period.dart';
import '../core/realtime_service.dart';
import '../core/receipt_model.dart';
import '../widgets/offline_banner.dart';
import 'receipt_detail_screen.dart';

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key});
  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  List<Receipt> _receipts = [];
  bool _loading = true;
  String? _error;
  bool _offline = false;     // showing receipts saved on the phone
  DateTime? _savedAt;
  Period _period = Period.containing(PeriodType.month, DateTime.now());
  int _requestId = 0; // ignores responses from periods the user already left
  ValueListenable<int>? _refreshTick; // live receipts / reconnect / resume
  String? _category; // filter chip; null = all

  static const _filters = [
    (PeriodType.day,    'Day'),
    (PeriodType.week,   'Week'),
    (PeriodType.month,  'Month'),
    (PeriodType.year,   'Year'),
    (PeriodType.custom, 'Custom'),
  ];

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

  /// [silent]: background refresh. No spinner, and the current list stays
  /// if it fails.
  Future<void> _load({bool silent = false}) async {
    final id = ++_requestId;
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      final result = await ApiClient.loadReceipts(
        from: _period.start, to: _period.end);
      if (mounted && id == _requestId) {
        setState(() {
          _receipts = result.receipts;
          _offline  = result.offline;
          _savedAt  = result.savedAt;
          _loading  = false;
          _error    = null;
        });
      }
    } catch (e) {
      // A silent failure only shows the error if nothing is on screen yet
      // (it replaced a first load that was still spinning).
      if (mounted && id == _requestId && (!silent || _loading)) {
        setState(() { _error = e.toString(); _loading = false; });
      }
    }
  }

  void _setPeriod(Period p) {
    setState(() => _period = p);
    _load();
  }

  Future<void> _selectType(PeriodType type) async {
    if (type == PeriodType.custom) return _pickCustomRange();
    if (type == _period.type) return;
    _setPeriod(Period.containing(type, DateTime.now()));
  }

  Future<void> _pickCustomRange() async {
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last  = _period.lastDay.isAfter(today) ? today : _period.lastDay;
    final isDark = Nx.of(context).dark;

    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: today,
      initialDateRange: DateTimeRange(
        start: _period.start.isAfter(last) ? last : _period.start, end: last),
      helpText: 'Choose a period',
      saveText: 'Apply',
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: (isDark ? const ColorScheme.dark() : const ColorScheme.light())
              .copyWith(
                primary: isDark ? AppColors.lime : AppColors.cobalt,
                onPrimary: isDark ? AppColors.ink : Colors.white,
                secondary: AppColors.teal,
                surface: isDark ? AppColors.surface : Colors.white,
              ),
          datePickerTheme: DatePickerThemeData(
            rangeSelectionBackgroundColor:
                (isDark ? AppColors.lime : AppColors.cobalt).withValues(alpha: 0.18),
          ),
        ),
        child: child!,
      ),
    );
    if (range != null) _setPeriod(Period.custom(range.start, range.end));
  }

  List<Receipt> get _shown => _category == null
      ? _receipts
      : _receipts.where((r) => r.category == _category).toList();

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
      backgroundColor: nx.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: AppColors.ink,
          backgroundColor: AppColors.lime,
          onRefresh: () => _load(silent: true),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _buildHeader(nx)),
              if (_loading)
                SliverToBoxAdapter(child: _buildLoading(nx))
              else if (_error != null)
                SliverToBoxAdapter(child: _buildError(nx))
              else if (_receipts.isEmpty)
                SliverToBoxAdapter(child: _buildEmpty(nx))
              else
                ..._buildContent(nx),
            ],
          ),
        ),
      ),
    ),
    );
  }

  // ── Header: title, period, period type ─────────────────────────────────────

  Widget _buildHeader(Nx nx) {
    final now      = DateTime.now();
    final isCustom = _period.type == PeriodType.custom;
    final canNext  = !isCustom && !_period.isLatest(now);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Archive',
                  style: NxType.display(40, color: nx.text, letterSpacing: -1.8)),
              ),
              Tooltip(
                message: 'Refresh',
                child: Pressable(
                  onTap: _load,
                  child: Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: nx.line, width: 2)),
                    child: Icon(Icons.refresh_rounded, color: nx.text, size: 20),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Navigator: ‹ label ›   (custom: tap the label to change the range)
          Container(
            height: 48,
            decoration: BoxDecoration(
              color: nx.card,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: nx.line, width: 2),
            ),
            child: Row(
              children: [
                _navArrow(nx, Icons.chevron_left_rounded,
                  enabled: !isCustom, onTap: () => _setPeriod(_period.shift(-1))),
                Expanded(
                  child: GestureDetector(
                    onTap: isCustom ? _pickCustomRange : null,
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (isCustom) ...[
                          Icon(Icons.date_range_rounded, size: 16, color: nx.accent),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(_period.label(now).toUpperCase(),
                            overflow: TextOverflow.ellipsis,
                            style: NxType.mono(13.5, color: nx.text,
                              weight: FontWeight.w500, letterSpacing: 1)),
                        ),
                      ],
                    ),
                  ),
                ),
                _navArrow(nx, Icons.chevron_right_rounded,
                  enabled: canNext, onTap: () => _setPeriod(_period.shift(1))),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // Period type
          Row(
            children: _filters.map((f) {
              final selected = _period.type == f.$1;
              return Expanded(
                child: Pressable(
                  onTap: () => _selectType(f.$1),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: selected
                          ? (nx.dark ? AppColors.lime : AppColors.ink)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    alignment: Alignment.center,
                    child: Text(f.$2,
                      style: NxType.body(13,
                        weight: FontWeight.w700,
                        color: selected
                            ? (nx.dark ? AppColors.ink : Colors.white)
                            : nx.muted)),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          if (!_loading && _error == null && _offline) ...[
            OfflineBanner(savedAt: _savedAt),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  Widget _navArrow(Nx nx, IconData icon, {
    required bool enabled,
    required VoidCallback onTap,
  }) =>
    IconButton(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 24),
      color: nx.text,
      disabledColor: nx.muted.withValues(alpha: 0.35),
    );

  // ── Loading ────────────────────────────────────────────────────────────────

  Widget _buildLoading(Nx nx) => Padding(
    padding: const EdgeInsets.only(top: 60),
    child: Center(
      child: SizedBox(width: 22, height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: nx.accent)),
    ),
  );

  // ── Error ──────────────────────────────────────────────────────────────────

  Widget _buildError(Nx nx) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
    child: Column(
      children: [
        Icon(Icons.wifi_off_rounded, color: nx.danger, size: 40),
        const SizedBox(height: 16),
        Text('Could not load receipts',
          style: NxType.display(20, color: nx.text)),
        const SizedBox(height: 8),
        Text(_error ?? '', textAlign: TextAlign.center,
          style: NxType.body(13, color: nx.muted)),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _load,
          style: NxButtonStyle.solid(nx, height: 48),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('Retry')),
        ),
      ],
    ),
  );

  // ── Empty state ────────────────────────────────────────────────────────────

  Widget _buildEmpty(Nx nx) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
    child: Column(
      children: [
        NxIconTile(icon: Icons.receipt_long_outlined,
          color: AppColors.lime, size: 64, tilt: -6),
        const SizedBox(height: 18),
        Text('No receipts in this period',
          style: NxType.display(20, color: nx.text)),
        const SizedBox(height: 8),
        Text('Try another period, or visit a\nNexus-enabled store to collect receipts.',
          textAlign: TextAlign.center,
          style: NxType.body(13.5, color: nx.muted, height: 1.6)),
      ],
    ),
  );

  // ── Main content ───────────────────────────────────────────────────────────

  List<Widget> _buildContent(Nx nx) {
    final totals = Receipt.totalsByCategory(_receipts);
    final total  = _receipts.fold<double>(0, (s, r) => s + r.totalAmount);
    final shown  = _shown;

    // Group the shown receipts by day, newest first (the API order).
    final groups = <DateTime, List<Receipt>>{};
    for (final r in shown) {
      final day = DateTime(r.date.year, r.date.month, r.date.day);
      groups.putIfAbsent(day, () => []).add(r);
    }

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Where it went ────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.only(right: 5, bottom: 5),
                child: NxCard(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text('WHERE IT WENT',
                              style: NxType.label(nx.muted)),
                          ),
                          Text('${formatJd(total)} JD',
                            style: NxType.display(20, color: nx.text,
                              letterSpacing: -0.5)),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _StackedBar(totals: totals, total: total),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 16, runSpacing: 8,
                        children: totals.entries.map((e) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 11, height: 11,
                              decoration: BoxDecoration(
                                color: CategoryColors.of(e.key),
                                borderRadius: BorderRadius.circular(3),
                                border: Border.all(color: nx.line, width: 1.5)),
                            ),
                            const SizedBox(width: 6),
                            Text(e.key, style: NxType.body(13, color: nx.text,
                              weight: FontWeight.w700)),
                            const SizedBox(width: 6),
                            Text(formatJd(e.value),
                              style: NxType.mono(12.5, color: nx.text)),
                          ],
                        )).toList(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),

      // ── Category filter chips ─────────────────────────────────────────────
      SliverToBoxAdapter(
        child: SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              NxChip(
                label: 'All ${_receipts.length}',
                filled: _category == null,
                fill: nx.dark ? AppColors.lime : AppColors.ink,
                height: 46,
                onTap: () => setState(() => _category = null)),
              for (final c in totals.keys) ...[
                const SizedBox(width: 8),
                NxChip(
                  label: c,
                  filled: _category == c,
                  fill: nx.dark ? AppColors.lime : AppColors.ink,
                  height: 46,
                  onTap: () => setState(() => _category = c)),
              ],
            ],
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 14)),

      // ── Receipts by day ─────────────────────────────────────────────────
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 140),
        sliver: SliverList(
          delegate: SliverChildListDelegate([
            for (final g in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Text(_dayLabel(g.key),
                  style: NxType.label(nx.muted)),
              ),
              for (final r in g.value) _ReceiptTile(receipt: r),
              const SizedBox(height: 8),
            ],
          ]),
        ),
      ),
    ];
  }

  static String _dayLabel(DateTime day) {
    const w = ['MON','TUE','WED','THU','FRI','SAT','SUN'];
    const m = ['JAN','FEB','MAR','APR','MAY','JUN',
               'JUL','AUG','SEP','OCT','NOV','DEC'];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final base = '${w[day.weekday - 1]} ${day.day} ${m[day.month - 1]}';
    if (day == today) return '$base · TODAY';
    if (day == today.subtract(const Duration(days: 1))) return '$base · YESTERDAY';
    return day.year == now.year ? base : '$base ${day.year}';
  }
}

// ── Stacked category bar ─────────────────────────────────────────────────────

class _StackedBar extends StatelessWidget {
  final Map<String, double> totals;
  final double total;
  const _StackedBar({required this.totals, required this.total});

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final entries = totals.entries.where((e) => e.value > 0).toList();
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => Container(
        height: 30,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: nx.line, width: 2),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: Row(
            children: [
              for (var i = 0; i < entries.length; i++)
                Expanded(
                  flex: total <= 0 ? 1
                      : (entries[i].value / total * 1000 * t).round().clamp(1, 1000),
                  child: Container(
                    decoration: BoxDecoration(
                      color: CategoryColors.of(entries[i].key),
                      border: i == entries.length - 1 ? null
                          : Border(right: BorderSide(color: nx.line, width: 2)),
                    ),
                  ),
                ),
              if (t < 1)
                Expanded(
                  flex: (1000 * (1 - t)).round().clamp(1, 1000),
                  child: const SizedBox()),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Receipt tile ──────────────────────────────────────────────────────────────

class _ReceiptTile extends StatelessWidget {
  final Receipt receipt;
  const _ReceiptTile({required this.receipt});

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final d = receipt.date;
    final time = '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
    final items = receipt.items.take(3).join(', ');
    final cat = CategoryColors.of(receipt.category);

    // Tap anywhere on the tile for the full receipt.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Pressable(
        onTap: () => ReceiptDetailScreen.open(context, receipt),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: nx.card,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              NxIconTile(
                icon: categoryIcon(receipt.category),
                color: nx.dark && cat == AppColors.cobalt
                    ? AppColors.cobaltLight : cat,
                tilt: receipt.storeName.length.isEven ? -4 : 3),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(receipt.storeName,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: NxType.body(15, color: nx.text,
                        weight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(items.isEmpty ? time : '$time · $items',
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: NxType.mono(12, color: nx.muted)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text.rich(TextSpan(children: [
                TextSpan(text: formatJd(receipt.totalAmount),
                  style: NxType.mono(17, color: nx.text,
                    weight: FontWeight.w500)),
                TextSpan(text: ' JD',
                  style: NxType.mono(12, color: nx.muted)),
              ])),
            ],
          ),
        ),
      ),
    );
  }
}
