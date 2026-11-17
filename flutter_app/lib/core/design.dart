import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'constants.dart';

/// Colours for the current mode (paper or ink). Screens read this instead of
/// picking `isDark ? a : b` for every colour.
class Nx {
  final bool dark;
  const Nx._(this.dark);

  /// From the app theme, which follows ThemeProvider.
  static Nx of(BuildContext context) =>
      Nx._(Theme.of(context).brightness == Brightness.dark);

  Color get bg    => dark ? AppColors.ink : AppColors.paper;
  Color get sheet => dark ? AppColors.surface : AppColors.paper;
  /// Cards and receipt rows.
  Color get card  => dark ? AppColors.raised : Colors.white;
  Color get text  => dark ? Colors.white : AppColors.ink;
  Color get muted => dark ? AppColors.textMuted : AppColors.textMutedLight;
  /// Outlines and hard shadows: ink on paper, white-ish on ink.
  Color get line  => dark ? AppColors.textMuted : AppColors.ink;
  Color get hairline => dark ? AppColors.border : AppColors.borderLight;
  /// Accent used as text or icon on [bg] (links, active states).
  Color get accent => dark ? AppColors.lime : AppColors.cobalt;
  /// Hard shadow under tilted cards.
  Color get shadow => dark ? AppColors.lime : AppColors.ink;
  /// Primary button fill and its text.
  Color get buttonFill => dark ? AppColors.lime : AppColors.ink;
  Color get onButton   => dark ? AppColors.ink : Colors.white;
  Color get danger => dark ? AppColors.coral : AppColors.danger;
}

/// The three type roles: Bricolage Grotesque for headings and amounts,
/// Instrument Sans for text, DM Mono for receipt-style labels and figures.
class NxType {
  static TextStyle display(double size,
          {Color? color, FontWeight weight = FontWeight.w800,
           double? letterSpacing, double? height}) =>
      GoogleFonts.bricolageGrotesque(
        fontSize: size, fontWeight: weight, color: color, height: height,
        letterSpacing: letterSpacing ?? -size * 0.035);

  static TextStyle body(double size,
          {Color? color, FontWeight weight = FontWeight.w500, double? height}) =>
      GoogleFonts.instrumentSans(
        fontSize: size, fontWeight: weight, color: color, height: height);

  static TextStyle mono(double size,
          {Color? color, FontWeight weight = FontWeight.w400,
           double letterSpacing = 0}) =>
      GoogleFonts.dmMono(
        fontSize: size, fontWeight: weight, color: color,
        letterSpacing: letterSpacing);

  /// Small spaced mono label, like the header line on a till slip.
  static TextStyle label(Color color) =>
      mono(11, color: color, letterSpacing: 1.5);
}

// ── Receipt edge ────────────────────────────────────────────────────────────

/// A torn-paper zigzag strip. Put it under (or over, with [up]) a block of
/// the same [color] to make it look like a receipt.
class ReceiptEdge extends StatelessWidget {
  final Color color;
  final bool up;
  final double height;
  const ReceiptEdge({super.key, required this.color,
      this.up = false, this.height = 8});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height, width: double.infinity,
        child: CustomPaint(painter: _ZigzagPainter(color, up)));
}

class _ZigzagPainter extends CustomPainter {
  final Color color;
  final bool up;
  _ZigzagPainter(this.color, this.up);

  @override
  void paint(Canvas canvas, Size size) {
    final tooth = size.height * 2;
    final path = Path();
    if (up) {
      path.moveTo(0, size.height);
      for (double x = 0; x < size.width; x += tooth) {
        path.lineTo(math.min(x + tooth / 2, size.width), 0);
        path.lineTo(math.min(x + tooth, size.width), size.height);
      }
    } else {
      path.moveTo(0, 0);
      for (double x = 0; x < size.width; x += tooth) {
        path.lineTo(math.min(x + tooth / 2, size.width), size.height);
        path.lineTo(math.min(x + tooth, size.width), 0);
      }
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ZigzagPainter old) => old.color != color || old.up != up;
}

/// A dashed horizontal rule, like the cut line on a till slip.
class DashedRule extends StatelessWidget {
  final Color color;
  final double thickness;
  final double dash;
  final double gap;
  const DashedRule({super.key, required this.color,
      this.thickness = 2, this.dash = 6, this.gap = 4});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: thickness, width: double.infinity,
        child: CustomPaint(painter: _DashPainter(color, dash, gap)));
}

