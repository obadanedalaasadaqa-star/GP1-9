import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/constants.dart';
import 'package:nexus_app/widgets/face_id_glyph.dart';

void main() {
  testWidgets('T20 the glyph: one painter, 48x48, the caller colour, no semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: FaceIdGlyph(size: 48, color: AppColors.ink)),
    ));
    final glyph = find.descendant(of: find.byType(FaceIdGlyph), matching: find.byType(CustomPaint));
    expect(glyph, findsOneWidget);
    final painter = tester.widget<CustomPaint>(glyph).painter!;
    expect(painter, isA<FaceIdPainter>());
    expect((painter as FaceIdPainter).color, AppColors.ink);
    expect(tester.getSize(glyph), const Size(48, 48));
    // Strokes only (four brackets, the nose, the smile; eyes are lines), in the given colour.
    expect(
        tester.renderObject(glyph),
        paints
          ..path(color: AppColors.ink, style: PaintingStyle.stroke, strokeWidth: 2.0)
          ..path(color: AppColors.ink, style: PaintingStyle.stroke)
          ..path(color: AppColors.ink, style: PaintingStyle.stroke)
          ..path(color: AppColors.ink, style: PaintingStyle.stroke)
          ..line(color: AppColors.ink)
          ..line(color: AppColors.ink)
          ..path(color: AppColors.ink)
          ..path(color: AppColors.ink));
    // Decorative: no semantics node of its own.
    expect(find.byType(ExcludeSemantics), findsWidgets);
    expect(tester.getSemantics(find.byType(FaceIdGlyph)).label, isEmpty);
    handle.dispose();
  });

  test('T20 shouldRepaint only on a colour or size change', () {
    final a = FaceIdPainter(AppColors.ink, 24);
    expect(a.shouldRepaint(FaceIdPainter(AppColors.ink, 24)), isFalse);
    expect(a.shouldRepaint(FaceIdPainter(Colors.white, 24)), isTrue);
    expect(a.shouldRepaint(FaceIdPainter(AppColors.ink, 56)), isTrue);
  });

  test('T20 (D3) stroke floor 2.0, then 0.04 x size; smile control at (0.50, 0.76)', () {
    expect(FaceIdPainter.strokeFor(24), 2.0);
    expect(FaceIdPainter.strokeFor(56), closeTo(2.24, 1e-9));
    expect(FaceIdPainter.strokeFor(64), closeTo(2.56, 1e-9));
    expect(FaceIdPainter.smileControl, const Offset(0.50, 0.76));
  });
}

