import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/money.dart';
import '../core/realtime_service.dart';
import '../core/receipt_model.dart';
import '../widgets/insight_card.dart';
import '../widgets/offline_banner.dart';
import 'ai_screen.dart';
import 'receipt_detail_screen.dart';
import 'verify_email_screen.dart';

class DashboardScreen extends StatefulWidget {
  /// Opens the Archive tab ("All receipts"); null hides the link.
  final VoidCallback? onOpenArchive;
  const DashboardScreen({super.key, this.onOpenArchive});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Receipt> _receipts = [];
  bool _loading = true;
  bool _offline = false; // showing receipts saved on the phone
  DateTime? _savedAt;
  ValueListenable<int>? _refreshTick; // live receipts / reconnect / resume
  int _requestId = 0; // ignores responses older than the latest load
  final _insightKey = GlobalKey<InsightCardState>();

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
      _refreshTick?.addListener(_load); // _load already refreshes silently
    }
  }

  @override
  void dispose() {
    _refreshTick?.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final id = ++_requestId;
    try {
      final result = await ApiClient.loadReceipts();
      if (mounted && id == _requestId) {
        setState(() {
          _receipts = result.receipts;
          _offline = result.offline;
          _savedAt = result.savedAt;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && id == _requestId) setState(() => _loading = false);
    }
  }

  // Pull to refresh: the receipts and the AI teaser. Not from _load, which is
  // also the refreshTick listener (the card listens itself).
  Future<void> _refreshAll() => Future.wait([
    _load(),
    _insightKey.currentState?.reload() ?? Future<void>.value(),
  ]);

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

  double _totalFor(int year, int month) => _receipts
      .where((r) => r.date.year == year && r.date.month == month)
      .fold(0.0, (sum, r) => sum + r.totalAmount);

  /// Last month's total, for the "x% less than October" chip.
  double get _lastMonthTotal {
    final now = DateTime.now();
    final last = DateTime(now.year, now.month - 1);
    return _totalFor(last.year, last.month);
  }

  /// Points from receipts in the last 7 days, for the stamp on the card.
  int get _pointsThisWeek {
    final since = DateTime.now().subtract(const Duration(days: 7));
    return _receipts
        .where((r) => r.date.isAfter(since))
        .fold(0, (sum, r) => sum + r.pointsEarned);
  }

  // Today's receipts
  List<Receipt> get _todayReceipts {
    final now = DateTime.now();
    return _receipts
        .where(
          (r) =>
              r.date.year == now.year &&
              r.date.month == now.month &&
              r.date.day == now.day,
        )
        .toList();
  }

  // Recent activity (up to 5, excluding today)
  List<Receipt> get _recentReceipts {
    final now = DateTime.now();
    return _receipts
        .where(
          (r) =>
              !(r.date.year == now.year &&
                  r.date.month == now.month &&
                  r.date.day == now.day),
        )
        .take(5)
        .toList();
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  static const _monthsLong = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  static const _days = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    if (user == null) return const SizedBox.shrink();
    final nx = Nx.of(context);
    final now = DateTime.now();
    final monthLong = _monthsLong[now.month - 1];
    final lastMonthLong = _monthsLong[(now.month + 10) % 12];
    final hero = nx.dark ? AppColors.ink : AppColors.cobalt;
    final heroMuted = nx.dark ? AppColors.textMuted : AppColors.cobaltSoft;
    final initials =
        (user.firstName.isNotEmpty ? user.firstName[0] : '') +
        (user.lastName.isNotEmpty ? user.lastName[0] : '');
    final last = _lastMonthTotal;
    final change = last > 0 ? (_monthTotal - last) / last * 100 : null;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
      backgroundColor: nx.sheet,
      body: DecoratedBox(
        // Hero colour above, sheet colour below, so pull-to-refresh and short
        // pages never show the wrong colour.
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [hero, hero, nx.sheet, nx.sheet],
            stops: const [0, 0.5, 0.5, 1],
          ),
        ),
        child: RefreshIndicator(
          color: AppColors.ink,
          backgroundColor: AppColors.lime,
          onRefresh: _refreshAll,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Hero ──────────────────────────────────────────
                Container(
                  color: hero,
                  padding: EdgeInsets.fromLTRB(
                    24,
                    MediaQuery.of(context).padding.top + 18,
                    24,
                    0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_offline) ...[
                        OfflineBanner(savedAt: _savedAt),
                        const SizedBox(height: 16),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${_days[now.weekday - 1]} ${now.day} '
                                  '${_months[now.month - 1].toUpperCase()}',
                                  style: NxType.mono(
                                    11,
                                    color: heroMuted,
                                    letterSpacing: 1,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Marhaba, ${_capitalized(user.firstName)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: NxType.display(
                                    24,
                                    color: Colors.white,
                                    weight: FontWeight.w700,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            width: 44,
                            height: 44,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.lime,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.ink,
                                width: 2,
                              ),
                            ),
                            child: Text(
                              initials.toUpperCase(),
                              style: NxType.display(
                                16,
                                color: AppColors.ink,
                                letterSpacing: 0,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      Text(
                        'SPENT IN ${monthLong.toUpperCase()}',
                        style: NxType.label(heroMuted),
                      ),
                      const SizedBox(height: 6),
                      _loading
                          ? Container(
                              width: 200,
                              height: 72,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                            )
                          : FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: formatJd(_monthTotal),
                                      style: NxType.display(
                                        78,
                                        color: nx.dark
                                            ? AppColors.lime
                                            : Colors.white,
                                        letterSpacing: -3,
                                        height: 0.95,
                                      ),
                                    ),
                                    TextSpan(
                                      text: ' JD',
                                      style: NxType.display(
                                        26,
                                        color: nx.dark
                                            ? Colors.white
                                            : AppColors.lime,
                                        weight: FontWeight.w700,
                                        letterSpacing: 0,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (!_loading && change != null)
                            _HeroChip(
                              filled: true,
                              icon: change <= 0
                                  ? Icons.arrow_downward_rounded
                                  : Icons.arrow_upward_rounded,
                              text: change.abs() < 0.5
                                  ? 'Same as $lastMonthLong'
                                  : '${change.abs().round()}% '
                                        '${change < 0 ? 'less' : 'more'} '
                                        'than $lastMonthLong',
                            ),
                          if (!_loading)
                            _HeroChip(
                              text: _monthCount == 0
                                  ? 'No receipts this month'
                                  : '$_monthCount receipt${_monthCount == 1 ? '' : 's'}',
                            ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      _LoyaltyCard(
                        points: user.loyaltyPoints,
                        thisWeek: _loading ? 0 : _pointsThisWeek,
                      ),
                      const SizedBox(height: 26),
                    ],
                  ),
                ),

                // ── Sheet ─────────────────────────────────────────
                Container(
                  decoration: BoxDecoration(
                    color: nx.sheet,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                  ),
                  transform: Matrix4.translationValues(0, -2, 0),
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 140),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!user.emailVerified) ...[
                        NxCard(
                          color: AppColors.amber,
                          borderColor: AppColors.ink,
                          shadow: 0,
                          padding: const EdgeInsets.all(14),
                          onTap: () => VerifyEmailScreen.open(context),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.mark_email_unread_outlined,
                                color: AppColors.ink,
                                size: 24,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Verify your email',
                                      style: NxType.display(
                                        16,
                                        color: AppColors.ink,
                                        weight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Confirm ${user.email} to secure your account.',
                                      style: NxType.body(
                                        12.5,
                                        color: AppColors.ink,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(
                                Icons.chevron_right_rounded,
                                color: AppColors.ink,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                      ],

                      _SectionHead(
                        title: 'Today',
                        action: widget.onOpenArchive == null
                            ? null
                            : 'All receipts',
                        onAction: widget.onOpenArchive,
                      ),
                      const SizedBox(height: 12),
                      if (_loading)
                        _buildMiniLoader(nx)
                      else if (_todayReceipts.isEmpty)
                        _buildEmpty(
                          nx,
                          'No receipts today. Show your '
                          'code at the till and they land here.',
                        )
                      else
                        ..._todayReceipts.map(
                          (r) => _CompactReceiptTile(receipt: r, today: true),
                        ),

                      const SizedBox(height: 10),
                      InsightCard(
                        key: _insightKey,
                        compact: true,
                        onOpen: () => AiScreen.open(context),
                      ),
                      const SizedBox(height: 24),

                      const _SectionHead(title: 'Recent activity'),
                      const SizedBox(height: 12),
                      if (_loading)
                        _buildMiniLoader(nx)
                      else if (_recentReceipts.isEmpty)
                        _buildEmpty(nx, 'No recent activity')
                      else
                        ..._recentReceipts.map(
                          (r) => _CompactReceiptTile(receipt: r),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    );
  }

  /// "obada" → "Obada" for the greeting (the stored name is unchanged).
  static String _capitalized(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Widget _buildMiniLoader(Nx nx) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: nx.accent),
      ),
    ),
  );

  Widget _buildEmpty(Nx nx, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: ReceiptTile(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          NxIconTile(
            icon: Icons.receipt_long_outlined,
            color: nx.dark ? AppColors.lavender : AppColors.paper,
            size: 38,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(text, style: NxType.body(13.5, color: nx.muted)),
          ),
        ],
      ),
    ),
  );
}

// ── Hero chip ────────────────────────────────────────────────────────────────

class _HeroChip extends StatelessWidget {
  final String text;
  final IconData? icon;
  final bool filled;
  const _HeroChip({required this.text, this.icon, this.filled = false});

  @override
  Widget build(BuildContext context) => Container(
    height: 28,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: filled ? AppColors.lime : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      border: filled ? null : Border.all(color: Colors.white, width: 1.5),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: AppColors.ink),
          const SizedBox(width: 5),
        ],
        Text(
          text,
          style: NxType.body(
            12.5,
            color: filled ? AppColors.ink : Colors.white,
            weight: filled ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

// ── Loyalty card ─────────────────────────────────────────────────────────────

class _LoyaltyCard extends StatelessWidget {
  final int points;
  final int thisWeek;
  const _LoyaltyCard({required this.points, required this.thisWeek});

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final fg = nx.dark ? Colors.white : AppColors.ink;
    return NxCard(
      tilt: -1.5,
      color: nx.dark ? AppColors.cobalt : Colors.white,
      borderColor: AppColors.ink,
      shadowColor: nx.dark ? AppColors.lime : AppColors.ink,
      padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
      child: SizedBox(
        height: 60,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'LOYALTY CARD',
                    style: NxType.label(
                      nx.dark ? AppColors.cobaltSoft : AppColors.textMutedLight,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: formatPoints(points),
                          style: NxType.display(30, color: fg, height: 1),
                        ),
                        TextSpan(
                          text: '  points',
                          style: NxType.body(
                            14,
                            color: fg,
                            weight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (thisWeek > 0)
              NxStamp(
                value: '+$thisWeek',
                caption: 'THIS WEEK',
                color: nx.dark ? AppColors.lime : AppColors.danger,
              ),
          ],
        ),
      ),
    );
  }
}

// ── Section head ─────────────────────────────────────────────────────────────

class _SectionHead extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const _SectionHead({required this.title, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            title,
            style: NxType.display(22, color: nx.text, letterSpacing: -0.5),
          ),
        ),
        if (action != null)
          GestureDetector(
            onTap: onAction,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                action!,
                style:
                    NxType.body(
                      13,
                      color: nx.accent,
                      weight: FontWeight.w700,
                    ).copyWith(
                      decoration: TextDecoration.underline,
                      decorationColor: nx.accent,
                    ),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Compact receipt tile ──────────────────────────────────────────────────────

class _CompactReceiptTile extends StatelessWidget {
  final Receipt receipt;
  final bool today;
  const _CompactReceiptTile({required this.receipt, this.today = false});

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final d = receipt.date;
    final when = today
        ? '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}'
        : _formatDate(d);
    final n = receipt.items.length;
    final meta = [
      when,
      if (n > 0) '$n item${n == 1 ? '' : 's'}',
      if (receipt.pointsEarned > 0) '+${receipt.pointsEarned} pts',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ReceiptTile(
        // Tap anywhere on the tile for the full receipt.
        onTap: () => ReceiptDetailScreen.open(context, receipt),
        child: Row(
          children: [
            NxIconTile(
              icon: categoryIcon(receipt.category),
              color: _tileColor(nx, receipt.category),
              tilt: receipt.storeName.length.isEven ? -4 : 3,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    receipt.storeName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NxType.body(
                      15,
                      color: nx.text,
                      weight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NxType.mono(11.5, color: nx.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: formatJd(receipt.totalAmount),
                    style: NxType.mono(
                      17,
                      color: nx.text,
                      weight: FontWeight.w500,
                    ),
                  ),
                  TextSpan(
                    text: ' JD',
                    style: NxType.mono(11, color: nx.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Color _tileColor(Nx nx, String category) {
    final c = CategoryColors.of(category);
    // Cobalt disappears on the dark rows; use its lighter tint there.
    return nx.dark && c == AppColors.cobalt ? AppColors.cobaltLight : c;
  }

  String _formatDate(DateTime d) {
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }
}
