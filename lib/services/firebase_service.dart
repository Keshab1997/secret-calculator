import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database.dart';
import 'package:firebase_storage.dart';
import 'dart:io';
import 'encryption_service.dart';

class FirebaseService {
  static final FirebaseService _instance = FirebaseService._internal();
  factory FirebaseService() => _instance;
  FirebaseService._internal();

  DatabaseReference? _chatRef;
  String? _roomId;
  final EncryptionService _encryption = EncryptionService();

  Future<void> initialize() async {
    await Firebase.initializeApp();
  }

  // Create a room and return the room code
  Future<String> createRoom() async {
    final roomRef = FirebaseDatabase.instance.ref().child('rooms').push();
    _roomId = roomRef.key;
    
    await roomRef.set({
      'createdAt': ServerValue.timestamp,
      'members': [],
    });
    
    _chatRef = roomRef.child('messages');
    return _roomId!;
  }

  // Join a room with code
  Future<bool> joinRoom(String roomCode) async {
    final roomRef = FirebaseDatabase.instance.ref().child('rooms').child(roomCode);
    final snapshot = await roomRef.get();
    
    if (snapshot.exists) {
      _roomId = roomCode;
      _chatRef = roomRef.child('messages');
      
      // Add user to members
      await roomRef.child('members').push().set({
        'joinedAt': ServerValue.timestamp,
      });
      
      return true;
    }
    return false;
  }

  // Send a message
  Future<void> sendMessage(String text, {String? imageUrl}) async {
    if (_chatRef == null) return;
    
    // Encrypt the message
    final encryptedText = _encryption.encrypt(text);
    
    await _chatRef!.push().set({
      'text': encryptedText,
      'imageUrl': imageUrl,
      'timestamp': ServerValue.timestamp,
      'senderId': _roomId,
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
      final fileName = 'images/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final ref = FirebaseStorage.instance.ref().child(fileName);
      await ref.putFile(imageFile);
      return await ref.getDownloadURL();
    } catch (e) {
      return null;
    }
  }

  // Update online status
  Future<void> updateOnlineStatus(bool isOnline) async {
    if (_roomId == null) return;
    
    final statusRef = FirebaseDatabase.instance
        .ref()
        .child('rooms')
        .child(_roomId!)
        .child('status');
    
    await statusRef.set({
      'isOnline': isOnline,
      'lastSeen': ServerValue.timestamp,
    });
  }

  // Listen for partner's online status
  Stream<DatabaseEvent> getPartnerStatusStream() {
    if (_roomId == null) {
      return const Stream.empty();
    }
    return FirebaseDatabase.instance
        .ref()
        .child('rooms')
        .child(_roomId!)
        .child('status')
        .onValue;
  }

  // Generate a short room code (first 6 chars of roomId)
  String getShortCode() {
    if (_roomId == null) return '';
    return _roomId!.substring(0, 6).toUpperCase();
  }
}