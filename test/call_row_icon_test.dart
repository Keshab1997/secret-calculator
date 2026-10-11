import 'package:calculator/widgets/messaging_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('callRowIcon', () {
    test('a missed incoming call is the loudest, actionable row', () {
      final info = callRowIcon(isMe: false, callOutcome: 'missed');
      expect(info.icon, Icons.call_missed_outlined);
      expect(info.color, const Color(0xFFE5484D));
    });

    test('a completed call is green and direction-aware', () {
      expect(
        callRowIcon(isMe: true, callOutcome: 'completed').icon,
        Icons.call_made_outlined,
      );
      expect(
        callRowIcon(isMe: false, callOutcome: 'completed').icon,
        Icons.call_received_outlined,
      );
      expect(
        callRowIcon(isMe: true, callOutcome: 'completed').color,
        chatGreen,
      );
      expect(
        callRowIcon(isMe: false, callOutcome: 'completed').color,
        chatGreen,
      );
    });

    test('an outgoing call with no answer is muted, not red', () {
      final info = callRowIcon(isMe: true, callOutcome: 'missed');
      expect(info.icon, Icons.call_made_outlined);
      expect(info.color, const Color(0xFF8A97A0));
    });

    test('a declined call is muted regardless of direction', () {
      expect(
        callRowIcon(isMe: true, callOutcome: 'declined').color,
        const Color(0xFF8A97A0),
      );
      expect(
        callRowIcon(isMe: false, callOutcome: 'declined').color,
        const Color(0xFF8A97A0),
      );
    });

    test('missing outcome is treated as a missed call', () {
      expect(
        callRowIcon(isMe: false, callOutcome: null).icon,
        Icons.call_missed_outlined,
      );
    });
  });
}
