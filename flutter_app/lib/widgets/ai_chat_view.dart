import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/ai_chat_session.dart';
import '../core/ai_models.dart';
import '../core/constants.dart';
import '../core/theme_provider.dart';

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
    final isDark = context.watch<ThemeProvider>().isDark;
    final surface = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border = isDark ? AppColors.border : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted = isDark ? AppColors.textMuted : AppColors.textMutedLight;

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
              ? _empty(textPrimary, textMuted, surface, border)
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
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 10),
          decoration: BoxDecoration(
            color: surface,
            border: Border(top: BorderSide(color: border)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: widget.controller,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(chat),
                        inputFormatters: const [RuneLimitFormatter(AiChatView.maxQuestion)],
                        style: GoogleFonts.dmSans(fontSize: 14.5, color: textPrimary),
                        decoration: InputDecoration(
                          hintText: 'Ask about your spending…',
                          hintStyle: GoogleFonts.dmSans(fontSize: 14, color: textMuted),
                          border: InputBorder.none,
                          isDense: true,
                          counterText: runes >= 450 ? '$runes/${AiChatView.maxQuestion}' : null,
                          counterStyle: GoogleFonts.dmSans(fontSize: 11, color: textMuted),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Send',
                      onPressed: canSend ? () => _send(chat) : null,
                      icon: Icon(Icons.send_rounded,
                        color: canSend ? AppColors.gold : textMuted.withValues(alpha: 0.5)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  "Answers use your Nexus receipts. Don't type personal details."
                  '${left != null && left <= 5 ? ' · $left question${left == 1 ? '' : 's'} left today' : ''}',
                  style: GoogleFonts.dmSans(fontSize: 11, color: textMuted),
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
        style: GoogleFonts.spaceGrotesk(fontSize: 18, fontWeight: FontWeight.w700, color: textPrimary)),
      const SizedBox(height: 6),
      Text('Answers come from your own receipts in Nexus.',
        style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
      const SizedBox(height: 18),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final q in AiChatView.examples)
            ActionChip(
              label: Text(q, style: GoogleFonts.dmSans(fontSize: 12.5, color: textPrimary)),
              backgroundColor: surface,
              side: BorderSide(color: border),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              onPressed: () => widget.controller.value = TextEditingValue(
                text: q, selection: TextSelection.collapsed(offset: q.length)),
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
    final Color bg;
    final Color edge;
    if (isUser) {
      bg = AppColors.gold.withValues(alpha: 0.16);
      edge = AppColors.gold.withValues(alpha: 0.35);
    } else if (message.isError) {
      bg = AppColors.alert.withValues(alpha: 0.10);
      edge = AppColors.alert.withValues(alpha: 0.35);
    } else {
      bg = surface;
      edge = border;
    }
    final style = GoogleFonts.dmSans(fontSize: 14, color: textPrimary, height: 1.45);

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
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isUser ? 16 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 16),
            ),
            border: Border.all(color: edge),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isUser || message.isError)
                Text(message.text, style: style)
              else
                SelectableText(message.text, style: style),
              if (message.isError && message.retryQuestion != null)
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.gold, padding: EdgeInsets.zero,
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
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: widget.border),
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
