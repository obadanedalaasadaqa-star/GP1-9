import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/ai_chat_session.dart';
import '../core/constants.dart';
import '../core/realtime_service.dart';
import '../core/theme_provider.dart';
import '../widgets/ai_chat_view.dart';
import '../widgets/insight_card.dart';
import '../widgets/report_view.dart';

enum AiTab { insight, ask, report }

/// The AI page, pushed over the tabs (from the Home teaser or the Trends AI
/// button): Insight, Ask and Report.
class AiScreen extends StatefulWidget {
  final AiTab initialTab;

  /// Text to put in the Ask input (never sent on its own).
  final String? draft;

  const AiScreen({super.key, this.initialTab = AiTab.insight, this.draft});

  /// The tabs shown, in order. One list, so a tab can be hidden in one line.
  static const tabs = [AiTab.insight, AiTab.ask, AiTab.report];

  /// The suggestions on the Insight tab (and in the empty chat).
  static const suggestions = [
    'How much did I spend this month?',
    'Where can I save money?',
    'Compare this month with last month',
  ];

  /// Push the page. A pushed route doesn't see the shell's providers, so the
  /// caller's RealtimeService and AiChatSession are passed on. Without a
  /// session above (tests), a fallback one is made here and disposed when the
  /// page closes; the shell's session is never disposed here.
  static Future<void> open(BuildContext context, {AiTab tab = AiTab.insight, String? draft}) {
    final realtime = context.read<RealtimeService?>();
    final shellSession = context.read<AiChatSession?>();
    final fallback = shellSession == null ? AiChatSession() : null;
    final session = shellSession ?? fallback!;
    final route = MaterialPageRoute<void>(
      builder: (_) => MultiProvider(
        providers: [
          if (realtime != null) ChangeNotifierProvider<RealtimeService>.value(value: realtime),
          ChangeNotifierProvider<AiChatSession>.value(value: session),
        ],
        child: AiScreen(initialTab: tab, draft: draft),
      ),
    );
    return Navigator.of(context).push(route).then((_) => fallback?.dispose());
  }

  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final TextEditingController _input;
  final _insightKey = GlobalKey<InsightCardState>();

  @override
  void initState() {
    super.initState();
    final initial = AiScreen.tabs.indexOf(widget.initialTab);
    _tabs = TabController(length: AiScreen.tabs.length, vsync: this, initialIndex: initial < 0 ? 0 : initial);
    _tabs.addListener(() {
      if (mounted) setState(() {}); // the "New chat" action follows the tab
    });
    _input = TextEditingController(text: widget.draft ?? '');
  }

  @override
  void dispose() {
    _tabs.dispose();
    _input.dispose();
    super.dispose();
  }

  void _goTo(AiTab tab) {
    final i = AiScreen.tabs.indexOf(tab);
    if (i >= 0) _tabs.animateTo(i);
  }

  // A suggestion fills the Ask input; the user sends it (no surprise cost).
  void _suggest(String text) {
    _input.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    _goTo(AiTab.ask);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeProvider>().isDark;
    final chat = context.watch<AiChatSession>();
    final bg = isDark ? AppColors.bg : AppColors.bgLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted = isDark ? AppColors.textMuted : AppColors.textMutedLight;
    final onAsk = AiScreen.tabs[_tabs.index] == AiTab.ask;

    return Scaffold(
      backgroundColor: bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 12, 4),
              child: Row(children: [
                IconButton(
                  tooltip: 'Back',
                  icon: Icon(Icons.arrow_back_rounded, color: textPrimary),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text('AI insights',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 24, fontWeight: FontWeight.w800, color: textPrimary, letterSpacing: -0.5)),
                ),
                if (onAsk && chat.messages.isNotEmpty)
                  IconButton(
                    tooltip: 'New chat',
                    icon: const Icon(Icons.refresh_rounded, color: AppColors.gold),
                    onPressed: chat.sending ? null : chat.clear,
                  ),
                ShaderMask(
                  shaderCallback: (b) => AppColors.goldGlow.createShader(b),
                  child: const Icon(Icons.auto_awesome_rounded, size: 24, color: Colors.white),
                ),
                const SizedBox(width: 8),
              ]),
            ),
            TabBar(
              controller: _tabs,
              indicatorColor: AppColors.gold,
              labelColor: AppColors.gold,
              unselectedLabelColor: textMuted,
              labelStyle: GoogleFonts.dmSans(fontSize: 14, fontWeight: FontWeight.w700),
              unselectedLabelStyle: GoogleFonts.dmSans(fontSize: 14, fontWeight: FontWeight.w500),
              tabs: [for (final t in AiScreen.tabs) Tab(text: _label(t))],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  for (final t in AiScreen.tabs)
                    switch (t) {
                      AiTab.insight => _InsightTab(
                          insightKey: _insightKey,
                          onSuggest: _suggest,
                          onReport: AiScreen.tabs.contains(AiTab.report) ? () => _goTo(AiTab.report) : null,
                        ),
                      AiTab.ask => AiChatView(controller: _input),
                      AiTab.report => const ReportView(),
                    },
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _label(AiTab t) => switch (t) {
        AiTab.insight => 'Insight',
        AiTab.ask => 'Ask',
        AiTab.report => 'Report',
      };
}

class _InsightTab extends StatefulWidget {
  final GlobalKey<InsightCardState> insightKey;
  final ValueChanged<String> onSuggest;
  final VoidCallback? onReport;
  const _InsightTab({required this.insightKey, required this.onSuggest, this.onReport});

  @override
  State<_InsightTab> createState() => _InsightTabState();
}

// Kept alive so switching tabs doesn't reload the insight.
class _InsightTabState extends State<_InsightTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = context.watch<ThemeProvider>().isDark;
    final surface = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border = isDark ? AppColors.border : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted = isDark ? AppColors.textMuted : AppColors.textMutedLight;

    return RefreshIndicator(
      color: AppColors.gold,
      backgroundColor: surface,
      onRefresh: () => widget.insightKey.currentState?.reload() ?? Future<void>.value(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InsightCard(key: widget.insightKey),
            const SizedBox(height: 24),
            Text('TRY ASKING',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 11, fontWeight: FontWeight.w700, color: textMuted, letterSpacing: 2)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in AiScreen.suggestions)
                  ActionChip(
                    label: Text(s, style: GoogleFonts.dmSans(fontSize: 12.5, color: textPrimary)),
                    onPressed: () => widget.onSuggest(s),
                    backgroundColor: surface,
                    side: BorderSide(color: border),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
              ],
            ),
            if (widget.onReport != null) ...[
              const SizedBox(height: 24),
              Material(
                color: surface,
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: widget.onReport,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: border),
                    ),
                    child: Row(children: [
                      const Icon(Icons.summarize_rounded, color: AppColors.gold),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Create a report',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 14, fontWeight: FontWeight.w700, color: textPrimary)),
                          const SizedBox(height: 2),
                          Text('1, 3, 6 or 12 months, or your own dates. Email it to yourself.',
                            style: GoogleFonts.dmSans(fontSize: 12, color: textMuted)),
                        ]),
                      ),
                      Icon(Icons.chevron_right_rounded, color: textMuted),
                    ]),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
