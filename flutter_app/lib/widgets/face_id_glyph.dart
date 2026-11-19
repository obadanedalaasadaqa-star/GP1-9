import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The Face ID glyph (four corner brackets, two eyes, the "J" nose and a
/// smile), drawn from `GP2/phase-11/faceid-glyph-reference.jpg`. Sizes 24
/// (buttons), 56 (offer sheet) and 64 (lock overlay). The colour always comes
/// from the caller. Decorative: the button or title next to it says Face ID.
class FaceIdGlyph extends StatelessWidget {
  final double size;
  final Color color;
  const FaceIdGlyph({super.key, this.size = 24, required this.color});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox.square(
          dimension: size,
          child: CustomPaint(painter: FaceIdPainter(color, size)),
        ),
      );
}

/// Paints [FaceIdGlyph]. All geometry is a fraction of the size, measured to
/// the centre of the stroke (design 0.2).
@visibleForTesting
class FaceIdPainter extends CustomPainter {
  final Color color;
  final double size;
  FaceIdPainter(this.color, this.size);

  /// `max(2.0, 0.04 × size)`: the house 2px line at small sizes, the
  /// reference proportion above 50pt (design 0.3).
  static double strokeFor(double size) => math.max(2.0, size * 0.04);

  /// The smile's control point. A quadratic only goes halfway to it, so 0.76
  /// puts the bottom of the smile at 0.72, as in the reference.
  static const smileControl = Offset(0.50, 0.76);

  @override
  void paint(Canvas canvas, Size _) {
    final s = size;
    Offset p(double x, double y) => Offset(x * s, y * s);
    final corner = Radius.circular(0.10 * s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeFor(s)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    // One path per bracket (line, arc, line), so the corner joins smoothly.
    Path bracket(Offset a, Offset b, Offset c, Offset d) => Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(b.dx, b.dy)
      ..arcToPoint(c, radius: corner, clockwise: true)
      ..lineTo(d.dx, d.dy);

    canvas
      ..drawPath(bracket(p(0.10, 0.30), p(0.10, 0.20), p(0.20, 0.10), p(0.30, 0.10)), paint)
      ..drawPath(bracket(p(0.70, 0.10), p(0.80, 0.10), p(0.90, 0.20), p(0.90, 0.30)), paint)
      ..drawPath(bracket(p(0.90, 0.68), p(0.90, 0.80), p(0.80, 0.90), p(0.70, 0.90)), paint)
      ..drawPath(bracket(p(0.30, 0.90), p(0.20, 0.90), p(0.10, 0.80), p(0.10, 0.68)), paint)
      // Eyes
      ..drawLine(p(0.32, 0.38), p(0.32, 0.44), paint)
      ..drawLine(p(0.68, 0.38), p(0.68, 0.44), paint);

    // Nose: down, a small turn down and left, then a short foot.
    final nose = Path()
      ..moveTo(0.52 * s, 0.38 * s)
      ..lineTo(0.52 * s, 0.54 * s)
      ..arcToPoint(p(0.48, 0.58), radius: Radius.circular(0.04 * s), clockwise: true)
      ..lineTo(0.46 * s, 0.58 * s);
    canvas.drawPath(nose, paint);

    final smile = Path()
      ..moveTo(0.38 * s, 0.68 * s)
      ..quadraticBezierTo(smileControl.dx * s, smileControl.dy * s, 0.62 * s, 0.68 * s);
    canvas.drawPath(smile, paint);
  }

  @override
  bool shouldRepaint(FaceIdPainter old) => old.color != color || old.size != size;
}
