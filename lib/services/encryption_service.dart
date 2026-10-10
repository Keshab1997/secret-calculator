import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';

class EncryptionService {
  static final EncryptionService _instance = EncryptionService._internal();
  factory EncryptionService() => _instance;
  EncryptionService._internal() : _key = _deriveKey(_defaultPassphrase);

  /// Creates an isolated instance with its own key (useful for testing or
  /// per-room encryption contexts).
  EncryptionService.withPassphrase(String passphrase)
    : _key = _deriveKey(passphrase);

  static const String _defaultPassphrase =
      'com.keshabstudios.calculator.default.v1';
  static const int _keyLengthBytes = 32; // 256 bits (AES-256)
  static const int _nonceLengthBytes = 12; // 96-bit nonce for AES-GCM
  static final Uint8List _kdfSalt = Uint8List.fromList(
    'secret-calculator-kdf-salt-v1'.codeUnits,
  );

  Key _key;

  /// Number of key bytes (always 32 for AES-256).
  int get keyLengthBytes => _key.length;

  /// Derives and sets a 256-bit room-specific key from [roomSecret].
  void setRoomKey(String roomSecret) {
    final normalized = roomSecret.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(roomSecret, 'roomSecret', 'Must not be empty');
    }
    _key = _deriveKey(normalized);
  }

  /// Resets the key back to the default key.
  void resetKey() {
    _key = _deriveKey(_defaultPassphrase);
  }

  static Key _deriveKey(String passphrase) {
    return Key.fromUtf8(passphrase)
        .stretch(_keyLengthBytes, iterationCount: 2048, salt: _kdfSalt);
  }

  /// Encrypts [plainText] using AES-256-GCM with a fresh random 12-byte nonce.
  /// Returns `<nonceBase64>:<ciphertextWithTagBase64>`.
  String encrypt(String plainText) {
    final iv = IV.fromSecureRandom(_nonceLengthBytes);
    final encrypter = Encrypter(AES(_key, mode: AESMode.gcm));
    final encrypted = encrypter.encryptBytes(
      Uint8List.fromList(
        plainText.codeUnits.isEmpty
            ? const <int>[]
            : Encrypted.fromUtf8(plainText).bytes,
      ),
      iv: iv,
    );
    return '${iv.base64}:${encrypted.base64}';
  }

  /// Decrypts a payload produced by [encrypt].
  /// Throws [FormatException] if the payload is malformed, tampered with, or
  /// encrypted under a different key.
  String decrypt(String encryptedText) {
    final separatorIndex = encryptedText.indexOf(':');
    if (separatorIndex <= 0 || separatorIndex == encryptedText.length - 1) {
      throw const FormatException('Invalid encrypted payload format.');
    }

    final ivPart = encryptedText.substring(0, separatorIndex);
    final cipherPart = encryptedText.substring(separatorIndex + 1);
    if (cipherPart.contains(':')) {
      throw const FormatException('Invalid encrypted payload format.');
    }

    try {
      final iv = IV.fromBase64(ivPart);
      if (iv.bytes.length != _nonceLengthBytes) {
        throw const FormatException('Invalid nonce length.');
      }
      final encrypted = Encrypted.fromBase64(cipherPart);
      if (encrypted.bytes.length < 16) {
        // AES-GCM authentication tag is 16 bytes minimum.
        throw const FormatException('Ciphertext too short.');
      }
      final encrypter = Encrypter(AES(_key, mode: AESMode.gcm));
      return encrypter.decrypt(encrypted, iv: iv);
    } catch (e) {
      if (e is FormatException) rethrow;
      throw FormatException('Decryption failed: $e');
    }
  }
}
