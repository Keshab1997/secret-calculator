import 'dart:async';
import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/encryption_service.dart';
import '../services/firebase_service.dart';
import '../services/notification_service.dart';
import 'pairing_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _messageController = TextEditingController();
  final List<ChatMessage> _messages = [];
  final Set<String> _seenMessageKeys = <String>{};
  final ImagePicker _picker = ImagePicker();
  final FirebaseService _firebase = FirebaseService();
  final EncryptionService _encryption = EncryptionService();
  final NotificationService _notifications = NotificationService();
  StreamSubscription<DatabaseEvent>? _messagesSub;
  StreamSubscription<DatabaseEvent>? _statusSub;
  bool _showEmojiPicker = false;
  bool _isPartnerOnline = false;
  String _partnerLastSeen = '';

  final List<String> _emojis = [
    '😀',
    '😂',
    '😍',
    '🥰',
    '😘',
    '😊',
    '😉',
    '😎',
    '🤩',
    '🥳',
    '😋',
    '🤪',
    '😜',
    '🤗',
    '❤️',
    '💕',
    '💖',
    '💗',
    '💝',
    '🔥',
    '✨',
    '🌟',
    '💫',
    '🎉',
    '🎊',
    '👏',
    '🙌',
    '💪',
    '👍',
    '👎',
    '🤝',
    '🙏',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _firebase.updateOnlineStatus(true);
    _listenForMessages();
    _listenForPartnerStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messagesSub?.cancel();
    _statusSub?.cancel();
    _messageController.dispose();
    _firebase.updateOnlineStatus(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _firebase.updateOnlineStatus(true);
    } else {
      _firebase.updateOnlineStatus(false);
    }
  }

  void _listenForMessages() {
    _messagesSub?.cancel();
    _messagesSub = _firebase.getMessagesStream().listen((event) {
      final raw = event.snapshot.value;
      if (raw == null || raw is! Map) {
        if (!mounted) return;
        setState(_messages.clear);
        return;
      }

      final entries = <MapEntry<String, Map<dynamic, dynamic>>>[];
      raw.forEach((key, value) {
        if (value is Map) {
          entries.add(MapEntry(key.toString(), value));
        }
      });

      entries.sort((a, b) {
        final tsA = (a.value['timestamp'] as int?) ?? 0;
        final tsB = (b.value['timestamp'] as int?) ?? 0;
        return tsA.compareTo(tsB);
      });

      final rebuilt = <ChatMessage>[];
      var hasNewPartnerMessage = false;

      for (final entry in entries) {
        final message = entry.value;
        final senderId = message['senderId']?.toString() ?? '';
        final isMe = senderId == _firebase.myPeerId;

        String? decryptedText;
        final rawText = message['text'];
        if (rawText is String && rawText.isNotEmpty) {
          try {
            decryptedText = _encryption.decrypt(rawText);
          } on FormatException {
            decryptedText = '[Unable to decrypt message]';
          }
        }

        rebuilt.add(
          ChatMessage(
            text: decryptedText,
            imageUrl: message['imageUrl'] as String?,
            isMe: isMe,
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              (message['timestamp'] as int?) ?? 0,
            ),
          ),
        );

        final isNewKey = _seenMessageKeys.add(entry.key);
        if (isNewKey && !isMe) {
          hasNewPartnerMessage = true;
        }
      }

      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(rebuilt);
      });

      if (hasNewPartnerMessage) {
        _notifications.showFakeNotification();
      }
    });
  }

  void _listenForPartnerStatus() {
    _statusSub?.cancel();
    _statusSub = _firebase.getPartnerStatusStream().listen((event) {
      final raw = event.snapshot.value;
      if (raw == null || raw is! Map) return;

      Map<dynamic, dynamic>? partnerData;
      if (raw.containsKey('isOnline') || raw.containsKey('lastSeen')) {
        partnerData = raw;
      } else {
        for (final entry in raw.entries) {
          if (entry.key.toString() != _firebase.myPeerId &&
              entry.value is Map) {
            partnerData = entry.value as Map<dynamic, dynamic>;
            break;
          }
        }
      }

      if (partnerData == null || !mounted) return;

      setState(() {
        _isPartnerOnline = (partnerData!['isOnline'] as bool?) ?? false;
        final rawLastSeen = partnerData['lastSeen'];
        if (rawLastSeen is int) {
          final lastSeen = DateTime.fromMillisecondsSinceEpoch(rawLastSeen);
          _partnerLastSeen =
              '${lastSeen.hour}:${lastSeen.minute.toString().padLeft(2, '0')}';
        }
      });
    });
  }

  Future<void> _sendMessage({String? text, File? image}) async {
    if (text == null && image == null) return;
    if (text != null && text.trim().isEmpty && image == null) return;

    String? imageUrl;
    if (image != null) {
      imageUrl = await _firebase.uploadImage(image);
    }

    await _firebase.sendMessage(text ?? '', imageUrl: imageUrl);
    _messageController.clear();
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      await _sendMessage(image: File(image.path));
    }
  }

  Future<void> _takePhoto() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.camera);
    if (image != null) {
      await _sendMessage(image: File(image.path));
    }
  }

  void _showImageOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Gallery'),
              onTap: () {
                Navigator.pop(context);
                _pickImage();
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Camera'),
              onTap: () {
                Navigator.pop(context);
                _takePhoto();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showCallOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.call, color: Colors.green),
              title: const Text('Voice Call'),
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Voice call feature coming soon!'),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: Colors.blue),
              title: const Text('Video Call'),
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Video call feature coming soon!'),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const CircleAvatar(
              backgroundColor: Colors.pink,
              child: Icon(Icons.person, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Secret Chat', style: TextStyle(fontSize: 16)),
                Text(
                  _isPartnerOnline ? 'Online' : 'Last seen $_partnerLastSeen',
                  style: TextStyle(
                    fontSize: 12,
                    color: _isPartnerOnline ? Colors.green : Colors.grey,
                  ),
                ),
              ],
            ),
          ],
        ),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.call), onPressed: _showCallOptions),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              if (value == 're_pair') {
                await _firebase.leaveRoom();
                if (!context.mounted) return;
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const PairingScreen(),
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                enabled: false,
                child: Text('Room: ${_firebase.getShortCode()}'),
              ),
              const PopupMenuItem<String>(
                value: 're_pair',
                child: Text('Pair New Device'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Messages
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.lock_outline,
                          size: 64,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Start a secret conversation',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      return _buildMessageBubble(message);
                    },
                  ),
          ),
          // Emoji Picker
          if (_showEmojiPicker)
            Container(
              height: 200,
              color: Colors.grey[900],
              child: GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 8,
                  childAspectRatio: 1,
                ),
                itemCount: _emojis.length,
                itemBuilder: (context, index) {
                  return GestureDetector(
                    onTap: () {
                      _messageController.text += _emojis[index];
                      setState(() {
                        _showEmojiPicker = false;
                      });
                    },
                    child: Center(
                      child: Text(
                        _emojis[index],
                        style: const TextStyle(fontSize: 24),
                      ),
                    ),
                  );
                },
              ),
            ),
          // Input
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.grey[900],
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    _showEmojiPicker ? Icons.keyboard : Icons.emoji_emotions,
                    color: Colors.grey[400],
                  ),
                  onPressed: () {
                    setState(() {
                      _showEmojiPicker = !_showEmojiPicker;
                    });
                  },
                ),
                IconButton(
                  icon: Icon(Icons.attach_file, color: Colors.grey[400]),
                  onPressed: _showImageOptions,
                ),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      hintStyle: TextStyle(color: Colors.grey[500]),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Colors.grey[800],
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                    ),
                    style: const TextStyle(color: Colors.white),
                    onSubmitted: (text) => _sendMessage(text: text),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: Colors.deepPurple,
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white),
                    onPressed: () =>
                        _sendMessage(text: _messageController.text),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    return Align(
      alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: message.isMe ? Colors.deepPurple : Colors.grey[800],
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (message.imageUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  message.imageUrl!,
                  width: 200,
                  height: 200,
                  fit: BoxFit.cover,
                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) return child;
                    return Container(
                      width: 200,
                      height: 200,
                      color: Colors.grey[800],
                      child: Center(
                        child: CircularProgressIndicator(
                          value: loadingProgress.expectedTotalBytes != null
                              ? loadingProgress.cumulativeBytesLoaded /
                                    loadingProgress.expectedTotalBytes!
                              : null,
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (message.text != null)
              Text(
                message.text!,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            const SizedBox(height: 4),
            Text(
              '${message.timestamp.hour}:${message.timestamp.minute.toString().padLeft(2, '0')}',
              style: TextStyle(color: Colors.grey[400], fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

class ChatMessage {
  final String? text;
  final String? imageUrl;
  final bool isMe;
  final DateTime timestamp;

  ChatMessage({
    this.text,
    this.imageUrl,
    required this.isMe,
    required this.timestamp,
  });
}
