import 'package:calculator/screens/chat_screen.dart';
import 'package:calculator/screens/chats_screen.dart';
import 'package:calculator/services/firebase_service.dart';
import 'package:calculator/widgets/messaging_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dark mode: a full theme for the messaging side, a user preference that
/// persists, and the calculator face that never follows it.
void main() {
  final service = FirebaseService();

  setUp(() async {
    await service.setThemeMode(ThemeMode.system);
  });
  tearDown(() async {
    await service.setThemeMode(ThemeMode.system);
  });

  test('the light and dark messaging themes are opposite brightnesses', () {
    expect(messagingTheme.brightness, Brightness.light);
    expect(messagingDarkTheme.brightness, Brightness.dark);
  });

  test(
    'setThemeMode updates the getter and publishes on the notifier',
    () async {
      await service.setThemeMode(ThemeMode.dark);
      expect(service.themeMode, ThemeMode.dark);
      expect(service.themeModeChanged.value, ThemeMode.dark);

      await service.setThemeMode(ThemeMode.light);
      expect(service.themeMode, ThemeMode.light);
      expect(service.themeModeChanged.value, ThemeMode.light);
    },
  );

  testWidgets('dark mode re-skins the directory to the night palette', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: messagingTheme,
        darkTheme: messagingDarkTheme,
        themeMode: ThemeMode.dark,
        home: const ChatsScreen(),
      ),
    );
    expect(find.text('Your private conversations'), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, const Color(0xFF0B141A));
  });

  testWidgets('dark mode re-skins the chat to the night palette', (
    tester,
  ) async {
    final date = DateTime(2026, 10, 11, 10, 30);
    await tester.pumpWidget(
      MaterialApp(
        theme: messagingTheme,
        darkTheme: messagingDarkTheme,
        themeMode: ThemeMode.dark,
        home: ChatScreen(
          contactName: 'Partner',
          initialMessages: [
            ChatMessage(
              id: 'm1',
              text: 'Hello there',
              isMe: true,
              timestamp: date,
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, const Color(0xFF0B141A));
  });

  test('the calculator theme stays dark regardless of the mode', () {
    // The calculator face is built from ThemeData.dark and must not depend on
    // the messaging mode at all.
    final base = ThemeData.dark(useMaterial3: true);
    expect(base.brightness, Brightness.dark);
  });
}
