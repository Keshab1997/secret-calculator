import 'package:calculator/models/romantic_message_effect.dart';
import 'package:calculator/widgets/romantic_effect_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('romanticEffectForMessage', () {
    test('recognizes English, Bengali and Banglish love messages', () {
      for (final message in [
        'I love you',
        'Love you so much!',
        '“I love you!”',
        'ভালোবাসি',
        'ভালোবাসি।',
        'আমি তোমাকে ভালোবাসি',
        'bhalobashi',
        'bhalo bashi',
        'valobashi',
        'Ami tomake bhalobashi',
        'ami tomay valobashi',
        '❤️',
      ]) {
        expect(
          romanticEffectForMessage(message),
          RomanticMessageEffect.love,
          reason: 'Should recognize "$message"',
        );
      }
    });

    test('recognizes kisses and avoids negatives and sticker payloads', () {
      for (final message in [
        'kiss',
        'Kiss me 😘',
        'chumu dao',
        'চুমু দাও',
        '💋',
      ]) {
        expect(
          romanticEffectForMessage(message),
          RomanticMessageEffect.kiss,
          reason: 'Should recognize "$message"',
        );
      }

      for (final message in [
        "don't kiss",
        'I don’t love you',
        'bhalobashi na',
        'bhalo bashi na',
        'ভালোবাসি না',
        'sticker:v1:😘',
        'sticker:v1:❤️',
        '',
      ]) {
        expect(
          romanticEffectForMessage(message),
          isNull,
          reason: 'Should not play an effect for "$message"',
        );
      }
    });
  });

  testWidgets('love effect animates heart confetti and finishes', (
    tester,
  ) async {
    var finished = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RomanticEffectOverlay(
            effect: RomanticMessageEffect.love,
            onFinished: () => finished = true,
          ),
        ),
      ),
    );

    expect(find.text('💖'), findsWidgets);
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('kiss overlay is brief and does not block chat interaction', (
    tester,
  ) async {
    var tapped = false;
    var finished = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => tapped = true,
                child: const SizedBox.expand(),
              ),
              RomanticEffectOverlay(
                effect: RomanticMessageEffect.kiss,
                onFinished: () => finished = true,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('😘'), findsOneWidget);
    await tester.tapAt(const Offset(12, 12));
    expect(tapped, isTrue);
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(tester.takeException(), isNull);
  });
}
