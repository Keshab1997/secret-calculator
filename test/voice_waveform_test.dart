import 'package:calculator/screens/chat_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('voiceWaveformHeights', () {
    test('is deterministic for the same message id', () {
      expect(
        voiceWaveformHeights('note-1'),
        equals(voiceWaveformHeights('note-1')),
      );
    });

    test('differs between message ids', () {
      expect(
        voiceWaveformHeights('note-1'),
        isNot(equals(voiceWaveformHeights('note-2'))),
      );
    });

    test('heights stay inside the renderable band', () {
      final heights = voiceWaveformHeights('some-message-id', barCount: 24);
      expect(heights.length, 24);
      for (final value in heights) {
        expect(value, greaterThanOrEqualTo(0.25));
        expect(value, lessThanOrEqualTo(1.0));
      }
    });

    test('honours a custom bar count', () {
      expect(voiceWaveformHeights('x', barCount: 40).length, 40);
    });
  });
}
