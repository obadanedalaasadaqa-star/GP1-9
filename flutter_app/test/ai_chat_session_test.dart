import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/ai_chat_session.dart';
import 'package:nexus_app/core/ai_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<T> withHttp<T>(Future<http.Response> Function(http.Request) handler, Future<T> Function() body) =>
    http.runWithClient(body, () => MockClient(handler));

http.Response answer(String text, {int? left = 29}) =>
    http.Response(jsonEncode({'answer': text, 'toolsUsed': [], 'remainingToday': left}), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  test('ask: user bubble and sending, then the answer', () async {
    final s = AiChatSession();
    final reply = Completer<http.Response>();
    await withHttp((_) => reply.future, () async {
      final f = s.ask('  How much?  ');
      await Future<void>.delayed(Duration.zero);
      expect(s.messages.single.text, 'How much?');
      expect(s.sending, isTrue);
      reply.complete(answer('So far 287.99 JD.', left: 3));
      await f;
    });
    expect(s.sending, isFalse);
    expect(s.messages.map((m) => m.text), ['How much?', 'So far 287.99 JD.']);
    expect(s.messages.last.role, ChatRole.assistant);
    expect(s.remainingToday, 3);
  });

  test('history: completed pairs only, no error bubbles, at most 10', () async {
    final s = AiChatSession();
    final bodies = <Map<String, dynamic>>[];
    var n = 0;
    await withHttp((req) async {
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
      n++;
      if (n == 2) return http.Response(jsonEncode({'error': 'Busy.'}), 503);
      return answer('A$n');
    }, () async {
      for (var i = 1; i <= 8; i++) {
        await s.ask('Q$i');
      }
    });
    // Q2 failed: its question and error bubble are never history.
    final last = (bodies.last['history'] as List).cast<Map<String, dynamic>>();
    expect(last, hasLength(10));
    expect(last.every((m) => m['text'] != 'Q2' && m['text'] != 'Busy.'), isTrue);
    expect(last.first, {'role': 'user', 'text': 'Q3'});
    expect(last.last, {'role': 'assistant', 'text': 'A7'});
    expect(bodies.first['history'], isEmpty);
  });

  test('offline: error bubble with retryQuestion; retry resends and removes it', () async {
    final s = AiChatSession();
    await withHttp((_) async => throw const SocketException('down'), () => s.ask('How much?'));
    final err = s.messages.last;
    expect(err.isError, isTrue);
    expect(err.text, "You're offline. Ask AI needs a connection.");
    expect(err.retryQuestion, 'How much?');

    await withHttp((_) async => answer('So far 287.99 JD.'), () => s.retry(err));
    expect(s.messages.map((m) => m.text), ['How much?', 'So far 287.99 JD.']);
    expect(s.messages.any((m) => m.isError), isFalse);
  });

  test('429 shows the server text; ask while sending is ignored; clear empties', () async {
    final s = AiChatSession();
    final reply = Completer<http.Response>();
    var calls = 0;
    await withHttp((_) {
      calls++;
      return reply.future;
    }, () async {
      final f = s.ask('One');
      await Future<void>.delayed(Duration.zero);
      await s.ask('Two'); // ignored
      reply.complete(http.Response(
          jsonEncode({'error': "You've reached today's limit of 30 questions. Try again tomorrow."}), 429));
      await f;
    });
    expect(calls, 1);
    expect(s.messages.last.text, "You've reached today's limit of 30 questions. Try again tomorrow.");
    s.clear();
    expect(s.messages, isEmpty);
  });

  test('a 504 or timeout says the AI took too long', () async {
    final s = AiChatSession();
    await withHttp((_) async => http.Response(jsonEncode({'error': 'x'}), 504), () => s.ask('q'));
    expect(s.messages.last.text, 'The AI took too long. Try again.');
  });

  for (final ok in [true, false]) {
    test('dispose during a request (${ok ? 'success' : 'error'}): no notify, no throw', () async {
      final s = AiChatSession();
      var notified = 0;
      s.addListener(() => notified++);
      final reply = Completer<http.Response>();
      await withHttp((_) => reply.future, () async {
        final f = s.ask('q');
        await Future<void>.delayed(Duration.zero);
        final before = notified;
        s.dispose();
        expect(s.isDisposed, isTrue);
        reply.complete(ok ? answer('fine') : http.Response(jsonEncode({'error': 'x'}), 500));
        await f; // returns normally; a notify after dispose would throw here
        expect(notified, before);
        expect(s.messages, hasLength(1));
      });
    });
  }
}
