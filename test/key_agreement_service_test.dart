import 'package:calculator/services/key_agreement_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy invite verifier is a SHA-256 hash of the room secret', () {
    expect(
      KeyAgreementService.hashInviteSecret('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('both peers derive the same room key without sharing private keys', () {
    final alice = KeyAgreementService.generateKeyPair();
    final bob = KeyAgreementService.generateKeyPair();

    final aliceSecret = KeyAgreementService.deriveRoomSecret(
      privateKey: alice.privateKey,
      peerPublicKey: bob.publicKey,
      roomId: 'AB23CD',
    );
    final bobSecret = KeyAgreementService.deriveRoomSecret(
      privateKey: bob.privateKey,
      peerPublicKey: alice.publicKey,
      roomId: 'AB23CD',
    );

    expect(alice.publicKey, isNot(bob.publicKey));
    expect(aliceSecret, bobSecret);
    expect(aliceSecret, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(
      KeyAgreementService.deriveRoomSecret(
        privateKey: alice.privateKey,
        peerPublicKey: bob.publicKey,
        roomId: 'EF45GH',
      ),
      isNot(aliceSecret),
    );
  });

  test('rejects malformed and invalid key material', () {
    expect(
      () => KeyAgreementService.deriveRoomSecret(
        privateKey: 'bad',
        peerPublicKey: 'bad',
        roomId: 'AB23CD',
      ),
      throwsFormatException,
    );
  });
}
