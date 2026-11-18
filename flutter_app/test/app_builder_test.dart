import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/main.dart' show NexusApp;
import 'package:nexus_app/widgets/dismiss_keyboard.dart';

void main() {
  testWidgets('T6 appBuilder wraps the page in DismissKeyboard', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }));

    const page = Text('x');
    final wrapped = NexusApp.appBuilder(ctx, page);
    expect(wrapped, isA<DismissKeyboard>());
    expect((wrapped as DismissKeyboard).child, same(page));

    final empty = NexusApp.appBuilder(ctx, null);
    expect(empty, isA<DismissKeyboard>());
    expect((empty as DismissKeyboard).child, isA<SizedBox>());
  });
}
