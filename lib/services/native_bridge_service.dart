import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter/foundation.dart';

import 'encryption_service.dart';
import 'media_cache_service.dart';

class NativeBridgeService {
  static final NativeBridgeService _instance = NativeBridgeService._internal();
  factory NativeBridgeService() => _instance;
  NativeBridgeService._internal();

  final LocalAuthentication _localAuth = LocalAuthentication();

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

  /// Plays the device's default ringtone (looping) for an incoming call.
  Future<void> startRingtone() async {
    try {
      await _channel.invokeMethod('startRingtone');
    } catch (_) {
      // Fail silently when the platform channel is unavailable (e.g. tests).
    }
  }

  /// Stops the ringtone started by [startRingtone].
  Future<void> stopRingtone() async {
    try {
      await _channel.invokeMethod('stopRingtone');
    } catch (_) {
      // Fail silently when the platform channel is unavailable (e.g. tests).
    }
  }

  /// Decrypts an AES-256-GCM encrypted base64 audio payload, writes it to a
  /// temporary `.m4a` file, and plays it via the native media player.
  /// Testing seam: when set, [playEncryptedAudio] delegates to this instead
  /// of decrypting and touching the disk — the UI's play/stop/progress
  /// behavior does not depend on any of that.
  @visibleForTesting
  Future<bool> Function(String payload, EncryptionService encryption)?
  playEncryptedAudioForTesting;

  Future<bool> playEncryptedAudio(
    String encryptedBase64Payload,
    EncryptionService encryption,
  ) async {
    final override = playEncryptedAudioForTesting;
    if (override != null) {
      return override(encryptedBase64Payload, encryption);
    }
    try {
      final decryptedBase64 = encryption.decrypt(encryptedBase64Payload);
      final bytes = base64Decode(decryptedBase64);
      final cached = await MediaCacheService().getOrCacheVoiceNote(
        encryptedBase64Payload,
        bytes,
      );
      final targetFile =
          cached ??
          (await File(
            '${Directory.systemTemp.path}/voice_play_${DateTime.now().millisecondsSinceEpoch}.m4a',
          ).writeAsBytes(bytes, flush: true));
      await playAudioFile(targetFile.path);
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

  /// Toggles Android `FLAG_SECURE` so secret chat screens are hidden from
  /// Recent Apps thumbnails, screenshots, and screen recordings.
  Future<void> setSecureScreen(bool enabled) async {
    try {
      await _channel.invokeMethod<bool>('setSecureScreen', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // No-op in tests or unsupported platforms.
    } on PlatformException {
      // Ignore.
    }
  }

  /// Asks the system to verify the user's identity (fingerprint, face, or
  /// device credential) via the biometric prompt.
  ///
  /// Contract kept from the old Keyguard implementation: a device with no
  /// lock enrolled and environments without the plugin (widget tests,
  /// desktop) count as verified; a cancelled or failed prompt denies access.
  Future<bool> authenticateDevice() async {
    try {
      final supported = await _localAuth.isDeviceSupported();
      if (!supported) return true;
      return await _localAuth.authenticate(
        localizedReason: 'Verify your identity to open Secret Chat',
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }
}
