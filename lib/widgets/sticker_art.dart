import 'package:flutter/material.dart';

/// A small, original offline sticker pack. No third-party sticker URLs or keys.
class StickerArt extends StatelessWidget {
  final String emoji;
  final double size;
  const StickerArt({super.key, required this.emoji, this.size = 100});
  @override
  Widget build(BuildContext context) {
    const love = [
      '❤️',
      '💖',
      '😍',
      '💋',
      '💕',
      '💝',
      '💞',
      '💘',
      '🥰',
      '😘',
      '🤗',
      '🌹',
      '💐',
      '🧸',
      '🫂',
      '💑',
      '💏',
    ];
    if (!love.contains(emoji)) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Text(emoji, style: TextStyle(fontSize: size * .65)),
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _LoveSticker(emoji)),
    );
  }
}

class _LoveSticker extends CustomPainter {
  final String emoji;
  _LoveSticker(this.emoji);
  void _heart(Canvas canvas, Offset center, double scale, Color color) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(scale);
    final path = Path()
      ..moveTo(0, 10)
      ..cubicTo(-28, -7, -12, -28, 0, -13)
      ..cubicTo(12, -28, 28, -7, 0, 10);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6,
    );
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  void _bear(Canvas c, Offset at, Color fur, bool closedEyes) {
    c.save();
    c.translate(at.dx, at.dy);
    final line = Paint()
      ..color = const Color(0xFF73544A)
      ..strokeWidth = 1.7
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = fur;
    for (final dx in [-15.0, 15.0]) {
      c.drawCircle(Offset(dx, -13), 8, Paint()..color = Colors.white);
      c.drawCircle(Offset(dx, -13), 6, fill);
      c.drawCircle(Offset(dx, -13), 6, line);
    }
    final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(-17, 9, 34, 39),
      const Radius.circular(16),
    );
    c.drawRRect(
      body,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5,
    );
    c.drawRRect(body, fill);
    c.drawRRect(body, line);
    final head = RRect.fromRectAndRadius(
      const Rect.fromLTWH(-23, -18, 46, 40),
      const Radius.circular(20),
    );
    c.drawRRect(
      head,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5,
    );
    c.drawRRect(head, fill);
    c.drawRRect(head, line);
    for (final dx in [-9.0, 9.0]) {
      if (closedEyes) {
        c.drawArc(
          Rect.fromCenter(center: Offset(dx, 1), width: 7, height: 6),
          0,
          3.14,
          false,
          line,
        );
      } else {
        c.drawOval(
          Rect.fromCenter(center: Offset(dx, 0), width: 3, height: 5),
          Paint()..color = line.color,
        );
      }
      c.drawOval(
        Rect.fromCenter(center: Offset(dx * 1.5, 8), width: 9, height: 5),
        Paint()..color = const Color(0xFFF6B0AF),
      );
    }
    c.drawCircle(const Offset(0, 5), 2, Paint()..color = line.color);
    c.drawPath(
      Path()
        ..moveTo(0, 7)
        ..quadraticBezierTo(-2, 12, -6, 8)
        ..moveTo(0, 7)
        ..quadraticBezierTo(2, 12, 6, 8),
      line,
    );
    c.drawLine(const Offset(-12, 28), const Offset(6, 32), line);
    c.restore();
  }

  void _rose(Canvas canvas, Offset at, double scale, Color petals) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.scale(scale);

    final stem = Paint()
      ..color = const Color(0xFF4E9A68)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(0, 12), const Offset(1, 52), stem);

    final leaves = Paint()..color = const Color(0xFF5EAD72);
    canvas.drawPath(
      Path()
        ..moveTo(0, 33)
        ..quadraticBezierTo(-20, 17, -21, 9)
        ..quadraticBezierTo(-5, 11, 0, 33)
        ..close(),
      leaves,
    );
    canvas.drawPath(
      Path()
        ..moveTo(1, 43)
        ..quadraticBezierTo(19, 28, 21, 21)
        ..quadraticBezierTo(6, 23, 1, 43)
        ..close(),
      leaves,
    );

    final shadowPetal = Paint()..color = petals.withValues(alpha: 0.55);
    final petal = Paint()..color = petals;
    canvas.drawCircle(const Offset(0, 0), 17, shadowPetal);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(-8, -3), width: 17, height: 19),
      petal,
    );
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(8, -3), width: 17, height: 19),
      petal,
    );
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(0, -9), width: 17, height: 18),
      petal,
    );
    canvas.drawCircle(
      const Offset(0, -2),
      7,
      Paint()..color = const Color(0xFFB92E58),
    );
    canvas.drawCircle(
      const Offset(-2, -5),
      2,
      Paint()..color = const Color(0xFFFFD166),
    );
    canvas.restore();
  }

  void _bouquet(Canvas canvas) {
    _rose(canvas, const Offset(34, 37), 0.64, const Color(0xFFE85D78));
    _rose(canvas, const Offset(50, 27), 0.72, const Color(0xFFCC3E67));
    _rose(canvas, const Offset(66, 37), 0.64, const Color(0xFFFF8295));

    final wrap = Path()
      ..moveTo(31, 61)
      ..lineTo(69, 61)
      ..lineTo(61, 91)
      ..lineTo(39, 91)
      ..close();
    canvas.drawPath(wrap, Paint()..color = const Color(0xFFFFE6EB));
    canvas.drawPath(
      wrap,
      Paint()
        ..color = const Color(0xFFE0A4B3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );
    canvas.drawPath(
      Path()
        ..moveTo(50, 64)
        ..cubicTo(40, 58, 37, 68, 49, 71)
        ..moveTo(50, 64)
        ..cubicTo(60, 58, 63, 68, 51, 71),
      Paint()
        ..color = const Color(0xFFC94F70)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    if (emoji == '🌹') {
      _rose(canvas, const Offset(50, 31), 0.95, const Color(0xFFE5486D));
      _heart(canvas, const Offset(81, 20), .42, const Color(0xFFFFB0C1));
    } else if (emoji == '💐') {
      _bouquet(canvas);
    } else if (emoji == '🧸') {
      _bear(canvas, const Offset(50, 39), const Color(0xFFD6B18D), false);
      _heart(canvas, const Offset(50, 70), .48, const Color(0xFFEF4469));
    } else if (emoji == '❤️' || emoji == '💖' || emoji == '💝') {
      _heart(canvas, const Offset(50, 59), 2.1, const Color(0xFFEF4469));
      canvas.drawOval(
        const Rect.fromLTWH(22, 29, 9, 15),
        Paint()..color = Colors.white.withValues(alpha: .65),
      );
      if (emoji != '❤️') {
        _heart(canvas, const Offset(79, 24), .5, const Color(0xFFFFB849));
      }
    } else {
      final pair = ['💕', '💞', '💋', '🤗', '🫂', '💑', '💏'].contains(emoji);
      if (pair) {
        _bear(canvas, const Offset(34, 44), const Color(0xFFD6B18D), true);
        _bear(canvas, const Offset(65, 47), const Color(0xFFFFF6EE), true);
        _heart(canvas, const Offset(53, 18), .6, const Color(0xFFEF4469));
      } else {
        _bear(
          canvas,
          const Offset(50, 39),
          const Color(0xFFFFF6EE),
          emoji != '😍',
        );
        _heart(canvas, const Offset(51, 75), .9, const Color(0xFFEF4469));
        _heart(canvas, const Offset(82, 28), .5, const Color(0xFFEF4469));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LoveSticker oldDelegate) =>
      emoji != oldDelegate.emoji;
}
