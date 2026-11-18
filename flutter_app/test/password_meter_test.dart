import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus_app/core/constants.dart';
import 'package:nexus_app/widgets/password_meter.dart';

// Phase 10, Q-D1 (design P2): text at 12 pt or more in the ink / white text
// colour, and no bar animation under Reduce Motion.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  Future<void> pumpMeter(WidgetTester tester, {required bool reduceMotion, bool dark = false}) async {
    final ctrl = TextEditingController(text: 'Nexus@2027!');
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(body: PasswordMeter(
          controller: ctrl, textMuted: AppColors.textMutedLight, track: AppColors.borderLight)),
      ),
    ));
  }

  testWidgets('no text is below 12 pt, and the words use the text colour', (tester) async {
    await pumpMeter(tester, reduceMotion: false);
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.style!.fontSize, greaterThanOrEqualTo(12), reason: text.data);
      expect(text.style!.color, AppColors.ink, reason: text.data);
    }
  });

  testWidgets('dark: the words are white', (tester) async {
    await pumpMeter(tester, reduceMotion: false, dark: true);
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.style!.color, Colors.white, reason: text.data);
    }
  });

  testWidgets('Reduce Motion: the bar has no animation', (tester) async {
    await pumpMeter(tester, reduceMotion: true);
    for (final bar in tester.widgetList<AnimatedContainer>(find.byType(AnimatedContainer))) {
      expect(bar.duration, Duration.zero);
    }
  });

  testWidgets('without Reduce Motion the bar keeps its 250 ms fill', (tester) async {
    await pumpMeter(tester, reduceMotion: false);
    final bar = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer).first);
    expect(bar.duration, const Duration(milliseconds: 250));
  });
}
