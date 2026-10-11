import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'encryption_service.dart';
import 'media_cache_service.dart';

class FirebaseService {
  static final FirebaseService _instance = FirebaseService._internal();
  factory FirebaseService() => _instance;
  FirebaseService._internal() : _peerId = generatePeerId();
  @visibleForTesting
  FirebaseService.forTesting(File stateFile)
    : _peerId = generatePeerId(),
      stateFileOverride = stateFile;

  /// Unambiguous 6-character code alphabet (excludes 0, O, 1, I).
  static const String codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const int roomCodeLength = 6;
  static const String defaultPasscode = '1997';

  /// Explicit Realtime Database URL (required because the database resides in
  /// `asia-southeast1` and `google-services.json` may omit `firebase_url`).
  static const String defaultDatabaseUrl =
      'https://secret-calculator-fce20-default-rtdb.asia-southeast1.firebasedatabase.app';

  static final Random _random = Random.secure();
  static final RegExp _validCodePattern = RegExp(r'^[A-Z0-9]{6}$');
  static final RegExp _validPasscodePattern = RegExp(r'^[0-9]{4,8}$');

  final Map<String, String> _pairedRooms = {};
  Map<String, String> _profile = {
    'name': 'Calculator user',
    'about': 'Available',
  };
  Map<String, String> get pairedRooms => Map.unmodifiable(_pairedRooms);
  Map<String, String> get profile => Map.unmodifiable(_profile);

  String _peerId;
  DatabaseReference? _chatRef;
  String? _roomId;
  bool _isPaired = false;
  bool _isOnline = true;
  bool? _lastWrittenOnline;
  bool? _lastWrittenTyping;
  String? _lastWrittenStatusRoom;
  bool _persistenceConfigured = false;
  final Map<String, ({String cipher, Map<String, String> profile})>
  _partnerProfileCache = {};
  String _customPasscode = defaultPasscode;
  String? _decoyPasscode;
  bool _biometricEnabled = false;
  int? _disappearingSeconds;
  final EncryptionService _encryption = EncryptionService();

  /// Unique per-install/session peer identifier used as `senderId` and status key.
  String get peerId => _peerId;

  /// Alias for [peerId].
  String get myPeerId => _peerId;

  /// Whether this device has an active paired chat room.
  bool get isPaired => _isPaired && _roomId != null;

  /// Current custom secret calculator passcode (4–8 digits).
  String get customPasscode => _customPasscode;

  /// Optional decoy calculator passcode (4–8 digits) that opens an empty decoy view.
  String? get decoyPasscode => _decoyPasscode;

  /// Whether fingerprint/biometric verification is required after entering the passcode.
  bool get biometricEnabled => _biometricEnabled;

  /// Disappearing-message timer for new messages; null = off.
  int? get disappearingSeconds => _disappearingSeconds;

