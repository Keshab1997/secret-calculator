import 'package:flutter/material.dart';

import '../services/media_cache_service.dart';

const chatGreen = Color(0xFF1DAA61);
const chatInk = Color(0xFF172126);
final messagingTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: chatGreen,
    brightness: Brightness.light,
  ),
  scaffoldBackgroundColor: Colors.white,
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.white,
    foregroundColor: chatInk,
    surfaceTintColor: Colors.transparent,
  ),
);

MaterialPageRoute<T> messagingRoute<T>(Widget child) => MaterialPageRoute<T>(
  builder: (_) => Theme(data: messagingTheme, child: child),
);

class ProfileAvatar extends StatelessWidget {
  final String? photo;
  final double radius;
  const ProfileAvatar({super.key, this.photo, this.radius = 25});
  @override
  Widget build(BuildContext context) {
    final image = MediaCacheService().avatarProvider(photo);
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFFCEEAF2),
      foregroundColor: const Color(0xFF0683A6),
      backgroundImage: image,
      onBackgroundImageError: image == null ? null : (_, _) {},
      child: image == null ? Icon(Icons.person, size: radius * 1.15) : null,
    );
  }
}

/// Original line-art wallpaper, drawn locally with no remote image requests.
class ChatWallpaper extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFE4DED2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (double y = -30; y < size.height + 90; y += 90) {
      for (double x = -20; x < size.width + 90; x += 90) {
        canvas.save();
        canvas.translate(x + ((y ~/ 90).isEven ? 0 : 35), y);
        canvas.rotate(0.18);
        final kind = ((x ~/ 90) + (y ~/ 90)).abs() % 3;
        if (kind == 0) {
          final heart = Path()
            ..moveTo(25, 40)
            ..cubicTo(-12, 15, 8, -4, 25, 12)
            ..cubicTo(42, -4, 62, 15, 25, 40);
          canvas.drawPath(heart, paint);
        } else if (kind == 1) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(0, 0, 43, 31),
              const Radius.circular(10),
            ),
            paint,
          );
          canvas.drawPath(
            Path()
              ..moveTo(10, 31)
              ..lineTo(7, 40)
              ..lineTo(23, 31),
            paint,
          );
          for (double dx = 11; dx < 35; dx += 10) {
            canvas.drawCircle(Offset(dx, 15), 1.5, paint);
          }
        } else {
          canvas.drawCircle(const Offset(23, 20), 21, paint);
          canvas.drawArc(
            const Rect.fromLTWH(12, 14, 22, 18),
            0.2,
            2.7,
            false,
            paint,
          );
          canvas.drawCircle(const Offset(16, 13), 1.5, paint);
          canvas.drawCircle(const Offset(30, 13), 1.5, paint);
        }
        canvas.drawCircle(const Offset(65, 60), 4, paint);
        canvas.drawLine(const Offset(13, 65), const Offset(21, 65), paint);
        canvas.drawLine(const Offset(17, 61), const Offset(17, 69), paint);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant ChatWallpaper oldDelegate) => false;
}
