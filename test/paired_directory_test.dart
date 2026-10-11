import 'dart:convert';
import 'dart:io';

import 'package:calculator/services/encryption_service.dart';
import 'package:calculator/services/firebase_service.dart';
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
      'migrates the old single-room state without losing identity or passcode',
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
        expect(service.pairedRooms.keys, ['AB23CD']);
        expect(service.peerId, '1234567890abcdef');
        expect(service.customPasscode, '2580');
        expect(service.biometricEnabled, isTrue);
        await service.selectRoom('AB23CD');
        expect(service.getShortCode(), 'AB23CD');
        expect(service.isPaired, isTrue);
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
        expect(service.pairedRooms.keys, ['AB23CD']);
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

    test('profile decoding uses the requested room key, excludes self and fails closed', () {
      final cipher = EncryptionService.withPassphrase('AB23CD');
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
}
