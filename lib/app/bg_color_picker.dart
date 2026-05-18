import 'package:flutter/material.dart';

// Swatches shown in both AnimationPage and GifExportSheet.
// [sceneBgColor] is the computed average from the image — shown as first swatch.
class BgColorPicker extends StatelessWidget {
  final Color? selected;
  final Color? sceneBgColor;
  final ValueChanged<Color?> onChanged;

  const BgColorPicker({
    super.key,
    required this.selected,
    required this.onChanged,
    this.sceneBgColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final swatches = <(String, Color?)>[
      if (sceneBgColor != null) ('Scene', sceneBgColor),
      ('White', const Color(0xFFFFFFFF)),
      ('Black', const Color(0xFF000000)),
      ('Green', const Color(0xFF00B140)),
      ('Grey', const Color(0xFFC6C6C8)),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: swatches.map((entry) {
        final (label, color) = entry;
        final isSelected = color == selected;
        return GestureDetector(
          onTap: () => onChanged(color),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected ? cs.primary : cs.outline.withValues(alpha: 0.4),
                width: isSelected ? 2 : 1,
              ),
              color: isSelected ? cs.primaryContainer : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ColorDot(color: color),
                const SizedBox(width: 6),
                Text(label, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _ColorDot extends StatelessWidget {
  final Color? color;
  const _ColorDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: CustomPaint(painter: _DotPainter(color)),
    );
  }
}

class _DotPainter extends CustomPainter {
  final Color? color;
  _DotPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(0, 0, size.width, size.height);
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(4));
    if (color == null) {
      final paint = Paint();
      final half = size.width / 2;
      paint.color = const Color(0xFFCCCCCC);
      canvas.drawRRect(rr, paint);
      paint.color = const Color(0xFFFFFFFF);
      canvas.drawRect(Rect.fromLTWH(0, 0, half, half), paint);
      canvas.drawRect(Rect.fromLTWH(half, half, half, half), paint);
      canvas.clipRRect(rr);
    } else {
      canvas.drawRRect(rr, Paint()..color = color!);
      if (color!.a > 0.98 && color!.r > 0.95 && color!.g > 0.95 && color!.b > 0.95) {
        canvas.drawRRect(
          rr,
          Paint()
            ..color = const Color(0xFFCCCCCC)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.color != color;
}
