import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexus_app/core/ai_chat_session.dart';
import 'package:nexus_app/core/auth_provider.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:nexus_app/main.dart' show NexusApp;
import 'package:nexus_app/screens/ai_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const answerText = 'So far this month you spent 287.99 JD.';
final userJson = {
  'id': 'u1', 'email': 'u1@nexus.test', 'name': 'Sim Tester', 'firstName': 'Sim', 'lastName': 'Tester',
  'emailVerified': true, 'serialNumber': 'NXS-AAAAA-BBBBB', 'loyaltyPoints': 1, 'createdAt': '2026-01-01T00:00:00.000Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  setUp(() => SharedPreferences.setMockInitialValues({'nexus_token': 't'}));

  late Future<http.Response> Function(http.Request) chat;
  final chatBodies = <Map<String, dynamic>>[];
  Future<http.Response> handler(http.Request req) async {
    if (req.url.path.endsWith('/ai/chat')) {
      chatBodies.add(jsonDecode(req.body) as Map<String, dynamic>);
      return chat(req);
    }
    if (req.url.path.endsWith('/ai/insight')) {
      return http.Response('{"status":"not_enough_data","receiptCount":0,"minReceipts":3}', 200);
    }
    return http.Response('{"error":"not here"}', 404);
  }

  Future<void> run(Future<void> Function() body) =>
      http.runWithClient(body, () => MockClient(handler));

  Future<AuthProvider> signedIn(WidgetTester tester) async {
    final auth = AuthProvider();
    for (var i = 0; i < 20 && auth.loading; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    auth.updateUser(User.fromJson(userJson));
    return auth;
  }

  /// A home page with an "open" button that calls AiScreen.open([tab]).
  /// [session]: the shell's chat session, or none (the fallback is used).
  Future<void> pumpHome(WidgetTester tester, {AiTab tab = AiTab.insight, AiChatSession? session}) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = await signedIn(tester);
    final home = Builder(builder: (context) => Scaffold(
      body: Center(child: TextButton(
        onPressed: () => AiScreen.open(context, tab: tab), child: const Text('open'))),
    ));
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider.value(value: auth),
      ],
      child: MaterialApp(builder: NexusApp.appBuilder, home: session == null
          ? home
          : ChangeNotifierProvider<AiChatSession>.value(value: session, child: home)),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    chatBodies.clear();
    chat = (_) async => http.Response(jsonEncode({'answer': answerText, 'toolsUsed': [], 'remainingToday': 29}), 200);
  });

  testWidgets('tabs; the initial tab follows tab:', (tester) async {
    await run(() async {
      await pumpHome(tester, tab: AiTab.ask);
    });
    expect(find.text('AI insights'), findsOneWidget);
    for (final t in ['Insight', 'Ask', 'Report']) {
      expect(find.widgetWithText(Tab, t), findsOneWidget);
    }
    expect(find.text('Ask about your spending'), findsOneWidget); // the Ask empty state
  });

  testWidgets('a "Try asking" chip fills the Ask input and sends nothing', (tester) async {
    await run(() async {
      await pumpHome(tester);
      await tester.tap(find.text('Compare this month with last month'));
      await tester.pumpAndSettle();
    });
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Compare this month with last month');
    expect(chatBodies, isEmpty);
  });

  testWidgets('ask flow: bubble, typing indicator, disabled send, then the answer', (tester) async {
    final reply = Completer<http.Response>();
    chat = (_) => reply.future;
    final semantics = tester.ensureSemantics();
    await run(() async {
      await pumpHome(tester, tab: AiTab.ask);
      await tester.enterText(find.byType(TextField), 'How much did I spend this month?');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    });
    expect(find.text('How much did I spend this month?'), findsOneWidget);
    expect(find.bySemanticsLabel('Thinking…'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Another');
    await tester.pump();
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded)).onPressed, isNull);

    reply.complete(http.Response(jsonEncode({'answer': answerText, 'toolsUsed': [], 'remainingToday': 3}), 200));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text(answerText), findsOneWidget);
    expect(find.bySemanticsLabel('Thinking…'), findsNothing);
    expect(find.textContaining("Don't type personal details"), findsOneWidget);
    expect(find.textContaining('3 questions left today'), findsOneWidget);
    semantics.dispose();
  });

  Future<void> askOnce(WidgetTester tester, String question) async {
    await run(() async {
      await pumpHome(tester, tab: AiTab.ask);
      await tester.enterText(find.byType(TextField), question);
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('an answer with a chart draws it under the answer', (tester) async {
    chat = (_) async => http.Response(jsonEncode({
          'answer': 'You buy Milk most.', 'toolsUsed': ['get_top_products'], 'remainingToday': 28,
          'chart': {
            'kind': 'bars', 'title': 'Most bought, all receipts', 'unit': 'times',
            'items': [{'label': 'Milk', 'value': 6}, {'label': 'Bread', 'value': 5}],
          },
        }), 200);
    await askOnce(tester, 'What do I buy most?');
    expect(find.text('You buy Milk most.'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-chart')), findsOneWidget);
    expect(find.text('Most bought, all receipts'), findsOneWidget);
    for (final t in ['Milk', 'Bread', '6×', '5×']) {
      expect(find.text(t), findsOneWidget);
    }
  });

  testWidgets('an answer with chart null has no chart', (tester) async {
    chat = (_) async => http.Response(jsonEncode({
          'answer': answerText, 'toolsUsed': ['list_receipts'], 'remainingToday': 28, 'chart': null,
        }), 200);
    await askOnce(tester, 'Show my receipts');
    expect(find.text(answerText), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-chart')), findsNothing);
  });

  testWidgets('an error bubble shows "Try again", which resends', (tester) async {
    var n = 0;
    chat = (_) async => ++n == 1
        ? http.Response(jsonEncode({'error': 'The AI service is busy. Try again in a minute.'}), 503)
        : http.Response(jsonEncode({'answer': answerText, 'toolsUsed': [], 'remainingToday': 28}), 200);
    await run(() async {
      await pumpHome(tester, tab: AiTab.ask);
      await tester.enterText(find.byType(TextField), 'How much?');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(find.text('The AI service is busy. Try again in a minute.'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
    });
    expect(n, 2);
    expect(find.text(answerText), findsOneWidget);
    expect(find.text('The AI service is busy. Try again in a minute.'), findsNothing);
    expect(find.textContaining('questions left today'), findsNothing); // 28 > 5
  });

  testWidgets('length: 501 emoji are cut to 500 code points, and 500 are sent', (tester) async {
    await run(() async {
      await pumpHome(tester, tab: AiTab.ask);
      await tester.enterText(find.byType(TextField), '😀' * 501);
      await tester.pump();
      final text = tester.widget<TextField>(find.byType(TextField)).controller!.text;
      expect(text.runes.length, 500);
      expect(find.text('500/500'), findsOneWidget);
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
    });
    expect((chatBodies.single['question'] as String).runes.length, 500);
  });

  testWidgets('fallback session: disposed when the page closes', (tester) async {
    late AiChatSession seen;
    await run(() async {
      await pumpHome(tester);
      seen = Provider.of<AiChatSession>(tester.element(find.byType(AiScreen)), listen: false);
      expect(seen.isDisposed, isFalse);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
    });
    expect(seen.isDisposed, isTrue);
  });

  testWidgets('a shell session is passed on and never disposed by the page', (tester) async {
    final shell = AiChatSession();
    addTearDown(shell.dispose);
    await run(() async {
      await pumpHome(tester, session: shell);
      expect(Provider.of<AiChatSession>(tester.element(find.byType(AiScreen)), listen: false), same(shell));
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
    });
    expect(shell.isDisposed, isFalse);
  });

  group('T13 keyboard', () {
    final ios = TargetPlatformVariant.only(TargetPlatform.iOS);
    bool inputFocused(WidgetTester tester) => tester
        .widget<EditableText>(find.descendant(of: find.byType(TextField), matching: find.byType(EditableText)))
        .focusNode
        .hasFocus;

    testWidgets('Send closes the keyboard and asks once', (tester) async {
      await run(() async {
        await pumpHome(tester, tab: AiTab.ask);
        await tester.enterText(find.byType(TextField), 'How much did I spend this month?');
        await tester.pump();
        expect(inputFocused(tester), isTrue);
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        expect(inputFocused(tester), isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        await tester.pumpAndSettle();
      });
      expect(chatBodies, hasLength(1));
    }, variant: ios);

    testWidgets('keyboard send and the Send button in the same frame ask once (2 in total, not 3)',
        (tester) async {
      await run(() async {
        await pumpHome(tester, tab: AiTab.ask);
        await tester.enterText(find.byType(TextField), 'First question');
        await tester.pump();
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();
        expect(chatBodies, hasLength(1));

        await tester.enterText(find.byType(TextField), 'Second question');
        await tester.pump();
        // No pump in between: both run before the next frame rebuilds the button.
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();
      });
      expect(chatBodies.map((b) => b['question']), ['First question', 'Second question']);
    }, variant: ios);

    testWidgets('a tap on the chat area or a drag of the chat list closes the keyboard', (tester) async {
      chat = (_) async => http.Response(
          jsonEncode({'answer': List.filled(120, 'A long answer line.').join('\n'), 'toolsUsed': [], 'remainingToday': 28}),
          200);
      await run(() async {
        await pumpHome(tester, tab: AiTab.ask);
        // Empty state: a tap on its title.
        await tester.tap(find.byType(TextField));
        await tester.pump();
        expect(inputFocused(tester), isTrue);
        await tester.tap(find.text('Ask about your spending'));
        await tester.pump();
        expect(inputFocused(tester), isFalse);

        await tester.enterText(find.byType(TextField), 'How much?');
        await tester.pump();
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();
      });
      // The list has scrolled to the answer, so find it from there.
      final list = find.ancestor(of: find.textContaining('A long answer line.'), matching: find.byType(ListView)).first;
      expect(tester.state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first).position.maxScrollExtent,
          greaterThan(0));

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(inputFocused(tester), isTrue);
      await tester.tapAt(tester.getRect(list).topCenter + const Offset(0, 4));
      await tester.pump();
      expect(inputFocused(tester), isFalse);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(inputFocused(tester), isTrue);
      await tester.drag(list, const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(inputFocused(tester), isFalse);
      expect(chatBodies, hasLength(1));
    }, variant: ios);
  });
}
