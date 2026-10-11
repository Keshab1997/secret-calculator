import 'package:flutter/material.dart';

import '../services/media_cache_service.dart';

const chatGreen = Color(0xFF1DAA61);
const chatInk = Color(0xFF172126);

/// Dark-mode counterparts of the chat ink, so surfaces can resolve one
/// logical colour against the active theme instead of guessing.
const chatInkDark = Color(0xFFE9EDEF);
const chatSubDark = Color(0xFF8696A0);

/// Semantic colours for the messaging surfaces, resolved against the active
/// theme. Every screen reads these instead of hard-coding white and grey,
/// which is what makes dark mode a flip, not a re-skin.
class MessagingPalette {
  const MessagingPalette._({
    required this.page,
    required this.card,
    required this.cardBorder,
    required this.ink,
    required this.sub,
    required this.fieldFill,
    required this.fieldBorder,
  });

  /// Page background (scaffold, list, sheets).
  final Color page;

  /// Raised card surface (profile cards, tiles).
  final Color card;
  final Color cardBorder;

  /// Primary text.
  final Color ink;

  /// Secondary text (captions, hints, timestamps).
  final Color sub;

  /// Text field fill + border.
  final Color fieldFill;
  final Color fieldBorder;

  static const MessagingPalette light = MessagingPalette._(
    page: Colors.white,
    card: Color(0xFFF7F8FA),
    cardBorder: Color(0xFFE7E9EE),
    ink: chatInk,
    sub: Color(0xFF8A919E),
    fieldFill: Colors.white,
    fieldBorder: Color(0xFFE7E9EE),
  );

  static const MessagingPalette dark = MessagingPalette._(
    page: Color(0xFF0B141A),
    card: Color(0xFF1F2C33),
    cardBorder: Color(0xFF2A3942),
    ink: chatInkDark,
    sub: chatSubDark,
    fieldFill: Color(0xFF111B21),
    fieldBorder: Color(0xFF2A3942),
  );

  static MessagingPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// True when the active theme is the dark one.
  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;
}

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
  // Dialogs and snack bars are part of the app's voice too: one rounded
  // shape and one floating style instead of the platform defaults.
  dialogTheme: DialogThemeData(
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    titleTextStyle: const TextStyle(
      fontFamily: appFontFamily,
      fontSize: 17.5,
      fontWeight: FontWeight.w600,
      color: chatInk,
    ),
    contentTextStyle: const TextStyle(
      fontFamily: appFontFamily,
      fontSize: 14.5,
      height: 1.35,
      color: Colors.black87,
    ),
  ),
  snackBarTheme: SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: const Color(0xFF1F2A30),
    contentTextStyle: const TextStyle(
      fontFamily: appFontFamily,
      fontSize: 14,
      color: Colors.white,
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
  ),
);

/// The dark variant of the messaging theme — WhatsApp's night palette:
/// near-black background, elevated surfaces, one green accent. The light and
/// dark themes share the type scale and the dialog/snackbar shape language,
/// so switching modes changes the mood, not the app.
final messagingDarkTheme = ThemeData(
  useMaterial3: true,
  fontFamily: appFontFamily,
  colorScheme: ColorScheme.fromSeed(
    seedColor: chatGreen,
    brightness: Brightness.dark,
  ).copyWith(surface: const Color(0xFF111B21)),
  textTheme: messagingTextTheme.apply(fontFamily: appFontFamily),
  scaffoldBackgroundColor: const Color(0xFF0B141A),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xFF111B21),
    foregroundColor: Color(0xFFE9EDEF),
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0.5,
  ),
  dialogTheme: DialogThemeData(
    backgroundColor: const Color(0xFF1F2C33),
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    titleTextStyle: const TextStyle(
      fontFamily: appFontFamily,
      fontSize: 17.5,
      fontWeight: FontWeight.w600,
      color: Color(0xFFE9EDEF),
    ),
    contentTextStyle: const TextStyle(
      fontFamily: appFontFamily,
      fontSize: 14.5,
      height: 1.35,
      color: Color(0xFFCFD6DC),
    ),
  ),
  snackBarTheme: SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor: Color(0xFF676E75),
    contentTextStyle: TextStyle(
      fontFamily: appFontFamily,
      fontSize: 14,
      color: Colors.white,
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    insetPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
  ),
);

/// A messaging route: fade through with a small rise instead of the platform
/// push. The default push swings the whole page sideways, which reads as
/// abrupt next to the rest of this side of the app — here the page settles
/// into place.
PageRoute<T> messagingRoute<T>(Widget child) => PageRouteBuilder<T>(
  transitionDuration: const Duration(milliseconds: 240),
  reverseTransitionDuration: const Duration(milliseconds: 200),
  // The app-level theme (light or dark, per the user's preference) cascades
  // through this route; forcing one here would pin the side to light.
  pageBuilder: (_, _, _) => child,
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

/// The call-row's trailing glyph: direction at a glance, and the one thing
/// that needs action — an incoming call that went unanswered — is the
/// loudest one in the list.
({IconData icon, Color color}) callRowIcon({
  required bool isMe,
  String? callOutcome,
}) {
  final outcome = callOutcome ?? 'missed';
  if (outcome == 'missed' && !isMe) {
    return (icon: Icons.call_missed_outlined, color: const Color(0xFFE5484D));
  }
  return (
    icon: isMe ? Icons.call_made_outlined : Icons.call_received_outlined,
    color: outcome == 'completed' ? chatGreen : const Color(0xFF8A97A0),
  );
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
  final Color line;

  const ChatWallpaper({this.line = const Color(0xFFE4DED2)});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = line
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
  bool shouldRepaint(covariant ChatWallpaper oldDelegate) =>
      line != oldDelegate.line;
}
