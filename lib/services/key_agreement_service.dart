import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// One-use P-256 ECDH material for a connection request or its acceptance.
class ContactKeyPair {
  const ContactKeyPair({required this.privateKey, required this.publicKey});

  /// Base64url-encoded 32-byte scalar. Store only in platform secure storage.
  final String privateKey;

  /// Base64url-encoded uncompressed P-256 point; safe to send to Firebase.
  final String publicKey;
}

/// Derives the same per-room secret on both devices without sending it to the
/// server. The ECDH private scalar remains only in local secure storage.
abstract final class KeyAgreementService {
  static const int _privateKeyBytes = 32;
  static const int _publicKeyBytes = 65;
  static const int _roomSecretBytes = 32;
  static final Uint8List _salt = Uint8List.fromList(
    utf8.encode('secret-calculator-contact-kdf-v1'),
  );

  /// Produces the server-side invite verifier without disclosing the room key.
  static String hashInviteSecret(String secret) {
    final digest = SHA256Digest().process(
      Uint8List.fromList(utf8.encode(secret)),
    );
    return digest.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static ContactKeyPair generateKeyPair() {
    final source = Random.secure();
    final seed = Uint8List.fromList(
      List<int>.generate(_privateKeyBytes, (_) => source.nextInt(256)),
    );
    final random = FortunaRandom()..seed(KeyParameter(seed));
    final domain = ECCurve_secp256r1();
    final generator = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(domain), random));
    final pair = generator.generateKeyPair();
    final privateKey = pair.privateKey as ECPrivateKey;
    final publicKey = pair.publicKey as ECPublicKey;
    final encodedPrivate = _bigIntToBytes(privateKey.d!, _privateKeyBytes);
    final encodedPublic = publicKey.Q!.getEncoded(false);
    if (encodedPublic.length != _publicKeyBytes || encodedPublic.first != 4) {
      throw StateError('Unexpected P-256 public key encoding.');
    }
    return ContactKeyPair(
      privateKey: _encode(encodedPrivate),
      publicKey: _encode(encodedPublic),
    );
  }

  /// Uses P-256 ECDH followed by HKDF-SHA-256, binding the result to [roomId].
  /// The returned value has the same format as existing protected room keys.
  static String deriveRoomSecret({
    required String privateKey,
    required String peerPublicKey,
    required String roomId,
  }) {
    final domain = ECCurve_secp256r1();
    final privateBytes = _decode(privateKey);
    final publicBytes = _decode(peerPublicKey);
    if (privateBytes.length != _privateKeyBytes ||
        publicBytes.length != _publicKeyBytes ||
        publicBytes.first != 4) {
      throw const FormatException('Invalid contact key material.');
    }

    final scalar = _bytesToBigInt(privateBytes);
    if (scalar <= BigInt.zero || scalar >= domain.n) {
      throw const FormatException('Invalid contact private key.');
    }
    final point = domain.curve.decodePoint(publicBytes);
    if (point == null || point.isInfinity) {
      throw const FormatException('Invalid contact public key.');
    }

    final agreement = ECDHBasicAgreement()..init(ECPrivateKey(scalar, domain));
    final shared = agreement.calculateAgreement(ECPublicKey(point, domain));
    final sharedBytes = _bigIntToBytes(shared, _privateKeyBytes);
    final derivator = HKDFKeyDerivator(SHA256Digest())
      ..init(
        HkdfParameters(
          sharedBytes,
          _roomSecretBytes,
          _salt,
          Uint8List.fromList(utf8.encode('secret-calculator-room-v1:$roomId')),
        ),
      );
    final roomKey = Uint8List(_roomSecretBytes);
    derivator.deriveKey(null, 0, roomKey, 0);
    return _encode(roomKey);
  }

  static Uint8List _decode(String value) {
    try {
      return base64Url.decode(base64Url.normalize(value));
    } on FormatException {
      throw const FormatException('Invalid contact key encoding.');
    }
  }

  static String _encode(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  static BigInt _bytesToBigInt(List<int> bytes) {
    var value = BigInt.zero;
    for (final byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final hex = value.toRadixString(16).padLeft(length * 2, '0');
    if (hex.length > length * 2) {
      throw const FormatException('Contact key is too large.');
    }
    return Uint8List.fromList(
      List<int>.generate(
        length,
        (index) =>
            int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16),
      ),
    );
  }
}
