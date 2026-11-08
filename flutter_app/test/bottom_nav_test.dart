import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus_app/widgets/bottom_nav.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // No font downloads in tests.
  GoogleFonts.config.allowRuntimeFetching = false;

  testWidgets('4 tabs: Home, Archive, Trends (2), Profile (3)', (tester) async {
    final taps = <int>[];
    var qr = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: NexusBottomNav(
          currentIndex: 0,
          onTap: taps.add,
          onQrTap: () => qr++,
        ),
      ),
    ));

    for (final label in ['Home', 'Archive', 'Trends', 'Profile']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('Trends'));
    await tester.tap(find.text('Profile'));
    await tester.tap(find.text('Archive'));
    await tester.tap(find.byIcon(Icons.qr_code_rounded));
    expect(taps, [2, 3, 1]);
    expect(qr, 1);
  });
}
