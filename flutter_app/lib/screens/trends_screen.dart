import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/budget_models.dart';
import '../core/comparison_labels.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/money.dart';
import '../core/offline_cache.dart';
import '../core/realtime_service.dart';
import '../core/stats_model.dart';
import '../core/trends.dart';
import '../widgets/budget_bar.dart';
import '../widgets/offline_banner.dart';
import 'ai_screen.dart';
import 'budgets_screen.dart';

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
  // This month's budgets (never a list from another month). With no list the
  // card shows a placeholder while a load runs, else a retry row.
  BudgetList? _budgets;
  bool _budgetsLoading = false;
  DateTime? _budgetsSavedAt; // set only when the list came from the phone
  int _budgetsRequestId = 0;
  ValueListenable<int>? _refreshTick; // live receipts / reconnect / resume

  static const _months = ['Jan','Feb','Mar','Apr','May','Jun',
                          'Jul','Aug','Sep','Oct','Nov','Dec'];
  static const _monthsLong = ['January','February','March','April','May','June',
                              'July','August','September','October','November','December'];

  @override
  void initState() {
    super.initState();
    _budgetsLoading = true; // the first frame shows the placeholder, not the retry row
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
    _loadBudgets(silent: silent); // in parallel; never touches the stats states
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

  /// The Budgets card's list. Shows the list saved on the phone at once when
  /// nothing is on screen. A failure never shows a SnackBar: it keeps a list
  /// that is on screen, else the card offers a retry. [silent] (background
  /// refresh) never shows the placeholder.
  Future<void> _loadBudgets({bool silent = false}) async {
    final id = ++_budgetsRequestId;
    if (!silent) {
      setState(() => _budgetsLoading = _budgets == null);
    }
    if (_budgets == null) {
      final cached = await OfflineCache.loadBudgets();
      if (!mounted || id != _budgetsRequestId) return;
      if (cached != null && cached.isMonthOf(DateTime.now())) {
        final savedAt = await OfflineCache.budgetsSavedAt();
        if (!mounted || id != _budgetsRequestId) return;
        setState(() {
          _budgets = cached;
          _budgetsSavedAt = savedAt;
          _budgetsLoading = false;
        });
      }
    }
    BudgetsResult? result;
    try {
      result = await ApiClient.loadBudgets();
    } catch (_) {
      result = null;
    }
    if (!mounted || id != _budgetsRequestId) return;
    final fresh = (result != null && result.list.isMonthOf(DateTime.now())) ? result.list : null;
    setState(() {
      if (fresh != null) {
        _budgets = fresh;
        _budgetsSavedAt = result!.offline ? result.savedAt : null;
      } else if (!silent && result != null) {
        // A list from another month (month rollover): its bars must go.
        _budgets = null;
        _budgetsSavedAt = null;
      }
      // Any other failure keeps what is on screen. With no list, ending the
      // load turns the placeholder into the retry row.
      _budgetsLoading = false;
    });
  }

  Future<void> _openBudgets() async {
    await BudgetsScreen.open(context);
    if (mounted) _loadBudgets();
  }

  @override
  Widget build(BuildContext context) {
    final nx    = Nx.of(context);
    final stats = _stats;

    // Trends is an ink page in both modes; its cards follow the mode.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
      backgroundColor: AppColors.ink,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildHeader()),
            if (_loading)
              SliverToBoxAdapter(child: _buildLoading())
            else if (_error != null || stats == null)
              SliverToBoxAdapter(child: _buildError(nx))
            else if (!stats.hasAnyReceipts)
              SliverToBoxAdapter(child: _buildEmpty())
            else
              SliverToBoxAdapter(child: _buildContent(stats, nx)),
          ],
        ),
      ),
    ),
    );
  }

  // ── Header: title, AI, refresh, offline banner ─────────────────────────────

  Widget _roundIcon(IconData icon, VoidCallback onTap, {bool filled = false}) =>
      Pressable(
        onTap: onTap,
        child: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: filled ? AppColors.lime : Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(
              color: filled ? AppColors.lime : Colors.white, width: 2)),
          child: Icon(icon, size: 20,
            color: filled ? AppColors.ink : Colors.white),
        ),
      );

  Widget _buildHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Trends',
                style: NxType.display(40, color: Colors.white,
                  letterSpacing: -1.8)),
            ),
            Tooltip(
              message: 'AI insights',
              child: _roundIcon(Icons.auto_awesome_rounded,
                () => AiScreen.open(context), filled: true),
            ),
            const SizedBox(width: 8),
            _roundIcon(Icons.refresh_rounded, _load),
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
          strokeWidth: 2.5, color: AppColors.lime)),
    ),
  );

  // ── Error ──────────────────────────────────────────────────────────────────

  Widget _buildError(Nx nx) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
    child: Column(
      children: [
        const Icon(Icons.wifi_off_rounded, color: AppColors.coral, size: 40),
        const SizedBox(height: 16),
        Text('Could not load trends',
          style: NxType.display(20, color: Colors.white)),
        const SizedBox(height: 8),
        Text(_error ?? '', textAlign: TextAlign.center,
          style: NxType.body(13, color: AppColors.textMuted)),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _load,
          style: NxButtonStyle.solid(nx, fill: AppColors.lime,
            text: AppColors.ink, height: 48),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('Retry')),
        ),
      ],
    ),
  );

  // ── Empty state ────────────────────────────────────────────────────────────

  Widget _buildEmpty() => Padding(
    padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
    child: Column(
      children: [
        const NxIconTile(icon: Icons.bar_chart_rounded,
          color: AppColors.lime, size: 64, tilt: -6),
        const SizedBox(height: 18),
        Text('No spending yet',
          style: NxType.display(20, color: Colors.white)),
        const SizedBox(height: 8),
        Text('Your trends appear after your first Nexus receipt.',
          textAlign: TextAlign.center,
          style: NxType.body(13.5, color: AppColors.textMuted, height: 1.6)),
      ],
    ),
  );

  // ── Main content ───────────────────────────────────────────────────────────

  /// Spending up is coral, down is teal (less spending is good); "—"/"0%" muted.
  static Color _changeColor(String change, Nx nx) {
    if (change == '—' || change == '0%') return nx.muted;
    return change.startsWith('−') ? AppColors.teal : nx.danger;
  }

  Widget _chip(String change, Nx nx, {String? suffix}) {
    final color = _changeColor(change, nx);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(suffix == null ? change : '$change $suffix',
        style: NxType.body(12, weight: FontWeight.w700, color: color)),
    );
  }

  Widget _card(Nx nx, {required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
    decoration: BoxDecoration(
      color: nx.card,
      borderRadius: BorderRadius.circular(18),
      border: nx.dark ? null : Border.all(color: AppColors.ink, width: 2),
    ),
    child: child,
  );

  Widget _sectionTitle(String text, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(text,
            style: NxType.display(22, color: Colors.white, letterSpacing: -0.5)),
        ),
        ?trailing,
      ],
    ),
  );

  Widget _buildContent(SpendingStats stats, Nx nx) {
    final current  = stats.current;
    final previous = stats.previous;
    final now      = DateTime.now();
    final isNow    = !now.isBefore(current.from) && now.isBefore(current.to);
    final label    = isNow
        ? '${_monthsLong[current.from.month - 1]} so far'
        : '${_monthsLong[current.from.month - 1]} ${current.from.year}';
    final vs       = previous == null
        ? null
        : trendsVsLabel(
            previousMonth: _monthsLong[previous.from.month - 1], monthInProgress: isNow);
    final change = previous == null
        ? null : formatChange(percentChange(current.total, previous.total));

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 140),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. This month
          Text(label.toUpperCase(),
            style: NxType.label(AppColors.textMuted)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: formatJd(current.total),
                      style: NxType.display(64, color: Colors.white,
                        letterSpacing: -2.5, height: 1)),
                    TextSpan(text: ' JD',
                      style: NxType.display(22, color: AppColors.lime,
                        weight: FontWeight.w700, letterSpacing: 0)),
                  ])),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10, runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (change != null)
                Transform.rotate(
                  angle: -0.05,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: change.startsWith('−') || change == '0%' || change == '—'
                          ? AppColors.lime : AppColors.coral,
                      borderRadius: BorderRadius.circular(16)),
                    child: Text('$change $vs',
                      style: NxType.body(12.5, color: AppColors.ink,
                        weight: FontWeight.w700)),
                  ),
                ),
              Text('${current.count} receipt${current.count == 1 ? '' : 's'}',
                style: NxType.mono(12.5, color: AppColors.textMuted)),
            ],
          ),
          const SizedBox(height: 22),

          // 2. Last 6 months
          _MonthChart(periods: stats.periods, months: _months),
          const SizedBox(height: 26),

          // Budgets (only for the current month)
          if (isNow) ...[
            if (_budgets != null)
              _buildBudgets(_budgets!, nx)
            else if (_budgetsLoading)
              _buildBudgetsLoading(nx)
            else
              _buildBudgetsRetry(nx),
            const SizedBox(height: 22),
          ],

          // 3. By category
          _sectionTitle('By category'),
          if (isNow && previous != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '${_monthsLong[current.from.month - 1]} so far '
                '${trendsVsLabel(previousMonth: _monthsLong[previous.from.month - 1], monthInProgress: true)}',
                style: NxType.mono(11.5, color: AppColors.textMuted)),
            ),
          _card(nx, child: Column(
            children: [
              for (final (i, c) in categoryChanges(current, previous).indexed) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: DashedRule(color: nx.hairline, thickness: 1.5, dash: 3, gap: 3),
                  ),
                Row(
                  children: [
                    Container(
                      width: 12, height: 12,
                      decoration: BoxDecoration(
                        color: CategoryColors.of(c.category),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: nx.line, width: 1.5)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(c.category,
                        style: NxType.body(14.5, weight: FontWeight.w700,
                          color: nx.text)),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${formatJd(c.current)} JD',
                          style: NxType.mono(13.5, color: nx.text,
                            weight: FontWeight.w500)),
                        if (previous != null)
                          Text('${formatJd(c.previous)} JD',
                            style: NxType.mono(11, color: nx.muted)),
                      ],
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 64,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _chip(formatChange(c.pct), nx)),
                    ),
                  ],
                ),
              ],
            ],
          )),
          const SizedBox(height: 16),

          // 4. Highlights
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _card(nx, child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _tileTitle('Biggest store', nx),
                    Text(current.topStore?.storeName ?? '—',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: NxType.display(18, color: nx.text)),
                    const SizedBox(height: 6),
                    Text(
                      current.topStore == null
                          ? 'No receipts this month'
                          : '${formatJd(current.topStore!.total)} JD · '
                            '${current.topStore!.count} visit${current.topStore!.count == 1 ? '' : 's'}',
                      style: NxType.mono(11.5, color: nx.muted)),
                  ],
                ))),
                const SizedBox(width: 12),
                Expanded(child: _card(nx, child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _tileTitle('Average receipt', nx),
                    Text('${formatJd(current.average)} JD',
                      style: NxType.display(18, color: nx.text)),
                    const SizedBox(height: 8),
                    if (previous != null)
                      _chip(formatChange(percentChange(current.average, previous.average)),
                        nx, suffix: 'vs last month'),
                  ],
                ))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBudgets(BudgetList list, Nx nx) {
    final edit = GestureDetector(
      key: const ValueKey('trends-budgets-edit'),
      onTap: _openBudgets,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        // 44pt tap target around the short link.
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
        child: Text(list.budgets.isEmpty ? 'Set up' : 'Edit',
          style: NxType.body(14, weight: FontWeight.w700, color: AppColors.lime)
            .copyWith(decoration: TextDecoration.underline,
              decorationColor: AppColors.lime)),
      ),
    );
    final savedLine = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text('Saved on this phone',
        style: NxType.mono(11.5, color: AppColors.textMuted)),
    );
    if (list.budgets.isEmpty) {
      return _card(nx, child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const NxIconTile(icon: Icons.savings_outlined,
                color: AppColors.amber, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Set monthly budgets',
                  style: NxType.display(16, color: nx.text,
                    weight: FontWeight.w700)),
              ),
              GestureDetector(
                key: const ValueKey('trends-budgets-edit'),
                onTap: _openBudgets,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                  child: Text('Set up',
                  style: NxType.body(14, weight: FontWeight.w700,
                    color: nx.accent).copyWith(
                      decoration: TextDecoration.underline,
                      decorationColor: nx.accent)),
                ),
              ),
            ],
          ),
          if (_budgetsSavedAt != null) ...[
            const SizedBox(height: 6),
            Text('Saved on this phone',
              style: NxType.mono(11.5, color: nx.muted)),
          ],
        ],
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Budgets', trailing: edit),
        if (_budgetsSavedAt != null) savedLine,
        for (final b in list.budgets)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _card(nx, child: BudgetBar(status: b)),
          ),
      ],
    );
  }

  /// Same height as two budget cards, so nothing jumps.
  Widget _buildBudgetsLoading(Nx nx) {
    Widget track() => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _card(nx, child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(width: 90, height: 12,
            decoration: BoxDecoration(
              color: nx.hairline, borderRadius: BorderRadius.circular(4))),
          const SizedBox(height: 10),
          Container(height: 18,
            decoration: BoxDecoration(
              color: nx.hairline, borderRadius: BorderRadius.circular(9))),
        ],
      )),
    );
    return KeyedSubtree(
      key: const ValueKey('trends-budgets-loading'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Budgets'),
          track(),
          track(),
        ],
      ),
    );
  }

  Widget _buildBudgetsRetry(Nx nx) =>
      GestureDetector(
        key: const ValueKey('trends-budgets-retry'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _loadBudgets(),
        child: _card(nx, child: Row(
          children: [
            Icon(Icons.refresh_rounded, color: nx.danger, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text("Couldn't load budgets, tap to retry",
                style: NxType.body(13.5, weight: FontWeight.w600, color: nx.text)),
            ),
          ],
        )),
      );

  Widget _tileTitle(String text, Nx nx) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text.toUpperCase(), style: NxType.label(nx.muted)),
  );
}