class _DashPainter extends CustomPainter {
  final Color color;
  final double dash, gap;
  _DashPainter(this.color, this.dash, this.gap);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (double x = 0; x < size.width; x += dash + gap) {
      canvas.drawRect(
          Rect.fromLTWH(x, 0, math.min(dash, size.width - x), size.height), p);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}

// ── Cards ───────────────────────────────────────────────────────────────────

/// Outlined card with a hard offset shadow, optionally tilted.
class NxCard extends StatelessWidget {
  final Widget child;
  final Color? color;
  final Color? borderColor;
  final Color? shadowColor;
  final double radius;
  final double tilt;       // degrees
  final double shadow;     // offset in px, 0 for none
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  const NxCard({super.key, required this.child, this.color, this.borderColor,
      this.shadowColor, this.radius = 18, this.tilt = 0, this.shadow = 5,
      this.padding = const EdgeInsets.all(16), this.onTap});

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? (nx.dark ? AppColors.surface : Colors.white),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? nx.line, width: 2),
        boxShadow: shadow == 0 ? null : [
          BoxShadow(color: shadowColor ?? nx.shadow,
              offset: Offset(shadow, shadow)),
        ],
      ),
      child: child,
    );
    final tilted = tilt == 0
        ? box
        : Transform.rotate(angle: tilt * math.pi / 180, child: box);
    return onTap == null ? tilted : Pressable(onTap: onTap, child: tilted);
  }
}

/// A receipt-shaped row: rounded top, zigzag bottom, slight drop shadow.
class ReceiptTile extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  const ReceiptTile({super.key, required this.child, this.onTap,
      this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12)});

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final tile = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: padding,
          decoration: BoxDecoration(
            color: nx.card,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
          ),
          child: child,
        ),
        ReceiptEdge(color: nx.card),
      ],
    );
    return onTap == null ? tile : Pressable(onTap: onTap, child: tile);
  }
}

/// Rounded-square category icon, slightly turned like a sticker.
class NxIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  final double tilt;
  const NxIconTile({super.key, required this.icon, required this.color,
      this.size = 42, this.tilt = -4});

  @override
  Widget build(BuildContext context) {
    final onColor = color == AppColors.cobalt || color == AppColors.lavender
        ? Colors.white : AppColors.ink;
    return Transform.rotate(
      angle: tilt * math.pi / 180,
      child: Container(
        width: size, height: size,
        decoration: BoxDecoration(
          color: color, borderRadius: BorderRadius.circular(size * 0.29)),
        child: Icon(icon, color: onColor, size: size * 0.52),
      ),
    );
  }
}

/// Icon for a receipt category.
IconData categoryIcon(String category) {
  switch (category) {
    case 'Supermarket': return Icons.shopping_basket_outlined;
    case 'Food':        return Icons.local_cafe_outlined;
    case 'Pharmacy':    return Icons.medical_services_outlined;
    case 'Clothing':    return Icons.checkroom_outlined;
    case 'Electronics': return Icons.devices_other_outlined;
    default:            return Icons.receipt_long_outlined;
  }
}

/// A round rubber stamp: dashed ring, big figure, small mono caption.
class NxStamp extends StatelessWidget {
  final String value;
  final String caption;
  final Color color;
  final double size;
  final double tilt;
  final Color? fill;
  const NxStamp({super.key, required this.value, required this.caption,
      required this.color, this.size = 64, this.tilt = 14, this.fill});

  @override
  Widget build(BuildContext context) => Transform.rotate(
        angle: tilt * math.pi / 180,
        child: Container(
          width: size, height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: fill,
          ),
          child: CustomPaint(
            painter: fill == null ? _DashedCircle(color) : null,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(value, style: NxType.display(size * 0.31,
                      color: color, height: 1)),
                  Text(caption, textAlign: TextAlign.center,
                      style: NxType.mono(size * 0.13, color: color,
                          weight: FontWeight.w500, letterSpacing: 0.5)),
                ],
              ),
            ),
          ),
        ),
      );
}

class _DashedCircle extends CustomPainter {
  final Color color;
  _DashedCircle(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2 - 1.5;
    final c = size.center(Offset.zero);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    const n = 22;
    for (var i = 0; i < n; i++) {
      final a = i * 2 * math.pi / n;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), a,
          math.pi / n, false, p);
    }
  }

  @override
  bool shouldRepaint(_DashedCircle old) => old.color != color;
}

// ── Buttons ─────────────────────────────────────────────────────────────────

/// Sinks and shrinks slightly while pressed, so every tap shows a response.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const Pressable({super.key, required this.child, this.onTap});
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  void _set(bool v) {
    if (widget.onTap != null && _down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => _set(true),
        onTapUp: (_) => _set(false),
        onTapCancel: () => _set(false),
        child: AnimatedScale(
          scale: _down ? 0.975 : 1,
          duration: const Duration(milliseconds: 90),
          child: AnimatedSlide(
            offset: _down ? const Offset(0, 0.02) : Offset.zero,
            duration: const Duration(milliseconds: 90),
            child: widget.child,
          ),
        ),
      );
}

