import 'package:flutter/material.dart';

import '../services/media_cache_service.dart';

const chatGreen = Color(0xFF1DAA61);
const chatInk = Color(0xFF172126);

/// The app's type family. Bundled (see pubspec.yaml) so it is identical on
/// every device and available on the first frame; every ThemeData in the app
/// spreads this name so the calculator and the hidden side share one voice.
const appFontFamily = 'Inter';

/// One type scale for the whole messaging side — headers, list rows, message
/// bodies, captions. Every screen reads from it instead of inventing sizes,
/// which is what makes the app feel deliberate rather than assembled.
const messagingTextTheme = TextTheme(
  headlineSmall: TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.4,
  ),
  titleLarge: TextStyle(
    fontSize: 17.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  ),
  titleMedium: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
  bodyLarge: TextStyle(fontSize: 16, height: 1.28),
  bodyMedium: TextStyle(fontSize: 15, height: 1.3),
  bodySmall: TextStyle(fontSize: 13, height: 1.25),
  labelLarge: TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
  ),
  labelMedium: TextStyle(fontSize: 12.5),
  labelSmall: TextStyle(fontSize: 11, letterSpacing: 0.2),
);

final messagingTheme = ThemeData(
  useMaterial3: true,
  fontFamily: appFontFamily,
  colorScheme: ColorScheme.fromSeed(
    seedColor: chatGreen,
    brightness: Brightness.light,
  ),
  textTheme: messagingTextTheme.apply(fontFamily: appFontFamily),
  scaffoldBackgroundColor: Colors.white,
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.white,
    foregroundColor: chatInk,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0.5,
  ),
);

/// A messaging route: fade through with a small rise instead of the platform
/// push. The default push swings the whole page sideways, which reads as
/// abrupt next to the rest of this side of the app — here the page settles
/// into place.
PageRoute<T> messagingRoute<T>(Widget child) => PageRouteBuilder<T>(
  transitionDuration: const Duration(milliseconds: 240),
  reverseTransitionDuration: const Duration(milliseconds: 200),
  pageBuilder: (_, _, _) => Theme(data: messagingTheme, child: child),
  transitionsBuilder: (_, animation, _, child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.025),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  },
);

/// Formats a call duration as `m:ss` (0:00 … 12:34).
String formatCallDuration(int totalSeconds) {
  final safe = totalSeconds < 0 ? 0 : totalSeconds;
  final minutes = safe ~/ 60;
  final seconds = safe % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// WhatsApp-style call log text for one call entry, resolved per viewer.
///
/// [callOutcome] is 'completed', 'missed' (nobody accepted — ring timeout,
/// offline callee, or the caller cancelled) or 'declined' (the callee
/// rejected). Entries from older clients predate the field: there a null
/// [callSeconds] meant the call never connected.
({String title, String detail}) callLogText({
  required String? callType,
  required int? callSeconds,
  required String? callOutcome,
  required bool isMe,
}) {
  final kind = callType == 'video' ? 'Video' : 'Voice';
  final outcome = callOutcome ?? (callSeconds == null ? 'missed' : 'completed');
  switch (outcome) {
    case 'declined':
      return (title: 'Declined $kind call', detail: 'Tap to call back');
    case 'missed':
      return isMe
          ? (title: '$kind call', detail: 'No answer')
          : (title: 'Missed $kind call', detail: 'Tap to call back');
    case 'completed':
    default:
      return (
        title: '$kind call',
        detail: callSeconds == null ? '' : formatCallDuration(callSeconds),
      );
  }
}

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
