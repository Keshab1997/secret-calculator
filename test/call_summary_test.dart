import 'package:calculator/widgets/messaging_style.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('callLogText', () {
    test('connected calls show the duration for both sides', () {
      for (final isMe in [true, false]) {
        final log = callLogText(
          callType: 'voice',
          callSeconds: 83,
          callOutcome: 'completed',
          isMe: isMe,
        );
        expect(log.title, 'Voice call');
        expect(log.detail, '1:23');
      }
      final video = callLogText(
        callType: 'video',
        callSeconds: 7,
        callOutcome: 'completed',
        isMe: true,
      );
      expect(video.title, 'Video call');
      expect(video.detail, '0:07');
    });

    test('missed call reads as missed for the callee and no answer for me', () {
      final callee = callLogText(
        callType: 'voice',
        callSeconds: null,
        callOutcome: 'missed',
        isMe: false,
      );
      expect(callee.title, 'Missed Voice call');
      expect(callee.detail, 'Tap to call back');

      final caller = callLogText(
        callType: 'voice',
        callSeconds: null,
        callOutcome: 'missed',
        isMe: true,
      );
      expect(caller.title, 'Voice call');
      expect(caller.detail, 'No answer');
    });

    test('a rejected call reads as declined for both sides', () {
      for (final isMe in [true, false]) {
        final log = callLogText(
          callType: 'video',
          callSeconds: null,
          callOutcome: 'declined',
          isMe: isMe,
        );
        expect(log.title, 'Declined Video call');
        expect(log.detail, 'Tap to call back');
      }
    });

    test('legacy entries without callOutcome fall back to callSeconds', () {
      // Old clients only recorded callSeconds; null meant never connected.
      final legacyMissed = callLogText(
        callType: 'voice',
        callSeconds: null,
        callOutcome: null,
        isMe: false,
      );
      expect(legacyMissed.title, 'Missed Voice call');

      final legacyCompleted = callLogText(
        callType: 'voice',
        callSeconds: 12,
        callOutcome: null,
        isMe: true,
      );
      expect(legacyCompleted.title, 'Voice call');
      expect(legacyCompleted.detail, '0:12');
    });

    test('unknown outcomes degrade to the completed wording', () {
      final log = callLogText(
        callType: 'voice',
        callSeconds: 3,
        callOutcome: 'something-new',
        isMe: true,
      );
      expect(log.title, 'Voice call');
      expect(log.detail, '0:03');
    });
  });

  group('formatCallDuration', () {
    test('formats m:ss and clamps negatives', () {
      expect(formatCallDuration(0), '0:00');
      expect(formatCallDuration(9), '0:09');
      expect(formatCallDuration(60), '1:00');
      expect(formatCallDuration(600), '10:00');
      expect(formatCallDuration(-5), '0:00');
    });
  });
}