  FirebaseDatabase get _db {
    final db = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: defaultDatabaseUrl,
    );
    if (!_persistenceConfigured) {
      _persistenceConfigured = true;
      try {
        db.setPersistenceEnabled(true);
        db.setPersistenceCacheSizeBytes(10 * 1024 * 1024);
      } catch (_) {}
    }
    return db;
  }

  /// Generates a random 6-character room code from [codeAlphabet].
  static String generateRoomCode() {
    return List.generate(
      roomCodeLength,
      (_) => codeAlphabet[_random.nextInt(codeAlphabet.length)],
    ).join();
  }

  /// Generates a random 16-character peer identifier.
  static String generatePeerId() {
    const hexAlphabet = '0123456789abcdef';
    return List.generate(
      16,
      (_) => hexAlphabet[_random.nextInt(hexAlphabet.length)],
    ).join();
  }

  /// Returns true when [code] is a valid 6-character alphanumeric room code.
  static bool isValidRoomCode(String code) {
    final normalized = code.trim().toUpperCase();
    return _validCodePattern.hasMatch(normalized);
  }

  /// Returns true when [passcode] is 4–8 numeric digits.
  static bool isValidPasscode(String passcode) {
    return _validPasscodePattern.hasMatch(passcode.trim());
  }

  Future<void> initialize() async {
    await Firebase.initializeApp();
    await loadSavedState();
  }

  @visibleForTesting
  File? stateFileOverride;

  Future<File> _stateFile() async {
    if (stateFileOverride != null) return stateFileOverride!;
    try {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      final primary = File('${dir.path}/secret_calc_state.json');
      if (!primary.existsSync()) {
        final legacy = _legacyStateFile();
        if (legacy.existsSync() && legacy.path != primary.path) {
          try {
            await legacy.copy(primary.path);
          } catch (_) {}
        }
      }
      return primary;
    } catch (_) {
      return _legacyStateFile();
    }
  }

  File _legacyStateFile() {
    final parentDir = Directory.systemTemp.parent;
    final filesDir = Directory('${parentDir.path}/files');
    if (filesDir.existsSync()) {
      return File('${filesDir.path}/secret_calc_state.json');
    }
    return File('${Directory.systemTemp.path}/secret_calc_state.json');
  }

  /// Loads persisted `peerId`, `pairedRoomId`, `customPasscode`, and `biometricEnabled`.
  Future<void> loadSavedState() async {
    try {
      final file = await _stateFile();
      if (!file.existsSync()) {
        await _saveState();
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        final savedPeer = decoded['peerId'];
        if (savedPeer is String && savedPeer.length == 16) {
          _peerId = savedPeer;
        }
        final savedPasscode = decoded['customPasscode'];
        if (savedPasscode is String && isValidPasscode(savedPasscode)) {
          _customPasscode = savedPasscode.trim();
        }
        final savedDecoy = decoded['decoyPasscode'];
        if (savedDecoy is String &&
            isValidPasscode(savedDecoy) &&
            savedDecoy.trim() != _customPasscode &&
            savedDecoy.trim() != defaultPasscode) {
          _decoyPasscode = savedDecoy.trim();
        }
        final savedBio = decoded['biometricEnabled'];
        if (savedBio is bool) {
          _biometricEnabled = savedBio;
        }
        final savedDisappearing = decoded['disappearingSeconds'];
        if (savedDisappearing is int) {
          _disappearingSeconds = savedDisappearing;
        }
        final rooms = decoded['pairedRooms'];
        if (rooms is Map) {
          for (final entry in rooms.entries) {
            if (isValidRoomCode(entry.key.toString())) {
              _pairedRooms[entry.key.toString().trim().toUpperCase()] = entry
                  .value
                  .toString();
            }
          }
        }
        final profile = decoded['profile'];
        if (profile is Map) {
          _profile = profile.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          );
        }
        final savedRoom = decoded['roomId'];
        if (savedRoom is String && isValidRoomCode(savedRoom)) {
          _pairedRooms.putIfAbsent(
            savedRoom.trim().toUpperCase(),
            () => 'Paired contact',
          );
        }
        if (savedRoom is String &&
            isValidRoomCode(savedRoom) &&
            Firebase.apps.isNotEmpty) {
          final normalized = savedRoom.trim().toUpperCase();
          _roomId = normalized;
          _isPaired = true;
          _encryption.setRoomKey(normalized);
          _chatRef = _db
              .ref()
              .child('rooms')
              .child(normalized)
              .child('messages');
        }
      }
    } catch (_) {
      // Ignore corrupt or inaccessible local state in restricted/test environments.
    }
  }

  Future<void> _saveState({bool strict = false}) async {
    try {
      final file = await _stateFile();
      await file.writeAsString(
        jsonEncode({
          'pairedRooms': _pairedRooms,
          'profile': _profile,
          'peerId': _peerId,
          'roomId': _isPaired ? _roomId : null,
          'customPasscode': _customPasscode,
          'decoyPasscode': _decoyPasscode,
          'biometricEnabled': _biometricEnabled,
          'disappearingSeconds': _disappearingSeconds,
        }),
      );
    } catch (_) {
      if (strict) rethrow;
      // Legacy settings remain best-effort in restricted environments.
    }
  }

  /// Updates and persists a custom calculator passcode (4–8 digits).
  Future<bool> setCustomPasscode(String code) async {
    final trimmed = code.trim();
    if (!isValidPasscode(trimmed)) return false;
    _customPasscode = trimmed;
    if (_decoyPasscode == trimmed) {
      _decoyPasscode = null;
    }
    await _saveState();
    return true;
  }

  /// Sets or clears an optional decoy passcode (4–8 digits, distinct from real unlock code).
  Future<bool> setDecoyPasscode(String? code) async {
    final trimmed = code?.trim() ?? '';
    if (trimmed.isEmpty) {
      _decoyPasscode = null;
      await _saveState();
      return true;
    }
    if (!isValidPasscode(trimmed) ||
        trimmed == _customPasscode ||
        trimmed == defaultPasscode) {
      return false;
    }
    _decoyPasscode = trimmed;
    await _saveState();
    return true;
  }

  /// Updates and persists the biometric lock setting.
  Future<void> setBiometricEnabled(bool enabled) async {
    _biometricEnabled = enabled;
    await _saveState();
  }

  /// Updates and persists the disappearing-message timer (null = off).
  Future<void> setDisappearingSeconds(int? seconds) async {
    _disappearingSeconds = seconds;
    await _saveState();
  }

  /// Marks the currently created room as paired and persists it.
  Future<void> markRoomPaired() async {
    if (_roomId == null) return;
    _isPaired = true;
    _pairedRooms.putIfAbsent(_roomId!, () => 'Paired contact');
    await _saveState(strict: true);
    try {
      await _publishProfile();
    } catch (_) {
      /* Profile can be retried from You. */
    }
    await registerFcmToken();
  }

  /// Unpairs the current room so the user can pair with a new code.
  Future<void> leaveRoom() async {
    await updateOnlineStatus(false);
    if (_roomId != null && Firebase.apps.isNotEmpty) {
      try {
        await _db
            .ref()
            .child('rooms')
            .child(_roomId!)
            .child('tokens')
            .child(_peerId)
            .remove();
      } catch (_) {
        // Best effort — stale tokens are also dropped by the Cloud Function.
      }
    }
    _pairedRooms.remove(_roomId);
    _roomId = null;
    _chatRef = null;
    _isPaired = false;
    _encryption.resetKey();
    await _saveState();
  }

  bool _fcmRefreshRegistered = false;

  /// Publishes this device's FCM token at `rooms/{roomId}/tokens/{peerId}`
  /// so the `onNewMessage` Cloud Function can push a disguised Calculator
  /// notification to the partner even when this app is closed.
  ///
  /// Failures are swallowed: local notifications still cover the case where
  /// the app is open or backgrounded.
  Future<void> registerFcmToken() async {
    if ((_roomId == null && _pairedRooms.isEmpty) || Firebase.apps.isEmpty) {
      return;
    }
    try {
      final messaging = FirebaseMessaging.instance;
      try {
        await messaging.requestPermission();
      } catch (_) {
        // Platforms without the notification permission prompt.
      }
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        for (final room in {..._pairedRooms.keys, ?_roomId}) {
          await _db.ref('rooms/$room/tokens/$_peerId').set(token);
        }
      }
      if (!_fcmRefreshRegistered) {
        _fcmRefreshRegistered = true;
        messaging.onTokenRefresh.listen((fresh) async {
          if (fresh.isEmpty) return;
          try {
            for (final code in {..._pairedRooms.keys, ?_roomId}) {
              await _db.ref('rooms/$code/tokens/$_peerId').set(fresh);
            }
          } catch (_) {}
        });
      }
    } catch (e) {
      debugPrint('registerFcmToken failed: $e');
    }
  }

  // Create a room and return the 6-character room code.
  Future<String> createRoom() async {
    final code = generateRoomCode();
    final roomRef = _db.ref().child('rooms').child(code);

    await roomRef.set({
      'createdAt': ServerValue.timestamp,
      'createdBy': _peerId,
      'members': {
        _peerId: {'joinedAt': ServerValue.timestamp},
      },
    });

    _roomId = code;
    _isPaired = false;
    _encryption.setRoomKey(code);
    _chatRef = roomRef.child('messages');
    return code;
  }

  // Join an existing room with its 6-character code.
  Future<bool> joinRoom(String roomCode) async {
    final normalized = roomCode.trim().toUpperCase();
    if (!isValidRoomCode(normalized)) {
      return false;
    }

    final roomRef = _db.ref().child('rooms').child(normalized);
    final snapshot = await roomRef.get();

    if (!snapshot.exists) {
      _roomId = null;
      _chatRef = null;
      _isPaired = false;
      return false;
    }

    _roomId = normalized;
    _isPaired = true;
    _encryption.setRoomKey(normalized);
    _chatRef = roomRef.child('messages');

    await roomRef.child('members').child(_peerId).set({
      'joinedAt': ServerValue.timestamp,
    });
    _pairedRooms.putIfAbsent(normalized, () => 'Paired contact');
    await _saveState(strict: true);
    try {
      await _publishProfile();
    } catch (_) {
      /* Pairing remains valid if profile sync fails. */
    }
    await registerFcmToken();

    return true;
  }

  /// Switching is only initiated from the directory, with no chat route open.
  Future<void> selectRoom(String code) async {
    if (!_pairedRooms.containsKey(code)) {
      throw ArgumentError('Unknown paired room');
    }
    unawaited(updateOnlineStatus(false).catchError((_) {}));
    _roomId = code;
    _isPaired = true;
    _encryption.setRoomKey(code);
    _chatRef = Firebase.apps.isEmpty ? null : _db.ref('rooms/$code/messages');
    await _saveState();
  }

  Future<void> saveProfile(Map<String, String> profile) async {
    final name = (profile['name'] ?? '').trim();
    if (name.isEmpty || name.length > 40) {
      throw ArgumentError('Name must be 1–40 characters');
    }
    if ((profile['about'] ?? '').length > 140) {
      throw ArgumentError('About must be at most 140 characters');
    }
    _profile = Map.of(profile)..['name'] = name;
    await _saveState(strict: true);
    await _publishProfile();
  }

  Future<void> _publishProfile() async {
    if (Firebase.apps.isEmpty) return;
    for (final room in _pairedRooms.keys.toList()) {
      final cipher = EncryptionService.withPassphrase(room);
      await _db
          .ref('rooms/$room/profiles/$_peerId')
          .set(cipher.encrypt(jsonEncode(_profile)));
    }
  }

  Map<String, String> partnerProfile(String room, Object? rawProfiles) {
    if (rawProfiles is! Map) return const {};
    for (final entry in rawProfiles.entries) {
      if (entry.key == _peerId || entry.value is! String) continue;
      final cipherText = entry.value as String;
      final cacheKey = '$room:${entry.key}';
      final cached = _partnerProfileCache[cacheKey];
      if (cached != null && cached.cipher == cipherText) {
        return cached.profile;
      }
      try {
        final value = jsonDecode(
          EncryptionService.withPassphrase(room).decrypt(cipherText),
        );
        if (value is Map) {
          final parsed = Map<String, String>.unmodifiable(
            value.map((k, v) => MapEntry(k.toString(), v.toString())),
          );
          _partnerProfileCache[cacheKey] = (
            cipher: cipherText,
            profile: parsed,
          );
          return parsed;
        }
      } catch (_) {
        /* Older clients may not have published a profile. */
      }
    }
    return const {};
  }

  Stream<DatabaseEvent> roomStream(String room) {
    if (Firebase.apps.isEmpty || !_pairedRooms.containsKey(room)) {
      return const Stream.empty();
    }
    return _db.ref('rooms/$room').onValue;
  }

  /// Lightweight stream of only the latest message in [room] so background
  /// alert listeners do not re-download the entire room or typing/status nodes.
  Stream<DatabaseEvent> roomLatestMessageStream(String room) {
    if (Firebase.apps.isEmpty || !_pairedRooms.containsKey(room)) {
      return const Stream.empty();
    }
    return _db
        .ref('rooms/$room/messages')
        .orderByChild('timestamp')
        .limitToLast(1)
        .onValue;
  }

  DatabaseReference? _ensureChatRef() {
    if (_chatRef == null && _roomId != null && Firebase.apps.isNotEmpty) {
      _chatRef = _db.ref().child('rooms').child(_roomId!).child('messages');
    }
    return _chatRef;
  }

  // Stream of room members so the creator knows when a partner joins.
  Stream<DatabaseEvent> getRoomMembersStream() {
    if (_roomId == null || Firebase.apps.isEmpty) {
      return const Stream.empty();
    }
    return _db.ref().child('rooms').child(_roomId!).child('members').onValue;
  }

  // Send a message with optional image, voice note, reply quote, and disappearing timer.
  Future<void> sendMessage(
    String text, {
    String? imageUrl,
    String? audioBase64,
    int? audioDurationSeconds,
    String? replyToText,
    String? replyToSenderId,
    int? expiresInSeconds,
  }) async {
    final chatRef = _ensureChatRef();
    if (chatRef == null) return;

    final encryptedText = text.isNotEmpty ? _encryption.encrypt(text) : null;
    final encryptedAudio = (audioBase64 != null && audioBase64.isNotEmpty)
        ? _encryption.encrypt(audioBase64)
        : null;
    final encryptedReply = (replyToText != null && replyToText.isNotEmpty)
        ? _encryption.encrypt(replyToText)
        : null;
    final expiresAt = expiresInSeconds != null
        ? DateTime.now()
              .add(Duration(seconds: expiresInSeconds))
              .millisecondsSinceEpoch
        : null;

    await chatRef.push().set({
      'text': encryptedText,
      'imageUrl': imageUrl,
      'timestamp': ServerValue.timestamp,
      'senderId': _peerId,
      'seen': false,
      'audioData': ?encryptedAudio,
      'audioDuration': ?audioDurationSeconds,
      'replyToText': ?encryptedReply,
      'replyToSenderId': ?replyToSenderId,
      'expiresAt': ?expiresAt,
    });
  }

  /// Starts a real-time voice or video call in the current room.
  Future<void> startCall({required bool isVideo}) async {
    if (_roomId == null || Firebase.apps.isEmpty) return;
    await _db.ref().child('rooms').child(_roomId!).child('call').set({
      'callerId': _peerId,
      'type': isVideo ? 'video' : 'voice',
      'status': 'ringing',
      'startedAt': ServerValue.timestamp,
    });
  }

  /// Accepts an incoming call in the current room.
  Future<void> acceptCall() async {
    if (_roomId == null || Firebase.apps.isEmpty) return;
    await _db.ref().child('rooms').child(_roomId!).child('call').update({
      'status': 'connected',
      'connectedAt': ServerValue.timestamp,
    });
  }

  /// Ends or declines the active call in the current room.
  Future<void> endCall() async {
    if (_roomId == null || Firebase.apps.isEmpty) return;
    final room = _db.ref('rooms/$_roomId');
    final snapshot = await room.child('call').get();
    final call = snapshot.value;
    if (call is! Map || call['startedAt'] is! int) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final connected = call['connectedAt'] as int?;
    await room.update({
      'call': null,
      'messages/call_${call['startedAt']}': {
        'senderId': call['callerId'],
        'timestamp': now,
        'seen': false,
        'callType': call['type'],
        'callSeconds': connected == null
            ? null
            : max(0, (now - connected) ~/ 1000),
      },
    });
  }

  /// Writes this peer's SDP (offer or answer) under `call/signal/{peerId}`.
  ///
  /// Callers must write this AFTER [startCall]: startCall replaces the whole
  /// `call` node and would wipe an earlier signal.
  Future<void> writeCallSignal(String type, String sdp) async {
    if (_roomId == null || Firebase.apps.isEmpty) return;
    await _db
        .ref()
        .child('rooms')
        .child(_roomId!)
        .child('call')
        .child('signal')
        .child(_peerId)
        .set({'type': type, 'sdp': sdp, 'ts': ServerValue.timestamp});
  }

  /// Appends one ICE candidate under `call/ice/{peerId}/{pushId}`.
  Future<void> writeCallIceCandidate(
    String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  ) async {
    if (_roomId == null || Firebase.apps.isEmpty || candidate.isEmpty) return;
    await _db
        .ref()
        .child('rooms')
        .child(_roomId!)
        .child('call')
        .child('ice')
        .child(_peerId)
        .push()
        .set({
          'candidate': candidate,
          'sdpMid': sdpMid,
          'sdpMLineIndex': sdpMLineIndex,
          'ts': ServerValue.timestamp,
        });
  }

  /// Listens to real-time call state and audio stream in the current room.
  Stream<DatabaseEvent> getCallStream() {
    if (_roomId == null || Firebase.apps.isEmpty) {
      return const Stream.empty();
    }
    return _db.ref().child('rooms').child(_roomId!).child('call').onValue;
  }

  /// Toggles an emoji reaction by this peer on [messageKey].
  Future<void> toggleReaction(
    String messageKey,
    String emoji, {
    String? currentReaction,
  }) async {
    final chatRef = _ensureChatRef();
    if (chatRef == null) return;
    final reactionRef = chatRef
        .child(messageKey)
        .child('reactions')
        .child(_peerId);
    if (currentReaction == emoji) {
      await reactionRef.remove();
    } else {
      await reactionRef.set(emoji);
    }
  }

  /// Marks incoming partner messages as seen.
  Future<void> markMessagesSeen(Iterable<String> messageKeys) async {
    final chatRef = _ensureChatRef();
    if (chatRef == null) return;
    for (final key in messageKeys) {
      await chatRef.child(key).update({'seen': true});
    }
  }

  Future<void> _deleteStorageUrlBestEffort(Object? rawUrl) async {
    if (rawUrl is! String || rawUrl.isEmpty || Firebase.apps.isEmpty) return;
    try {
      await FirebaseStorage.instance.refFromURL(rawUrl).delete();
    } catch (_) {}
  }

  /// Deletes a single message from the room for everyone and removes any cloud image.
  Future<void> deleteMessage(String messageKey, {String? imageUrl}) async {
    final chatRef = _ensureChatRef();
    if (chatRef == null) return;
    var urlToDelete = imageUrl;
    if (urlToDelete == null) {
      try {
        final snap = await chatRef.child(messageKey).child('imageUrl').get();
        if (snap.value is String) {
          urlToDelete = snap.value as String;
        }
      } catch (_) {}
    }
    await chatRef.child(messageKey).remove();
    await _deleteStorageUrlBestEffort(urlToDelete);
  }

  /// Clears all messages in the current room and cleans up cloud images.
  Future<void> clearAllMessages() async {
    final chatRef = _ensureChatRef();
    if (chatRef == null) return;
    final urls = <String>[];
    try {
      final snap = await chatRef.get();
      final raw = snap.value;
      if (raw is Map) {
        for (final entry in raw.values) {
          if (entry is Map && entry['imageUrl'] is String) {
            urls.add(entry['imageUrl'] as String);
          }
        }
      }
    } catch (_) {}
    await chatRef.remove();
    for (final url in urls) {
      await _deleteStorageUrlBestEffort(url);
    }
  }

  // Listen for messages (bounded to recent 150 to keep Firebase bandwidth low).
  Stream<DatabaseEvent> getMessagesStream({int limit = 150}) {
    final chatRef = _ensureChatRef();
    if (chatRef == null) {
      return const Stream.empty();
    }
    return chatRef.orderByChild('timestamp').limitToLast(limit).onValue;
  }

  // Upload image to Firebase Storage
  Future<String?> uploadImage(File imageFile) async {
    try {
      final roomSegment = _roomId ?? 'unassigned';
      final fileName =
          'images/$roomSegment/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final ref = FirebaseStorage.instance.ref().child(fileName);
      // Explicit content type: storage.rules only allows `image/*`, and
      // putFile without metadata may send none (depends on platform file
      // extension guessing) — which the rule would reject.
      await ref.putFile(imageFile, SettableMetadata(contentType: 'image/jpeg'));
      final downloadUrl = await ref.getDownloadURL();
      await MediaCacheService().seedCachedImage(downloadUrl, imageFile);
      return downloadUrl;
    } catch (e) {
      // Surfaced in `flutter run` console so upload failures are diagnosable
      // instead of silently returning null.
      debugPrint('uploadImage failed: $e');
      return null;
    }
  }

  // Update online status keyed by this device's peerId.
  Future<void> updateOnlineStatus(bool isOnline, {bool? isTyping}) async {
    _isOnline = isOnline;
    if (_roomId == null || Firebase.apps.isEmpty) return;
    final nextTyping = isTyping ?? false;
    if (_lastWrittenStatusRoom == _roomId &&
        _lastWrittenOnline == isOnline &&
        _lastWrittenTyping == nextTyping) {
      return;
    }
    _lastWrittenStatusRoom = _roomId;
    _lastWrittenOnline = isOnline;
    _lastWrittenTyping = nextTyping;

    final statusRef = _db
        .ref()
        .child('rooms')
        .child(_roomId!)
        .child('status')
        .child(_peerId);

    await statusRef.set({
      'isOnline': isOnline,
      'isTyping': nextTyping,
      'lastSeen': ServerValue.timestamp,
    });
  }

  /// Updates typing status for the current peer.
  Future<void> updateTypingStatus(bool isTyping) async {
    if (_roomId == null || Firebase.apps.isEmpty) return;
    await updateOnlineStatus(_isOnline, isTyping: isTyping);
  }

  // Listen for partner's online status.
  Stream<DatabaseEvent> getPartnerStatusStream([String? partnerPeerId]) {
    if (_roomId == null || Firebase.apps.isEmpty) {
      return const Stream.empty();
    }
    final statusRef = _db.ref().child('rooms').child(_roomId!).child('status');
    if (partnerPeerId != null && partnerPeerId.isNotEmpty) {
      return statusRef.child(partnerPeerId).onValue;
    }
    return statusRef.onValue;
  }

  // Current 6-character room code.
  String getShortCode() => _roomId ?? '';

  @visibleForTesting
  void setRoomIdForTesting(String? code, {bool paired = false}) {
    _roomId = code?.trim().toUpperCase();
    _isPaired = paired && _roomId != null;
  }
}
