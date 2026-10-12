import 'package:calculator/services/firebase_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FirebaseService room codes & peer identity', () {
    test('generateRoomCode returns 6-char uppercase unambiguous code', () {
      for (var i = 0; i < 50; i++) {
        final code = FirebaseService.generateRoomCode();
        expect(code.length, equals(6));
        expect(code, equals(code.toUpperCase()));
        expect(code.contains('0'), isFalse);
        expect(code.contains('O'), isFalse);
        expect(code.contains('1'), isFalse);
        expect(code.contains('I'), isFalse);
        expect(FirebaseService.isValidRoomCode(code), isTrue);
      }
    });

    test('isValidRoomCode validates length and character set', () {
      expect(FirebaseService.isValidRoomCode('AB23CD'), isTrue);
      expect(FirebaseService.isValidRoomCode('  ab23cd '), isTrue);
      expect(FirebaseService.isValidRoomCode('ABC'), isFalse);
      expect(FirebaseService.isValidRoomCode('ABCD123'), isFalse);
      expect(FirebaseService.isValidRoomCode('AB-123'), isFalse);
    });

    test(
      'Personal IDs normalize for display and reject ambiguous characters',
      () {
        expect(FirebaseService.isValidPersonalId('ABCDEFGHJK'), isTrue);
        expect(
          FirebaseService.normalizePersonalId('abcde-fghjk'),
          'ABCDEFGHJK',
        );
        expect(FirebaseService.formatPersonalId('abcde-fghjk'), 'ABCDE-FGHJK');
        expect(FirebaseService.isValidPersonalId('ABCDE0GHJK'), isFalse);
        expect(FirebaseService.isValidPersonalId('ABCDE1GHJK'), isFalse);
        expect(FirebaseService.isValidPersonalId('ABCDEIGHJK'), isFalse);
        expect(FirebaseService.isValidPersonalId('ABCDEOGHJK'), isFalse);
        expect(FirebaseService.isValidPersonalId('ABCDEF'), isFalse);
      },
    );

    test('secure invitations include a separate 256-bit secret', () {
      for (var i = 0; i < 10; i++) {
        final room = FirebaseService.generateRoomCode();
        final secret = FirebaseService.generateRoomSecret();
        expect(secret.length, 43);
        expect(FirebaseService.isValidInviteCode('$room.$secret'), isTrue);
        final parsed = FirebaseService.parseInviteCode(
          '${room.toLowerCase()}.$secret',
        );
        expect(parsed?.roomId, room);
        expect(parsed?.secret, secret);
        expect(FirebaseService.isValidInviteCode(room), isFalse);
      }
    });

    test('getShortCode returns full 6-character room code', () {
      final service = FirebaseService();
      service.setRoomIdForTesting('k7m9p2');
      expect(service.getShortCode(), equals('K7M9P2'));
      service.setRoomIdForTesting(null);
      expect(service.getShortCode(), isEmpty);
    });

    test(
      'peerId is a non-empty 16-character identifier distinct from roomId',
      () {
        final service = FirebaseService();
        service.setRoomIdForTesting('K7M9P2');
        expect(service.peerId.length, equals(16));
        expect(service.myPeerId, equals(service.peerId));
        expect(service.peerId, isNot(equals(service.getShortCode())));
      },
    );
  });
}
