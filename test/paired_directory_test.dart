import 'dart:convert';
import 'dart:io';

import 'package:calculator/services/encryption_service.dart';
import 'package:calculator/services/firebase_service.dart';
import 'package:calculator/services/media_cache_service.dart';
import 'package:calculator/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Paired directory and profile persistence', () {
    late Directory temporary;
    late File state;
    late FirebaseService service;
    setUp(() {
      temporary = Directory.systemTemp.createTempSync('messaging-test-');
      state = File('${temporary.path}/state.json');
      service = FirebaseService.forTesting(state);
    });
    tearDown(() => temporary.deleteSync(recursive: true));

    test(
      'legacy rooms require a secure re-pair while passcodes migrate safely',
      () async {
        state.writeAsStringSync(
          jsonEncode({
            'peerId': '1234567890abcdef',
            'roomId': 'AB23CD',
            'customPasscode': '2580',
            'biometricEnabled': true,
          }),
        );
        await service.loadSavedState();
        expect(service.pairedRooms, isEmpty);
        expect(service.needsSecureRePair, isTrue);
        expect(service.peerId, '1234567890abcdef');
        expect(service.customPasscode, '2580');
        expect(service.biometricEnabled, isTrue);
        await expectLater(service.selectRoom('AB23CD'), throwsArgumentError);
        final saved = jsonDecode(state.readAsStringSync()) as Map;
        expect(saved.containsKey('customPasscode'), isFalse);
        expect(saved.containsKey('decoyPasscode'), isFalse);
      },
    );

    test(
      'multiple pairs survive switching, restart and selective unpair',
      () async {
        for (final code in ['AB23CD', 'EF45GH']) {
          service.setRoomIdForTesting(code);
          await service.markRoomPaired();
        }
        await service.selectRoom('AB23CD');
        final restarted = FirebaseService.forTesting(state);
        await restarted.loadSavedState();
        expect(restarted.pairedRooms.length, 2);
        await restarted.selectRoom('AB23CD');
        await restarted.leaveRoom();
        expect(restarted.pairedRooms.keys, ['EF45GH']);
        final saved = jsonDecode(state.readAsStringSync()) as Map;
        expect((saved['pairedRooms'] as Map).keys, ['EF45GH']);
        expect(saved['roomId'], isNull);
      },
    );

    test(
      'unknown rooms cannot be selected and corrupt codes are ignored',
      () async {
        state.writeAsStringSync(
          jsonEncode({
            'pairedRooms': {'../../bad': 'bad', ' ab23cd ': 'Contact'},
          }),
        );
        await service.loadSavedState();
        expect(service.pairedRooms, isEmpty);
        expect(service.needsSecureRePair, isTrue);
        await expectLater(service.selectRoom('ZZ99ZZ'), throwsArgumentError);
      },
    );

    test('profile is persisted and validated', () async {
      await service.saveProfile({'name': '  Keshab  ', 'about': 'Hello'});
      final restarted = FirebaseService.forTesting(state);
      await restarted.loadSavedState();
      expect(restarted.profile['name'], 'Keshab');
      expect(restarted.profile['about'], 'Hello');
      await expectLater(
        service.saveProfile({'name': '   '}),
        throwsArgumentError,
      );
      await expectLater(
        service.saveProfile({'name': 'Okay', 'about': 'x' * 141}),
        throwsArgumentError,
      );
    });

    test('profile decoding uses the protected room key, excludes self and fails closed', () {
      service.setRoomIdForTesting('AB23CD', secret: 'unit-test-room-secret');
      final cipher = EncryptionService.withPassphrase('unit-test-room-secret');
      final encoded = cipher.encrypt(
        jsonEncode({'name': 'Partner', 'about': 'Hi'}),
      );
      expect(
        service.partnerProfile('AB23CD', {'other': encoded})['name'],
        'Partner',
      );
      expect(service.partnerProfile('EF45GH', {'other': encoded}), isEmpty);
      expect(
        service.partnerProfile('AB23CD', {service.peerId: encoded}),
        isEmpty,
      );
      expect(service.partnerProfile('AB23CD', {'other': 'broken'}), isEmpty);
    });
  });

  group('Media caching and discreet SMS notification throttling', () {
    test('avatarProvider caches decoded base64 image instances in memory', () {
      final cache = MediaCacheService();
      // 1x1 transparent PNG in base64
      const base64Png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
      final first = cache.avatarProvider(base64Png);
      final second = cache.avatarProvider(base64Png);
      expect(first, isNotNull);
      expect(identical(first, second), isTrue);
      expect(cache.avatarProvider(''), isNull);
      expect(cache.avatarProvider('!!!not-base64!!!'), isNull);
    });

    test('shouldAllowAlert deduplicates messageId and enforces cooldown', () {
      final notifications = NotificationService()..resetThrottleForTesting();
      final t0 = DateTime(2026, 10, 11, 12, 0, 0);

      expect(
        notifications.shouldAllowAlert(messageId: 'msg-1', now: t0),
        isTrue,
      );
      // Duplicate messageId is suppressed even after cooldown.
      expect(
        notifications.shouldAllowAlert(
          messageId: 'msg-1',
          now: t0.add(const Duration(minutes: 5)),
        ),
        isFalse,
      );
      // Burst message within 25s cooldown is suppressed for stealth.
      expect(
        notifications.shouldAllowAlert(
          messageId: 'msg-2',
          now: t0.add(const Duration(seconds: 10)),
        ),
        isFalse,
      );
      // Message after cooldown is allowed.
      expect(
        notifications.shouldAllowAlert(
          messageId: 'msg-3',
          now: t0.add(const Duration(seconds: 30)),
        ),
        isTrue,
      );
    });
  });
}