// ── Month bar chart ───────────────────────────────────────────────────────────

class _MonthChart extends StatelessWidget {
  final List<PeriodStats> periods;
  final List<String> months;

  const _MonthChart({required this.periods, required this.months});

  @override
  Widget build(BuildContext context) {
    const chartHeight = 130.0;
    final maxAmt = periods.fold<double>(0, (m, p) => p.total > m ? p.total : m);

    return Column(
      children: [
        SizedBox(
          height: chartHeight + 22,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < periods.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(formatJd(periods[i].total, decimals: 0),
                          style: NxType.mono(11,
                            weight: FontWeight.w500,
                            color: i == periods.length - 1
                                ? AppColors.lime : Colors.white)),
                        const SizedBox(height: 6),
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: maxAmt == 0
                              ? 0 : periods[i].total / maxAmt),
                          duration: Duration(milliseconds: 500 + i * 70),
                          curve: Curves.easeOutCubic,
                          builder: (context, f, _) => Container(
                            height: chartHeight * f,
                            decoration: BoxDecoration(
                              color: i == periods.length - 1
                                  ? AppColors.lime : AppColors.lavender,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(10)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        Container(height: 2, color: Colors.white),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var i = 0; i < periods.length; i++)
              Expanded(
                child: Text(months[periods[i].from.month - 1],
                  textAlign: TextAlign.center,
                  style: NxType.mono(11,
                    weight: i == periods.length - 1 ? FontWeight.w500 : FontWeight.w400,
                    color: i == periods.length - 1
                        ? AppColors.lime : AppColors.textMuted)),
              ),
          ],
        ),
      ],
    );
  }
}