/// Pill button styles used across the app.
class NxButtonStyle {
  /// Solid pill: ink on paper, lime on ink (or any [fill]).
  static ButtonStyle solid(Nx nx, {Color? fill, Color? text,
          double height = 54}) =>
      ElevatedButton.styleFrom(
        backgroundColor: fill ?? nx.buttonFill,
        foregroundColor: text ?? nx.onButton,
        disabledBackgroundColor: (fill ?? nx.buttonFill).withValues(alpha: 0.4),
        disabledForegroundColor: (text ?? nx.onButton).withValues(alpha: 0.7),
        elevation: 0,
        shadowColor: Colors.transparent,
        minimumSize: Size(0, height),
        shape: const StadiumBorder(),
        textStyle: NxType.body(15, weight: FontWeight.w700),
      );

  /// Outlined pill.
  static ButtonStyle outline(Nx nx, {Color? color, double height = 54}) =>
      OutlinedButton.styleFrom(
        foregroundColor: color ?? nx.text,
        minimumSize: Size(0, height),
        side: BorderSide(color: color ?? nx.line, width: 2),
        shape: const StadiumBorder(),
        textStyle: NxType.body(15, weight: FontWeight.w700),
      );
}

/// Round ink back button with a white arrow, as in the designs.
class NxBackButton extends StatelessWidget {
  final VoidCallback? onTap;
  final String tooltip;
  final IconData icon;
  const NxBackButton({super.key, this.onTap, this.tooltip = 'Back',
      this.icon = Icons.arrow_back_rounded});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Pressable(
          onTap: onTap ?? () => Navigator.of(context).maybePop(),
          child: Container(
            width: 44, height: 44,
            decoration: const BoxDecoration(
                color: AppColors.ink, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      );
}

/// Small rounded chip; [filled] for the selected state.
class NxChip extends StatelessWidget {
  final String label;
  final bool filled;
  final Color? fill;
  final Color? textColor;
  final VoidCallback? onTap;
  final double height;
  const NxChip({super.key, required this.label, this.filled = false,
      this.fill, this.textColor, this.onTap, this.height = 40});

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final bgc = filled ? (fill ?? AppColors.ink) : nx.card;
    final fg = textColor ??
        (filled ? (bgc == AppColors.lime ? AppColors.ink : Colors.white)
                : nx.text);
    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bgc,
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(
            color: filled ? bgc : nx.line, width: 2),
      ),
      child: Text(label, style: NxType.body(14, color: fg,
          weight: FontWeight.w700)),
    );
    return onTap == null ? chip : Pressable(onTap: onTap, child: chip);
  }
}

/// Input decoration for text fields: white box, 2px ink outline.
InputDecoration nxInput(Nx nx, {String? hint, Widget? suffix, Widget? prefix,
    String? errorText, String? labelText}) {
  OutlineInputBorder b(Color c, [double w = 2]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: c, width: w));
  return InputDecoration(
    hintText: hint,
    labelText: labelText,
    errorText: errorText,
    suffixIcon: suffix,
    prefixIcon: prefix,
    filled: true,
    fillColor: nx.card,
    hintStyle: NxType.body(15, color: nx.muted, weight: FontWeight.w400),
    labelStyle: NxType.body(14, color: nx.muted),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    enabledBorder: b(nx.line),
    focusedBorder: b(nx.dark ? AppColors.lime : AppColors.cobalt, 2.5),
    errorBorder: b(nx.danger),
    focusedErrorBorder: b(nx.danger, 2.5),
    disabledBorder: b(nx.hairline),
    errorStyle: NxType.body(12, color: nx.danger),
  );
}

/// Bottom sheet frame: full width, rounded top, handle, safe-area padding.
class NxSheet extends StatelessWidget {
  final Widget child;
  final Color? color;
  const NxSheet({super.key, required this.child, this.color});

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
          22, 12, 22, 16 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: color ?? (nx.dark ? AppColors.surface : AppColors.paper),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: nx.line, width: 2)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44, height: 5,
            decoration: BoxDecoration(
              color: nx.line, borderRadius: BorderRadius.circular(3))),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

/// Settings card on Profile: white with an ink outline (paper), or the
/// dark surface (ink). No shadow; the member card above carries that.
class NxProfileCard extends StatelessWidget {
  final List<Widget> children;
  const NxProfileCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: nx.dark ? AppColors.surface : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: nx.dark ? null : Border.all(color: AppColors.ink, width: 2),
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}

/// Dotted divider between rows in a card.
class NxRowDivider extends StatelessWidget {
  const NxRowDivider({super.key});
  @override
  Widget build(BuildContext context) => DashedRule(
      color: Nx.of(context).dark ? AppColors.border : AppColors.dotted,
      thickness: 1.5, dash: 3, gap: 3);
}
