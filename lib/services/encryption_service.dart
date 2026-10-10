import 'package:encrypt/encrypt.dart';

class EncryptionService {
  static final EncryptionService _instance = EncryptionService._internal();
  factory EncryptionService() => _instance;
  EncryptionService._internal();

  // Using a fixed key for simplicity (in production, use key exchange)
  // This key is derived from the secret code 1997
  final _key = Key.fromUtf8('1997199719971997'); // 16 chars for AES-128
  final _iv = IV.fromUtf8('1997199719971997'); // 16 chars

  String encrypt(String plainText) {
    final encrypter = Encrypter(AES(_key, mode: AESMode.cbc));
    final encrypted = encrypter.encrypt(plainText, iv: _iv);
    return encrypted.base64;
  }

  String decrypt(String encryptedText) {
    try {
      final encrypter = Encrypter(AES(_key, mode: AESMode.cbc));
      final decrypted = encrypter.decrypt64(encryptedText, iv: _iv);
      return decrypted;
    } catch (e) {
      return encryptedText; // Return as-is if decryption fails
    }
  }
}