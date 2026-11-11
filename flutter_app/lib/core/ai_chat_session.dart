import 'package:flutter/foundation.dart';
import 'ai_models.dart';
import 'api_client.dart';

/// The Ask AI chat for one login session. Lives in the main shell, so it
/// survives closing and reopening the AI page, and is gone after logout or an
/// app restart. Never written to disk; the server keeps no history either.
class AiChatSession extends ChangeNotifier {
  static const historyLimit = 10; // messages sent back (5 pairs)

  final List<ChatMessage> _messages = [];
  bool _sending = false;
  int? _remainingToday;
  bool _disposed = false;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get sending => _sending;

  /// Questions left today (from the server), or null when unknown.
  int? get remainingToday => _remainingToday;

  @visibleForTesting
  bool get isDisposed => _disposed;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // A request can outlive the shell (logout, session expiry): never notify then.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Earlier completed pairs (a question followed by a real answer), the last
  /// [historyLimit] messages. Error bubbles and their questions are left out.
  List<ChatMessage> _history() {
    final pairs = <ChatMessage>[];
    for (var i = 0; i + 1 < _messages.length; i++) {
      final q = _messages[i];
      final a = _messages[i + 1];
      if (q.role == ChatRole.user && a.role == ChatRole.assistant && !a.isError) {
        pairs..add(q)..add(a);
        i++;
      }
    }
    return pairs.length > historyLimit ? pairs.sublist(pairs.length - historyLimit) : pairs;
  }

  Future<void> ask(String question) async {
    final text = question.trim();
    if (text.isEmpty || _sending || _disposed) return;

    final history = _history();
    _messages.add(ChatMessage(role: ChatRole.user, text: text));
    _sending = true;
    _notify();

    try {
      final reply = await ApiClient.askAi(text, history);
      if (_disposed) return;
      _messages.add(ChatMessage(role: ChatRole.assistant, text: reply.answer));
      _remainingToday = reply.remainingToday ?? _remainingToday;
    } on ApiException catch (e) {
      if (_disposed) return;
      _messages.add(ChatMessage(
        role: ChatRole.assistant,
        text: _errorText(e),
        isError: true,
        retryQuestion: text,
      ));
    } catch (_) {
      if (_disposed) return;
      _messages.add(ChatMessage(
        role: ChatRole.assistant,
        text: "You're offline. Ask AI needs a connection.",
        isError: true,
        retryQuestion: text,
      ));
    } finally {
      if (!_disposed) {
        _sending = false;
        _notify();
      }
    }
  }

  static String _errorText(ApiException e) {
    if (e.statusCode == 408 || e.statusCode == 504) return 'The AI took too long. Try again.';
    if (!e.fromServer) return "You're offline. Ask AI needs a connection.";
    return e.message; // 429 limits and other server errors: the server's text
  }

  /// Remove [error] and the question before it, then ask that question again.
  Future<void> retry(ChatMessage error) async {
    final question = error.retryQuestion;
    if (question == null || _sending) return;
    final i = _messages.indexOf(error);
    if (i < 0) return;
    _messages.removeAt(i);
    if (i > 0 && _messages[i - 1].role == ChatRole.user) _messages.removeAt(i - 1);
    await ask(question);
  }

  /// "New chat".
  void clear() {
    if (_sending) return;
    _messages.clear();
    _notify();
  }
}
