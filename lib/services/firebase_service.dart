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
  static final Random _random = Random.secure();
  static final RegExp _validCodePattern = RegExp(r'^[A-Z0-9]{6}$');

  final String _peerId;
  DatabaseReference? _chatRef;
  String? _roomId;
  final EncryptionService _encryption = EncryptionService();

  /// Unique per-install/session peer identifier used as `senderId` and status key.
  String get peerId => _peerId;

  /// Alias for [peerId].
  String get myPeerId => _peerId;

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
  }

  // Create a room and return the 6-character room code.
  Future<String> createRoom() async {
    final code = generateRoomCode();
    final roomRef = FirebaseDatabase.instance.ref().child('rooms').child(code);

    await roomRef.set({
      'createdAt': ServerValue.timestamp,
      'createdBy': _peerId,
      'members': {
        _peerId: {'joinedAt': ServerValue.timestamp},
      },
    });

    _roomId = code;
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

    final roomRef = FirebaseDatabase.instance
        .ref()
        .child('rooms')
        .child(normalized);
    final snapshot = await roomRef.get();

    if (!snapshot.exists) {
      _roomId = null;
      _chatRef = null;
      return false;
    }

    _roomId = normalized;
    _encryption.setRoomKey(normalized);
    _chatRef = roomRef.child('messages');

    await roomRef.child('members').child(_peerId).set({
      'joinedAt': ServerValue.timestamp,
    });

    return true;
  }

  // Stream of room members so the creator knows when a partner joins.
  Stream<DatabaseEvent> getRoomMembersStream() {
    if (_roomId == null) {
      return const Stream.empty();
    }
    return FirebaseDatabase.instance
        .ref()
        .child('rooms')
        .child(_roomId!)
        .child('members')
        .onValue;
  }

  // Send a message
  Future<void> sendMessage(String text, {String? imageUrl}) async {
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
    if (_roomId == null) return;

    final statusRef = FirebaseDatabase.instance
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
    if (_roomId == null) {
      return const Stream.empty();
    }
    final statusRef = FirebaseDatabase.instance
        .ref()
        .child('rooms')
        .child(_roomId!)
        .child('status');
    if (partnerPeerId != null && partnerPeerId.isNotEmpty) {
      return statusRef.child(partnerPeerId).onValue;
    }
    return statusRef.onValue;
  }

  // Current 6-character room code.
  String getShortCode() => _roomId ?? '';

  @visibleForTesting
  void setRoomIdForTesting(String? code) {
    _roomId = code?.trim().toUpperCase();
  }
}
