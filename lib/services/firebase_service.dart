import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import 'encryption_service.dart';

class FirebaseService {
  static final FirebaseService _instance = FirebaseService._internal();
  factory FirebaseService() => _instance;
  FirebaseService._internal() : _peerId = generatePeerId();

  /// Unambiguous 6-character code alphabet (excludes 0, O, 1, I).
  static const String codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const int roomCodeLength = 6;

  /// Explicit Realtime Database URL (required because the database resides in
  /// `asia-southeast1` and `google-services.json` may omit `firebase_url`).
  static const String defaultDatabaseUrl =
      'https://secret-calculator-fce20-default-rtdb.asia-southeast1.firebasedatabase.app';

  static final Random _random = Random.secure();
  static final RegExp _validCodePattern = RegExp(r'^[A-Z0-9]{6}$');

  String _peerId;
  DatabaseReference? _chatRef;
  String? _roomId;
  bool _isPaired = false;
  final EncryptionService _encryption = EncryptionService();

  /// Unique per-install/session peer identifier used as `senderId` and status key.
  String get peerId => _peerId;

  /// Alias for [peerId].
  String get myPeerId => _peerId;

  /// Whether this device has an active paired chat room.
  bool get isPaired => _isPaired && _roomId != null;

  FirebaseDatabase get _db => FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL: defaultDatabaseUrl,
  );

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

  Future<void> initialize() async {
    await Firebase.initializeApp();
    await loadSavedState();
  }

  File _stateFile() {
    final parentDir = Directory.systemTemp.parent;
    final filesDir = Directory('${parentDir.path}/files');
    if (filesDir.existsSync()) {
      return File('${filesDir.path}/secret_calc_state.json');
    }
    return File('${Directory.systemTemp.path}/secret_calc_state.json');
  }

  /// Loads persisted `peerId` and `pairedRoomId` from local storage if present.
  Future<void> loadSavedState() async {
    try {
      final file = _stateFile();
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
        final savedRoom = decoded['roomId'];
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

  Future<void> _saveState() async {
    try {
      final file = _stateFile();
      await file.writeAsString(
        jsonEncode({'peerId': _peerId, 'roomId': _isPaired ? _roomId : null}),
      );
    } catch (_) {
      // Ignore write failures in read-only or test environments.
    }
  }

  /// Marks the currently created room as paired and persists it.
  Future<void> markRoomPaired() async {
    if (_roomId == null) return;
    _isPaired = true;
    await _saveState();
  }

  /// Unpairs the current room so the user can pair with a new code.
  Future<void> leaveRoom() async {
    await updateOnlineStatus(false);
    _roomId = null;
    _chatRef = null;
    _isPaired = false;
    _encryption.resetKey();
    await _saveState();
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
    await _saveState();

    return true;
  }

  // Stream of room members so the creator knows when a partner joins.
  Stream<DatabaseEvent> getRoomMembersStream() {
    if (_roomId == null) {
      return const Stream.empty();
    }
    return _db.ref().child('rooms').child(_roomId!).child('members').onValue;
  }

  // Send a message
  Future<void> sendMessage(String text, {String? imageUrl}) async {
    if (_chatRef == null && _roomId != null && Firebase.apps.isNotEmpty) {
      _chatRef = _db.ref().child('rooms').child(_roomId!).child('messages');
    }
    if (_chatRef == null) return;

    final encryptedText = text.isNotEmpty ? _encryption.encrypt(text) : null;

    await _chatRef!.push().set({
      'text': encryptedText,
      'imageUrl': imageUrl,
      'timestamp': ServerValue.timestamp,
      'senderId': _peerId,
    });
  }

  // Listen for messages
  Stream<DatabaseEvent> getMessagesStream() {
    if (_chatRef == null && _roomId != null && Firebase.apps.isNotEmpty) {
      _chatRef = _db.ref().child('rooms').child(_roomId!).child('messages');
    }
    if (_chatRef == null) {
      return const Stream.empty();
    }
    return _chatRef!.orderByChild('timestamp').onValue;
  }

  // Upload image to Firebase Storage
  Future<String?> uploadImage(File imageFile) async {
    try {
      final roomSegment = _roomId ?? 'unassigned';
      final fileName =
          'images/$roomSegment/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final ref = FirebaseStorage.instance.ref().child(fileName);
      await ref.putFile(imageFile);
      return await ref.getDownloadURL();
    } catch (e) {
      return null;
    }
  }

  // Update online status keyed by this device's peerId.
  Future<void> updateOnlineStatus(bool isOnline) async {
    if (_roomId == null || Firebase.apps.isEmpty) return;

    final statusRef = _db
        .ref()
        .child('rooms')
        .child(_roomId!)
        .child('status')
        .child(_peerId);

    await statusRef.set({
      'isOnline': isOnline,
      'lastSeen': ServerValue.timestamp,
    });
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
