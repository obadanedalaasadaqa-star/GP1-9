import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/ai_models.dart';
import '../core/api_client.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/money.dart';
import '../core/theme_provider.dart';
import '../screens/verify_email_screen.dart';
import 'offline_banner.dart';

/// The Report tab: a spending report for 1, 3, 6 or 12 months or chosen
/// dates. Every number comes from the server and is printed with formatJd;
/// the AI only adds the summary. Can be emailed to the verified address.
class ReportView extends StatefulWidget {
  const ReportView({super.key});

  static const maxDays = 731;

  @override
  State<ReportView> createState() => _ReportViewState();
}

class _ReportViewState extends State<ReportView> with AutomaticKeepAliveClientMixin {
  ReportRequest _request = const ReportRequest(ReportPeriod.oneMonth);
  SpendingReport? _report;
  bool _loading = true;
  String? _error;
  bool _offline = false;
  DateTime? _savedAt;
  bool _emailing = false;
  int _requestId = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = ++_requestId;
    setState(() {
      _loading = _report == null;
      _error = null;
    });
    try {
      final result = await ApiClient.loadReport(_request);
      if (!mounted || id != _requestId) return;
      setState(() {
        _report = result.report;
        _offline = result.offline;
        _savedAt = result.savedAt;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _report = null;
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _choose(ReportPeriod period) async {
    if (period == ReportPeriod.custom) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020, 1, 1),
        lastDate: today,
        helpText: 'Choose report dates',
        initialDateRange: _request.period == ReportPeriod.custom && _request.from != null
            ? DateTimeRange(start: _request.from!, end: _request.to!)
            : DateTimeRange(start: DateTime(today.year, today.month, 1), end: today),
      );
      if (picked == null || !mounted) return;
      final days = DateTime.utc(picked.end.year, picked.end.month, picked.end.day)
              .difference(DateTime.utc(picked.start.year, picked.start.month, picked.start.day))
              .inDays + 1;
      if (days > ReportView.maxDays) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reports can cover at most 2 years.')));
        return;
      }
      setState(() => _request = ReportRequest(ReportPeriod.custom, from: picked.start, to: picked.end));
    } else {
      setState(() => _request = ReportRequest(period));
    }
    _report = null; // another period: never show the old numbers under it
    await _load();
  }

  Future<void> _email() async {
    setState(() => _emailing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final message = await ApiClient.emailReport(_request);
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _emailing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = context.watch<ThemeProvider>().isDark;
    final c = _C(isDark);
    final report = _report;

    return RefreshIndicator(
      color: AppColors.gold,
      backgroundColor: c.surface,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in ReportPeriod.values)
                ChoiceChip(
                  label: Text(p == ReportPeriod.custom ? 'Custom…' : p.label),
                  selected: _request.period == p,
                  onSelected: (_) => _choose(p),
                  selectedColor: AppColors.gold.withValues(alpha: 0.2),
                  backgroundColor: c.surface,
                  side: BorderSide(color: _request.period == p ? AppColors.gold : c.border),
                  labelStyle: GoogleFonts.dmSans(
                    fontSize: 12.5, fontWeight: FontWeight.w600,
                    color: _request.period == p ? AppColors.gold : c.primary),
                  showCheckmark: false,
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold))),
            )
          else if (report == null)
            _errorBox(c)
          else
            ..._content(report, c),
        ],
      ),
    );
  }

  Widget _errorBox(_C c) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(children: [
      Text("Couldn't load the report.", style: GoogleFonts.dmSans(fontSize: 14, color: c.primary)),
      if (_error != null) ...[
        const SizedBox(height: 6),
        Text(_error!, textAlign: TextAlign.center, style: GoogleFonts.dmSans(fontSize: 12.5, color: c.muted)),
      ],
      const SizedBox(height: 8),
      TextButton(
        onPressed: _load,
        style: TextButton.styleFrom(foregroundColor: AppColors.gold),
        child: const Text('Try again'),
      ),
    ]),
  );

  List<Widget> _content(SpendingReport r, _C c) {
    final user = context.watch<AuthProvider>().user;
    final verified = user?.emailVerified ?? false;
    final empty = r.totals.receipts == 0;
    final diff = r.comparison.difference;

    return [
      if (_offline) ...[
        OfflineBanner(savedAt: _savedAt, what: 'report'),
        const SizedBox(height: 12),
      ],
      // 1. Range
      Text(r.range.label,
        style: GoogleFonts.spaceGrotesk(fontSize: 20, fontWeight: FontWeight.w800, color: c.primary)),
      const SizedBox(height: 2),
      Text('compared with ${r.previous.label}', style: GoogleFonts.dmSans(fontSize: 12.5, color: c.muted)),
      const SizedBox(height: 16),

      // 2. AI summary
      _card(c, child: _aiSummary(r.ai, c)),
      const SizedBox(height: 16),

      if (empty)
        _card(c, child: Text('No receipts in this period.',
          style: GoogleFonts.dmSans(fontSize: 14, color: c.primary)))
      else ...[
        // 3. Totals
        _card(c, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${formatJd(r.totals.total)} JD',
            style: GoogleFonts.spaceGrotesk(fontSize: 32, fontWeight: FontWeight.w800, color: c.primary)),
          const SizedBox(height: 6),
          Text('${r.totals.receipts} receipt${r.totals.receipts == 1 ? '' : 's'} · '
              'average ${formatJd(r.totals.average)} JD',
            style: GoogleFonts.dmSans(fontSize: 13, color: c.muted)),
        ])),
        const SizedBox(height: 16),

        // 4. Comparison
        _card(c, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _title('Compared with the previous period', c),
          _row('Previous total', '${formatJd(r.comparison.previousTotal)} JD', c),
          _row('Difference', '${diff > 0 ? '+' : diff < 0 ? '−' : ''}${formatJd(diff.abs())} JD', c),
          _row('Change', r.comparison.changeLabel, c),
        ])),
        const SizedBox(height: 16),

        // 5. Categories
        _card(c, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _title('By category', c),
          for (final cat in r.byCategory) ...[
            Row(children: [
              Expanded(child: Text(cat.category, style: GoogleFonts.dmSans(fontSize: 13.5, color: c.primary))),
              Text('${formatJd(cat.total)} JD', style: GoogleFonts.dmSans(fontSize: 13.5, color: c.primary)),
              const SizedBox(width: 10),
              SizedBox(width: 40, child: Text('${cat.sharePercent}%', textAlign: TextAlign.right,
                style: GoogleFonts.dmSans(fontSize: 12.5, color: c.muted))),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: cat.sharePercent / 100, minHeight: 6,
                color: CategoryColors.of(cat.category), backgroundColor: c.border),
            ),
            const SizedBox(height: 4),
            Text('${cat.receipts} receipt${cat.receipts == 1 ? '' : 's'}',
              style: GoogleFonts.dmSans(fontSize: 11.5, color: c.muted)),
            const SizedBox(height: 12),
          ],
        ])),
        const SizedBox(height: 16),

        // 6. Months
        _card(c, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _title('By month', c),
          for (final m in r.byMonth)
            _row('${m.label}${m.partial ? ' (so far)' : ''}', '${formatJd(m.total)} JD', c),
        ])),
        const SizedBox(height: 16),

        // 7. Stores and biggest receipts
        _card(c, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _title('Top stores', c),
          for (final s in r.topStores) _row(s.storeName, '${formatJd(s.total)} JD', c),
          const SizedBox(height: 12),
          _title('Biggest receipts', c),
          for (final b in r.biggestReceipts)
            _row('${_date(b.date)} · ${b.storeName} · ${b.category}', '${formatJd(b.total)} JD', c),
        ])),
      ],
      const SizedBox(height: 20),

      // 8. Email
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _offline || _emailing
              ? null
              : verified ? _email : () => VerifyEmailScreen.open(context),
          icon: _emailing
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold))
              : const Icon(Icons.mail_outline_rounded),
          label: Text(verified ? 'Email me this report' : 'Verify your email to get reports by email'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.gold,
            side: BorderSide(color: AppColors.gold.withValues(alpha: 0.5)),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    ];
  }

  Widget _aiSummary(ReportAi ai, _C c) {
    final header = Row(children: [
      ShaderMask(
        shaderCallback: (b) => AppColors.goldGlow.createShader(b),
        child: const Icon(Icons.auto_awesome_rounded, size: 18, color: Colors.white),
      ),
      const SizedBox(width: 8),
      Text('AI summary', style: GoogleFonts.spaceGrotesk(fontSize: 14, fontWeight: FontWeight.w700, color: c.primary)),
    ]);
    final Widget body = switch (ai.status) {
      ReportAiStatus.ready => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(ai.headline, style: GoogleFonts.dmSans(fontSize: 15, fontWeight: FontWeight.w700, color: c.primary)),
          const SizedBox(height: 8),
          Text(ai.narrative, style: GoogleFonts.dmSans(fontSize: 13.5, color: c.primary, height: 1.5)),
          const SizedBox(height: 10),
          for (final tip in ai.tips)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.lightbulb_rounded, color: AppColors.mint, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(tip, style: GoogleFonts.dmSans(fontSize: 13, color: c.primary, height: 1.45))),
              ]),
            ),
          const SizedBox(height: 4),
          Text('AI-generated · numbers calculated by Nexus',
            style: GoogleFonts.dmSans(fontSize: 11.5, color: c.muted)),
        ]),
      ReportAiStatus.notEnoughData => Text(
          'The AI summary appears after ${ai.minReceipts} receipts in this period.',
          style: GoogleFonts.dmSans(fontSize: 13.5, color: c.muted)),
      ReportAiStatus.unavailable => Text(ai.error ?? 'AI summary is not available right now.',
          style: GoogleFonts.dmSans(fontSize: 13.5, color: c.muted)),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [header, const SizedBox(height: 12), body]);
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static String _date(DateTime d) => '${d.day} ${_months[d.month - 1]}';

  Widget _card(_C c, {required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
    decoration: BoxDecoration(
      color: c.surface,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: c.border),
    ),
    child: child,
  );

  Widget _title(String text, _C c) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: GoogleFonts.spaceGrotesk(fontSize: 14, fontWeight: FontWeight.w700, color: c.primary)),
  );

  Widget _row(String label, String value, _C c) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Text(label, style: GoogleFonts.dmSans(fontSize: 13.5, color: c.primary))),
      const SizedBox(width: 12),
      Text(value, style: GoogleFonts.dmSans(fontSize: 13.5, fontWeight: FontWeight.w600, color: c.primary)),
    ]),
  );
}

class _C {
  final Color surface, border, primary, muted;
  _C(bool isDark)
      : surface = isDark ? AppColors.surface : AppColors.surfaceLight,
        border = isDark ? AppColors.border : AppColors.borderLight,
        primary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight,
        muted = isDark ? AppColors.textMuted : AppColors.textMutedLight;
}
