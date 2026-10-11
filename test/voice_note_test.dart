import 'package:calculator/screens/chat_screen.dart';
import 'package:calculator/services/native_bridge_service.dart';
import 'package:calculator/widgets/messaging_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A voice note plays like WhatsApp's: a waveform, a live clock, and the
/// played portion of the bars filling as the note runs.
void main() {
  testWidgets('voice note shows waveform, plays with progress, stops on tap', (
    tester,
  ) async {
    // The native side decrypts and plays the file; the test short-circuits
    // that so the play/stop/progress UI is what is actually being verified.
    final bridge = NativeBridgeService();
    bridge.playEncryptedAudioForTesting = (payload, encryption) async => true;
    addTearDown(() => bridge.playEncryptedAudioForTesting = null);

    // stopAudio still goes over the real channel; answer it so the
    // tap-to-stop path can complete.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.keshabstudios.calculator/native'),
      (call) async => null,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: messagingTheme,
        home: ChatScreen(
          initialMessages: [
            ChatMessage(
              id: 'note-1',
              encryptedAudioData: 'iv:ciphertext',
              audioDurationSeconds: 2,
              isMe: true,
              timestamp: DateTime(2026, 10, 11, 12),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    // Idle: the total duration and a play button.
    expect(find.text('0:02'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    // Tapping plays: pause icon, and the clock switches to elapsed/total.
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    expect(find.byIcon(Icons.pause), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('/ 0:02'), findsOneWidget);

    // Letting the note run to the end fills the clock to the total.
    await tester.pump(const Duration(milliseconds: 2500));
    expect(find.text('0:02 / 0:02'), findsOneWidget);

    // Tapping again stops it and the label falls back to the total.
    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.text('0:02'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
