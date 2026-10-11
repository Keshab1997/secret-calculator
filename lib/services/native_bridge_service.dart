import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter/foundation.dart';

import 'encryption_service.dart';

class NativeBridgeService {
  static final NativeBridgeService _instance = NativeBridgeService._internal();
  factory NativeBridgeService() => _instance;
  NativeBridgeService._internal();

  final LocalAuthentication _localAuth = LocalAuthentication();
  File? _activeVoiceTempFile;
  Timer? _voiceTempCleanupTimer;

  static const MethodChannel _channel = MethodChannel(
    'com.keshabstudios.calculator/native',
  );

  /// Removes voice playback temp directories left behind if the process was
  /// killed before the normal playback/stop cleanup could run.
  Future<void> cleanupStaleVoicePlaybackFiles() async {
    try {
      final temporary = Directory.systemTemp;
      await for (final entity in temporary.list()) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('secret_calc_voice_')) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

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
  ///
  /// [mode] is the user's call-alert preference: 'sound' plays the ringtone
  /// plus a repeating vibration (the default), 'vibrate' vibrates without
  /// any audio, and 'silent' does neither — the call simply appears on
  /// screen.
  Future<void> startRingtone({String mode = 'sound'}) async {
    try {
      await _channel.invokeMethod('startRingtone', {'mode': mode});
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

  /// Decrypts an AES-256-GCM encrypted base64 payload to a short-lived
  /// temporary file for native playback. The file is removed on stop or after
  /// the native-reported playback duration; it is never kept as a media cache.
  /// Testing seam: when set, [playEncryptedAudio] avoids touching disk.
  @visibleForTesting
  Future<bool> Function(String payload, EncryptionService encryption)?
  playEncryptedAudioForTesting;

  Future<bool> playEncryptedAudio(
    String encryptedBase64Payload,
    EncryptionService encryption, {
    int? durationSeconds,
  }) async {
    final override = playEncryptedAudioForTesting;
    if (override != null) {
      return override(encryptedBase64Payload, encryption);
    }
    File? targetFile;
    try {
      final decryptedBase64 = encryption.decrypt(encryptedBase64Payload);
      final bytes = base64Decode(decryptedBase64);
      if (bytes.isEmpty) return false;
      await stopAudio();
      final tempDirectory = await Directory.systemTemp.createTemp(
        'secret_calc_voice_',
      );
      targetFile = File('${tempDirectory.path}/playback.m4a');
      await targetFile.writeAsBytes(bytes, flush: true);
      _activeVoiceTempFile = targetFile;
      final nativeDurationMs = await playAudioFile(targetFile.path);
      final fallbackMs = (durationSeconds ?? 60).clamp(1, 3600).toInt() * 1000;
      final cleanupMs = (nativeDurationMs ?? fallbackMs)
          .clamp(1000, 3600000)
          .toInt();
      _voiceTempCleanupTimer?.cancel();
      _voiceTempCleanupTimer = Timer(
        Duration(milliseconds: cleanupMs + 1500),
        () => unawaited(_deleteVoiceTempFile(targetFile!)),
      );
      return true;
    } catch (_) {
      if (targetFile != null) await _deleteVoiceTempFile(targetFile);
      return false;
    }
  }

  Future<void> _deleteVoiceTempFile(File file) async {
    if (_activeVoiceTempFile?.path == file.path) {
      _activeVoiceTempFile = null;
      _voiceTempCleanupTimer?.cancel();
      _voiceTempCleanupTimer = null;
    }
    try {
      if (await file.exists()) await file.parent.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> stopAudio() async {
    try {
      await _channel.invokeMethod<bool>('stopAudio');
    } on MissingPluginException {
      // No-op in tests or unsupported platforms.
    } on PlatformException {
      // Ignore stop errors.
    }
    _voiceTempCleanupTimer?.cancel();
    _voiceTempCleanupTimer = null;
    final file = _activeVoiceTempFile;
    if (file != null) await _deleteVoiceTempFile(file);
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
