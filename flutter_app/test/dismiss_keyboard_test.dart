import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus_app/main.dart' show NexusApp;
import 'package:nexus_app/widgets/dismiss_keyboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

  late FocusNode a;
  late FocusNode b;
  late FocusNode dialogField;
  late int iconTaps;

  /// The app's real builder around: field A, a blank area, an icon button
  /// with a counter, field B, and a button that opens a dialog with a field.
  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(440, 956);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    a = FocusNode();
    b = FocusNode();
    dialogField = FocusNode();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    addTearDown(dialogField.dispose);
    iconTaps = 0;
    await tester.pumpWidget(MaterialApp(
      builder: NexusApp.appBuilder,
      home: Scaffold(
        body: Builder(builder: (context) => Column(children: [
          TextField(key: const ValueKey('a'), focusNode: a),
          const SizedBox(key: ValueKey('blank'), height: 200, width: double.infinity),
          IconButton(
            tooltip: 'Show password',
            icon: const Icon(Icons.visibility_off),
            onPressed: () => iconTaps++,
          ),
          TextField(key: const ValueKey('b'), focusNode: b),
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Dialog title'),
                content: TextField(focusNode: dialogField),
              ),
            ),
            child: const Text('open dialog'),
          ),
        ])),
      ),
    ));
  }

  testWidgets('T1 a tap on a blank area closes the keyboard', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('a')));
    await tester.pump();
    expect(a.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    // Empty space: nothing in the page claims the tap, only the root.
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('blank'))));
    await tester.pump();
    expect(a.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  }, variant: ios);

  testWidgets('T2 a button still gets the tap once, and the field keeps focus', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('a')));
    await tester.pump();
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(iconTaps, 1);
    expect(a.hasFocus, isTrue);
  }, variant: ios);

  testWidgets('T3 tapping another field moves the focus to it', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('a')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('b')));
    await tester.pump();
    expect(a.hasFocus, isFalse);
    expect(b.hasFocus, isTrue);
  }, variant: ios);

  testWidgets('T4 inside a dialog: the title closes the keyboard, the dialog stays; the barrier still closes it',
      (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('open dialog'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)));
    await tester.pump();
    expect(dialogField.hasFocus, isTrue);

    await tester.tap(find.text('Dialog title'));
    await tester.pumpAndSettle();
    expect(dialogField.hasFocus, isFalse);
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tapAt(const Offset(10, 10)); // the barrier
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  }, variant: ios);

  testWidgets('T5 the root adds no tap action for VoiceOver', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          DismissKeyboard(child: Container(key: const ValueKey('plain'), height: 100, color: Colors.white)),
          // Control: an ordinary tap handler does add the action.
          GestureDetector(
            onTap: () {},
            child: Container(key: const ValueKey('control'), height: 100, color: Colors.white),
          ),
        ]),
      ),
    ));
    bool hasTap(String key) =>
        tester.getSemantics(find.byKey(ValueKey(key))).getSemanticsData().hasAction(SemanticsAction.tap);
    expect(hasTap('control'), isTrue);
    expect(hasTap('plain'), isFalse);
    semantics.dispose();
  });
}
