import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/ai_chat_session.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/realtime_service.dart';
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
      // The keyboard belongs to the Ask tab only: close it on any other tab.
      if (AiScreen.tabs[_tabs.index] != AiTab.ask) _hideKeyboard();
      if (mounted) setState(() {}); // the "New chat" action follows the tab
    });
    _input = TextEditingController(text: widget.draft ?? '');
  }

  // Leaving the page with the Ask field focused could leave the iOS keyboard
  // open on Home (bug 2026-11-16), so every way out closes it first.
  void _hideKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

  @override
  void dispose() {
    _hideKeyboard();
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
    final nx = Nx.of(context);
    final chat = context.watch<AiChatSession>();
    final pageBg = nx.dark ? AppColors.ink : AppColors.pink;
    final onPage = nx.dark ? Colors.white : AppColors.ink;
    final onAsk = AiScreen.tabs[_tabs.index] == AiTab.ask;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: PopScope(
      // Runs for the back button, the iOS swipe-back and Android back alike.
      onPopInvokedWithResult: (_, _) => _hideKeyboard(),
      child: Scaffold(
        backgroundColor: pageBg,
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                child: Row(children: [
                  const NxBackButton(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('AI insights',
                      style: NxType.display(30, color: onPage, letterSpacing: -1.2)),
                  ),
                  if (onAsk && chat.messages.isNotEmpty)
                    IconButton(
                      tooltip: 'New chat',
                      icon: Icon(Icons.refresh_rounded, color: onPage),
                      onPressed: chat.sending ? null : chat.clear,
                    ),
                ]),
              ),
              // Pill tabs
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  height: 46,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: nx.dark ? AppColors.surface : Colors.white,
                    borderRadius: BorderRadius.circular(23),
                    border: Border.all(color: nx.dark ? AppColors.border : AppColors.ink, width: 2),
                  ),
                  child: TabBar(
                    controller: _tabs,
                    indicator: BoxDecoration(
                      color: nx.dark ? AppColors.lime : AppColors.ink,
                      borderRadius: BorderRadius.circular(19),
                    ),
                    indicatorSize: TabBarIndicatorSize.tab,
                    dividerColor: Colors.transparent,
                    labelColor: nx.dark ? AppColors.ink : Colors.white,
                    unselectedLabelColor: nx.text,
                    labelStyle: NxType.body(14, weight: FontWeight.w700),
                    unselectedLabelStyle: NxType.body(14, weight: FontWeight.w600),
                    splashFactory: NoSplash.splashFactory,
                    overlayColor: WidgetStateProperty.all(Colors.transparent),
                    tabs: [for (final t in AiScreen.tabs) Tab(text: _label(t))],
                  ),
                ),
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
    final nx = Nx.of(context);
    final onPage = nx.dark ? Colors.white : AppColors.ink;

    return RefreshIndicator(
      color: AppColors.ink,
      backgroundColor: AppColors.lime,
      onRefresh: () => widget.insightKey.currentState?.reload() ?? Future<void>.value(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InsightCard(key: widget.insightKey),
            const SizedBox(height: 22),
            Text('TRY ASKING', style: NxType.label(onPage)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final s in AiScreen.suggestions)
                  Pressable(
                    onTap: () => widget.onSuggest(s),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                      decoration: BoxDecoration(
                        color: nx.dark ? AppColors.surface : Colors.white,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: nx.dark ? AppColors.border : AppColors.ink, width: 2),
                      ),
                      child: Text(s, style: NxType.body(14, color: nx.text,
                        weight: FontWeight.w700)),
                    ),
                  ),
              ],
            ),
            if (widget.onReport != null) ...[
              const SizedBox(height: 22),
              Pressable(
                onTap: widget.onReport,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: nx.dark ? AppColors.cobalt : AppColors.ink,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(children: [
                    const NxIconTile(icon: Icons.description_outlined,
                      color: AppColors.lime, size: 46, tilt: -4),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Create a report',
                          style: NxType.display(18, color: Colors.white,
                            weight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text('1, 3, 6 or 12 months, or your own dates. Email it to yourself.',
                          style: NxType.body(12.5, color: AppColors.textMuted)),
                      ]),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: Colors.white),
                  ]),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
