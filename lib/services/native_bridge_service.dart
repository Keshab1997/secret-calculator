import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'encryption_service.dart';

class NativeBridgeService {
  static final NativeBridgeService _instance = NativeBridgeService._internal();
  factory NativeBridgeService() => _instance;
  NativeBridgeService._internal();

  static const MethodChannel _channel = MethodChannel(
    'com.keshabstudios.calculator/native',
  );

  Future<bool> ensureMicPermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>('ensureMicPermission');
      return granted ?? false;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return false;
    }
  }

  Future<String?> startRecording() async {
    try {
      return await _channel.invokeMethod<String>('startRecording');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<String?> stopRecording() async {
    try {
      return await _channel.invokeMethod<String>('stopRecording');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<int?> playAudioFile(String filePath) async {
    try {
      return await _channel.invokeMethod<int>('playAudio', {'path': filePath});
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Decrypts an AES-256-GCM encrypted base64 audio payload, writes it to a
  /// temporary `.m4a` file, and plays it via the native media player.
  Future<bool> playEncryptedAudio(
    String encryptedBase64Payload,
    EncryptionService encryption,
  ) async {
    try {
      final decryptedBase64 = encryption.decrypt(encryptedBase64Payload);
      final bytes = base64Decode(decryptedBase64);
      final tempFile = File(
        '${Directory.systemTemp.path}/voice_play_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      await tempFile.writeAsBytes(bytes, flush: true);
      await playAudioFile(tempFile.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stopAudio() async {
    try {
      await _channel.invokeMethod<bool>('stopAudio');
    } on MissingPluginException {
      // No-op in tests or unsupported platforms.
    } on PlatformException {
      // Ignore stop errors.
    }
  }

  Future<void> setSpeakerphone(bool enabled) async {
    try {
      await _channel.invokeMethod<bool>('setSpeakerphone', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // No-op in tests.
    } on PlatformException {
      // Ignore.
    }
  }

  Future<bool> authenticateDevice() async {
    try {
      final verified = await _channel.invokeMethod<bool>('authenticateDevice');
      return verified ?? false;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return false;
    }
  }
}
