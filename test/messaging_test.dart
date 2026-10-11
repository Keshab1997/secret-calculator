import 'package:calculator/screens/chat_screen.dart';
import 'package:calculator/screens/chats_screen.dart';
import 'package:calculator/widgets/messaging_style.dart';
import 'package:calculator/widgets/sticker_keyboard.dart';
import 'package:calculator/widgets/sticker_art.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('directory has Chats, Calls, You and no unsupported features', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: messagingTheme, home: const ChatsScreen()),
    );
    expect(find.text('Your private conversations'), findsOneWidget);
    expect(find.byTooltip('Pair new contact'), findsOneWidget);
    await tester.tap(find.text('Calls'));
    await tester.pumpAndSettle();
    expect(find.text('No calls yet'), findsOneWidget);
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();
    expect(find.text('Save profile'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
    for (final excluded in ['Meta AI', 'Updates', 'Payments']) {
      expect(find.text(excluded), findsNothing);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'chat theme picker offers romantic palettes in light and dark mode',
    (tester) async {
      Future<void> chooseTheme(String themeName) async {
        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Chat Theme'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(themeName));
        await tester.pumpAndSettle();
      }

      expect(
        ChatThemePalette.darkPresets,
        hasLength(ChatThemePalette.presets.length),
      );

      await tester.pumpWidget(
        MaterialApp(theme: messagingTheme, home: const ChatScreen()),
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chat Theme'));
      await tester.pumpAndSettle();
      for (final name in ['Rose Garden', 'Love Letter', 'Lavender Bloom']) {
        expect(find.text(name), findsOneWidget);
      }
      await tester.tap(find.text('Love Letter'));
      await tester.pumpAndSettle();
      var scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(
        scaffold.backgroundColor,
        ChatThemePalette.presets[2].backgroundColor,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: messagingTheme,
          darkTheme: messagingDarkTheme,
          themeMode: ThemeMode.dark,
          home: const ChatScreen(),
        ),
      );
      await tester.pump();
      await chooseTheme('Lavender Bloom');
      scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(
        scaffold.backgroundColor,
        ChatThemePalette.darkPresets[3].backgroundColor,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('sticker search returns matching artwork and an empty state', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: messagingTheme,
        home: Scaffold(
          body: StickerKeyboard(onStickerSelected: (value) => selected = value),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'love');
    await tester.pumpAndSettle();
    expect(find.byType(StickerArt), findsWidgets);
    await tester.tap(find.byType(StickerArt).first);
    expect(selected, isNotNull);
    await tester.enterText(find.byType(TextField), 'no-such-sticker');
    await tester.pumpAndSettle();
    expect(
      find.text('No stickers found. Try love, happy or heart.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'narrow chat renders messages, real call results, sticker panel and back handling',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/shared_preferences'),
        (_) async => <String, Object>{},
      );
      final date = DateTime(2026, 10, 11, 10, 30);
      await tester.pumpWidget(
        MaterialApp(
          theme: messagingTheme,
          home: ChatScreen(
            contactName: 'A very long contact display name',
            initialMessages: [
              ChatMessage(
                id: 'text',
                text: 'Hello there',
                isMe: true,
                timestamp: date,
              ),
              ChatMessage(
                id: 'sticker',
                text: 'sticker:v1:💕',
                isMe: false,
                timestamp: date,
              ),
              ChatMessage(
                id: 'call',
                callType: 'video',
                isMe: false,
                timestamp: date,
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Hello there'), findsOneWidget);
      expect(find.text('Missed Video call'), findsOneWidget);
      expect(find.byType(StickerArt), findsOneWidget);
      await tester.tap(find.byTooltip('Emoji keyboard'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stickers'));
      await tester.pumpAndSettle();
      expect(find.byType(StickerKeyboard), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(StickerKeyboard), findsNothing);
      expect(find.byType(ChatScreen), findsOneWidget);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Quick Hide to Calculator'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
