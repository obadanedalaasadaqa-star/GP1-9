import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/ai_chat_session.dart';
import '../core/ai_models.dart';
import '../core/constants.dart';
import '../core/design.dart';
import 'charts/chat_chart_view.dart';

/// Cuts the text to [max] code points (runes), the unit the server counts,
/// so emoji count as one character. A long paste is cut, not dropped.
class RuneLimitFormatter extends TextInputFormatter {
  final int max;
  const RuneLimitFormatter(this.max);

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.runes.length <= max) return newValue;
    final text = String.fromCharCodes(newValue.text.runes.take(max));
    int clamp(int offset) => offset < 0 ? offset : (offset > text.length ? text.length : offset);
    return TextEditingValue(
      text: text,
      selection: newValue.selection.copyWith(
        baseOffset: clamp(newValue.selection.baseOffset),
        extentOffset: clamp(newValue.selection.extentOffset),
      ),
    );
  }
}

/// The Ask tab: chat bubbles, a typing indicator and the input row.
/// [controller] belongs to the AI page, so a suggestion can fill it.
class AiChatView extends StatefulWidget {
  final TextEditingController controller;
  const AiChatView({super.key, required this.controller});

  static const maxQuestion = 500;
  static const examples = [
    'How much did I spend this month?',
    'Where can I save money?',
    'Compare this month with last month',
    'What did I buy at Carrefour?',
  ];

  @override
  State<AiChatView> createState() => _AiChatViewState();
}

class _AiChatViewState extends State<AiChatView> {
  final _scroll = ScrollController();
  int _shown = 0; // messages on screen, to scroll down when one is added

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _scroll.dispose();
    super.dispose();
  }

  void _onText() {
    if (mounted) setState(() {}); // send button and counter
  }

  void _send(AiChatSession chat) {
    final text = widget.controller.text.trim();
    if (text.isEmpty || chat.sending) return;
    widget.controller.clear();
    chat.ask(text);
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<AiChatSession>();
    final nx = Nx.of(context);
    // Cards on the page (white on pink, raised on ink) and text on the page.
    final surface = nx.dark ? AppColors.surface : Colors.white;
    final border = nx.dark ? AppColors.border : AppColors.ink;
    final textPrimary = nx.text;
    final textMuted = nx.muted;
    final onPage = nx.dark ? AppColors.textMuted : AppColors.ink;

    final messages = chat.messages;
    final count = messages.length + (chat.sending ? 1 : 0);
    if (count != _shown) {
      _shown = count;
      _scrollDown();
    }

    final runes = widget.controller.text.runes.length;
    final canSend = !chat.sending && widget.controller.text.trim().isNotEmpty;
    final left = chat.remainingToday;

    return Column(
      children: [
        Expanded(
          child: messages.isEmpty && !chat.sending
              ? _empty(nx.dark ? Colors.white : AppColors.ink, onPage, surface, border)
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  itemCount: count,
                  itemBuilder: (_, i) => i == messages.length
                      ? _TypingIndicator(color: textMuted, surface: surface, border: border)
                      : _Bubble(
                          message: messages[i],
                          surface: surface,
                          border: border,
                          textPrimary: textPrimary,
                          onRetry: chat.sending ? null : () => chat.retry(messages[i]),
                        ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(18, 4, 6, 4),
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: border, width: 2),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: TextField(
                            controller: widget.controller,
                            minLines: 1,
                            maxLines: 4,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(chat),
                            inputFormatters: const [RuneLimitFormatter(AiChatView.maxQuestion)],
                            style: NxType.body(15, color: textPrimary),
                            decoration: InputDecoration(
                              hintText: 'Ask about your spending…',
                              hintStyle: NxType.body(15, color: textMuted,
                                weight: FontWeight.w400),
                              border: InputBorder.none,
                              isDense: true,
                              counterText: runes >= 450 ? '$runes/${AiChatView.maxQuestion}' : null,
                              counterStyle: NxType.mono(12, color: textMuted),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: IconButton(
                          tooltip: 'Send',
                          onPressed: canSend ? () => _send(chat) : null,
                          style: IconButton.styleFrom(
                            backgroundColor: AppColors.cobalt,
                            disabledBackgroundColor: AppColors.cobalt.withValues(alpha: 0.35),
                            fixedSize: const Size(44, 44),
                          ),
                          icon: const Icon(Icons.arrow_upward_rounded,
                            color: Colors.white, size: 22),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  "Answers use your Nexus receipts. Don't type personal details."
                  '${left != null && left <= 5 ? ' · $left question${left == 1 ? '' : 's'} left today' : ''}',
                  style: NxType.body(11.5, color: onPage),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _empty(Color textPrimary, Color textMuted, Color surface, Color border) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
    children: [
      Text('Ask about your spending',
        style: NxType.display(26, color: textPrimary, letterSpacing: -0.8)),
      const SizedBox(height: 6),
      Text('Answers come from your own receipts in Nexus.',
        style: NxType.body(14, color: textMuted)),
      const SizedBox(height: 18),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final q in AiChatView.examples)
            Pressable(
              onTap: () => widget.controller.value = TextEditingValue(
                text: q, selection: TextSelection.collapsed(offset: q.length)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: border, width: 2),
                ),
                child: Text(q, style: NxType.body(14,
                  color: Nx.of(context).text, weight: FontWeight.w700)),
              ),
            ),
        ],
      ),
    ],
  );
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final Color surface, border, textPrimary;
  final VoidCallback? onRetry;
  const _Bubble({
    required this.message,
    required this.surface,
    required this.border,
    required this.textPrimary,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;
    final dark = Nx.of(context).dark;
    final Color bg;
    final Color edge;
    final Color fg;
    if (isUser) {
      bg = dark ? AppColors.lime : AppColors.ink;
      edge = bg;
      fg = dark ? AppColors.ink : Colors.white;
    } else if (message.isError) {
      bg = AppColors.coral;
      edge = AppColors.ink;
      fg = AppColors.ink;
    } else {
      bg = surface;
      edge = border;
      fg = textPrimary;
    }
    final style = NxType.body(14.5, color: fg, height: 1.45);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isUser ? 18 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 18),
            ),
            border: Border.all(color: edge, width: 2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isUser || message.isError)
                Text(message.text, style: style)
              else
                SelectableText(message.text, style: style),
              if (message.chart != null) ChatChartView(chart: message.chart!),
              if (message.isError && message.retryQuestion != null)
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.ink, padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  child: const Text('Try again'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Three pulsing dots while the AI is thinking.
class _TypingIndicator extends StatefulWidget {
  final Color color, surface, border;
  const _TypingIndicator({required this.color, required this.surface, required this.border});

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        label: 'Thinking…',
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: widget.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: widget.border, width: 2),
          ),
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 3; i++)
                  Container(
                    width: 7,
                    height: 7,
                    margin: EdgeInsets.only(right: i < 2 ? 5 : 0),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.color.withValues(
                        alpha: 0.3 + 0.7 * (((_ctrl.value * 3 - i) % 3) < 1 ? 1 : 0)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
