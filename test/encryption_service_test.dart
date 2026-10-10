import 'package:calculator/services/encryption_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EncryptionService', () {
    late EncryptionService service;

    setUp(() {
      service = EncryptionService()..resetKey();
    });

    test('uses a 256-bit (32-byte) AES key', () {
      expect(service.keyLengthBytes, 32);
    });

    test('round-trips plaintext including emojis and unicode', () {
      const samples = [
        'Hello, secret world!',
        '1997',
        '😀😂❤️🔥 গোপন বার্তা',
        '   leading and trailing spaces   ',
      ];

      for (final sample in samples) {
        final cipher = service.encrypt(sample);
        expect(cipher, isNot(equals(sample)));
        expect(service.decrypt(cipher), equals(sample));
      }
    });

    test('round-trips empty string', () {
      final cipher = service.encrypt('');
      expect(service.decrypt(cipher), equals(''));
    });

    test(
      'produces different ciphertexts for identical plaintexts (random IV)',
      () {
        const message = 'same plaintext twice';
        final first = service.encrypt(message);
        final second = service.encrypt(message);

        expect(first, isNot(equals(second)));
        expect(service.decrypt(first), equals(message));
        expect(service.decrypt(second), equals(message));
      },
    );

    test('throws FormatException on malformed or tampered ciphertext', () {
      expect(() => service.decrypt('not-encrypted'), throwsFormatException);
      expect(() => service.decrypt('bad:base64!'), throwsFormatException);

      final valid = service.encrypt('secret message');
      final parts = valid.split(':');
      final tampered = '${parts[0]}:AAAA${parts[1].substring(4)}';
      expect(() => service.decrypt(tampered), throwsFormatException);
    });

    test('room-specific keys isolate messages between rooms', () {
      final roomA = EncryptionService.withPassphrase('ROOM2A');
      final roomB = EncryptionService.withPassphrase('ROOM3B');

      final cipher = roomA.encrypt('only for room A');
      expect(roomA.decrypt(cipher), equals('only for room A'));
      expect(() => roomB.decrypt(cipher), throwsFormatException);
    });
  });
}
