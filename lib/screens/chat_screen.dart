import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/encryption_service.dart';
import '../services/firebase_service.dart';
import '../services/native_bridge_service.dart';
import '../services/notification_service.dart';
import 'call_screen.dart';
import 'pairing_screen.dart';

class ChatThemePalette {
  final String name;
  final Color appBarColor;
  final Color backgroundColor;
  final List<Color> myBubbleGradient;
  final Color partnerBubbleColor;
  final Color accentColor;

  const ChatThemePalette({
    required this.name,
    required this.appBarColor,
    required this.backgroundColor,
    required this.myBubbleGradient,
    required this.partnerBubbleColor,
    required this.accentColor,
  });

  static const List<ChatThemePalette> presets = [
    ChatThemePalette(
      name: 'Midnight Purple',
      appBarColor: Color(0xFF2A1B4E),
      backgroundColor: Color(0xFF0F0B1A),
      myBubbleGradient: [Color(0xFF6A3DE8), Color(0xFF9B4DFF)],
      partnerBubbleColor: Color(0xFF231D33),
      accentColor: Color(0xFFB388FF),
    ),
    ChatThemePalette(
      name: 'Matrix Stealth',
      appBarColor: Color(0xFF0D2818),
      backgroundColor: Color(0xFF06110B),
      myBubbleGradient: [Color(0xFF058C42), Color(0xFF16DB65)],
      partnerBubbleColor: Color(0xFF132A1E),
      accentColor: Color(0xFF16DB65),
    ),
    ChatThemePalette(
      name: 'Ocean Abyss',
      appBarColor: Color(0xFF0B2545),
      backgroundColor: Color(0xFF061326),
      myBubbleGradient: [Color(0xFF134074), Color(0xFF00A8E8)],
      partnerBubbleColor: Color(0xFF152942),
      accentColor: Color(0xFF4EA8DE),
    ),
    ChatThemePalette(
      name: 'Crimson Rose',
      appBarColor: Color(0xFF3D0C1D),
      backgroundColor: Color(0xFF17050C),
      myBubbleGradient: [Color(0xFFC9184A), Color(0xFFFF4D6D)],
      partnerBubbleColor: Color(0xFF2E121D),
      accentColor: Color(0xFFFF758F),
    ),
    ChatThemePalette(
      name: 'AMOLED Black',
      appBarColor: Color(0xFF121212),
      backgroundColor: Color(0xFF000000),
      myBubbleGradient: [Color(0xFF2B2D42), Color(0xFF4A4E69)],
      partnerBubbleColor: Color(0xFF1A1A1A),
      accentColor: Color(0xFF8D99AE),
    ),
  ];
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  final Set<String> _seenMessageKeys = <String>{};
  final ImagePicker _picker = ImagePicker();
  final FirebaseService _firebase = FirebaseService();
  final EncryptionService _encryption = EncryptionService();
  final NotificationService _notifications = NotificationService();
  final NativeBridgeService _native = NativeBridgeService();

  StreamSubscription<DatabaseEvent>? _messagesSub;
  StreamSubscription<DatabaseEvent>? _statusSub;
  StreamSubscription<DatabaseEvent>? _callSub;
  Timer? _typingDebounce;
  Timer? _expiryTimer;
  Timer? _recordingTimer;

  bool _showEmojiPicker = false;
  bool _isSearching = false;
  String _searchQuery = '';
  bool _isPartnerOnline = false;
  bool _isPartnerTyping = false;
  String _partnerLastSeen = '';
  int _selectedThemeIndex = 0;
  int _selectedEmojiCategory = 0;
  int? _disappearingSeconds;
  ChatMessage? _replyingTo;

  bool _isRecordingVoice = false;
  int _recordingSeconds = 0;
  bool _micHeld = false;
  bool _micStarting = false;
  double? _micDownX;
  DateTime? _micDownAt;
  bool _micCancelArmed = false;
  String? _playingMessageId;
  bool _isShowingIncomingCall = false;

  static const List<String> _reactionOptions = [
    '❤️',
    '😂',
    '😮',
    '😢',
    '🔥',
    '👍',
    '🎉',
    '🙏',
  ];

  static const Map<String, List<String>> _emojiCategories = {
    'Smileys': [
      '😀',
      '😂',
      '🤣',
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
      '🤔',
    ],
    'Love': [
      '❤️',
      '💕',
      '💖',
      '💗',
      '💓',
      '💘',
      '💝',
      '💞',
      '💌',
      '🌹',
      '🫶',
      '💋',
      '🥺',
      '🫂',
      '✨',
      '🌙',
    ],
    'Hype': [
      '🔥',
      '⚡',
      '🌟',
      '💫',
      '🎉',
      '🎊',
      '🚀',
      '💯',
      '👑',
      '💎',
      '🎯',
      '🏆',
      '🎶',
      '🍕',
      '☕',
      '🍿',
    ],
    'Hands': [
      '👍',
      '👎',
      '👏',
      '🙌',
      '💪',
      '🤝',
      '🙏',
      '✌️',
      '🤞',
      '👌',
      '🫡',
      '👋',
      '🫶',
      '☝️',
      '✊',
      '🤙',
    ],
    'Secret': [
      '🤫',
      '🔒',
      '🗝️',
      '🕵️',
      '👀',
      '🕶️',
      '🛡️',
      '🧮',
      '📵',
      '⏳',
      '💣',
      '👻',
      '🥷',
      '🎭',
      '📡',
      '✅',
    ],
  };

  ChatThemePalette get _theme => ChatThemePalette.presets[_selectedThemeIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _firebase.updateOnlineStatus(true);
    _listenForMessages();
    _listenForPartnerStatus();
    _listenForIncomingCalls();
    _expiryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _pruneExpiredMessages();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _typingDebounce?.cancel();
    _expiryTimer?.cancel();
    _recordingTimer?.cancel();
    _messagesSub?.cancel();
    _statusSub?.cancel();
    _callSub?.cancel();
    _native.stopRecording();
    _native.stopAudio();
    _messageController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _firebase.updateOnlineStatus(false, isTyping: false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _firebase.updateOnlineStatus(true);
    } else {
      _firebase.updateOnlineStatus(false, isTyping: false);
    }
  }

  void _listenForIncomingCalls() {
    _callSub?.cancel();
    _callSub = _firebase.getCallStream().listen((event) {
      final raw = event.snapshot.value;
      if (raw == null || raw is! Map || !mounted) return;
      final callerId = raw['callerId']?.toString() ?? '';
      final status = raw['status']?.toString() ?? '';
      final isVideo = raw['type']?.toString() == 'video';

      if (status == 'ringing' &&
          callerId.isNotEmpty &&
          callerId != _firebase.myPeerId &&
          !_isShowingIncomingCall) {
        _isShowingIncomingCall = true;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                CallScreen(isVideo: isVideo, isIncoming: true),
          ),
        ).whenComplete(() {
          _isShowingIncomingCall = false;
        });
      }
    });
  }

  void _pruneExpiredMessages() {
    if (!mounted || _messages.isEmpty) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final expiredKeys = <String>[];
    for (final msg in _messages) {
      if (msg.expiresAtMs != null && msg.expiresAtMs! <= nowMs) {
        expiredKeys.add(msg.id);
      }
    }
    if (expiredKeys.isEmpty) return;
    for (final key in expiredKeys) {
      _firebase.deleteMessage(key);
    }
    setState(() {
      _messages.removeWhere(
        (m) => m.expiresAtMs != null && m.expiresAtMs! <= nowMs,
      );
    });
  }

  String? _safeDecrypt(Object? rawValue) {
    if (rawValue is! String || rawValue.isEmpty) return null;
    try {
      return _encryption.decrypt(rawValue);
    } on FormatException {
      return '[Unable to decrypt message]';
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

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final rebuilt = <ChatMessage>[];
      final unseenPartnerKeys = <String>[];
      var hasNewPartnerMessage = false;

      for (final entry in entries) {
        final message = entry.value;
        final expiresAt = message['expiresAt'] as int?;
        if (expiresAt != null && expiresAt <= nowMs) {
          _firebase.deleteMessage(entry.key);
          continue;
        }

        final senderId = message['senderId']?.toString() ?? '';
        final isMe = senderId == _firebase.myPeerId;
        final isSeen = (message['seen'] as bool?) ?? false;

        if (!isMe && !isSeen) {
          unseenPartnerKeys.add(entry.key);
        }

        final reactions = <String, String>{};
        final rawReactions = message['reactions'];
        if (rawReactions is Map) {
          rawReactions.forEach((peer, emoji) {
            if (emoji is String && emoji.isNotEmpty) {
              reactions[peer.toString()] = emoji;
            }
          });
        }

        final replySender = message['replyToSenderId']?.toString();

        rebuilt.add(
          ChatMessage(
            id: entry.key,
            text: _safeDecrypt(message['text']),
            imageUrl: message['imageUrl'] as String?,
            encryptedAudioData: message['audioData'] as String?,
            audioDurationSeconds: message['audioDuration'] as int?,
            isMe: isMe,
            isSeen: isSeen,
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              (message['timestamp'] as int?) ?? 0,
            ),
            replyToText: _safeDecrypt(message['replyToText']),
            replyToIsMe:
                replySender != null && replySender == _firebase.myPeerId,
            reactions: reactions,
            expiresAtMs: expiresAt,
          ),
        );

        final isNewKey = _seenMessageKeys.add(entry.key);
        if (isNewKey && !isMe) {
          hasNewPartnerMessage = true;
        }
      }

      if (unseenPartnerKeys.isNotEmpty) {
        _firebase.markMessagesSeen(unseenPartnerKeys);
      }

      if (!mounted) return;
      final previousCount = _messages.length;
      setState(() {
        _messages
          ..clear()
          ..addAll(rebuilt);
      });

      if (rebuilt.length > previousCount) {
        _scrollToBottom();
      }

      if (hasNewPartnerMessage) {
        _notifications.showFakeNotification();
      }
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
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
        _isPartnerTyping =
            _isPartnerOnline && ((partnerData['isTyping'] as bool?) ?? false);
        final rawLastSeen = partnerData['lastSeen'];
        if (rawLastSeen is int) {
          final lastSeen = DateTime.fromMillisecondsSinceEpoch(rawLastSeen);
          _partnerLastSeen =
              '${lastSeen.hour}:${lastSeen.minute.toString().padLeft(2, '0')}';
        }
      });
    });
  }

  void _onInputChanged(String value) {
    setState(() {});
    _firebase.updateTypingStatus(value.trim().isNotEmpty);
    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(seconds: 2), () {
      _firebase.updateTypingStatus(false);
    });
  }

  Future<void> _startVoiceRecording() async {
    try {
      await _startVoiceRecordingInner();
    } finally {
      _micStarting = false;
    }
  }

  Future<void> _startVoiceRecordingInner() async {
    final granted = await _native.ensureMicPermission();
    if (!granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission is required')),
      );
      return;
    }
    final path = await _native.startRecording();
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start voice recording')),
        );
      }
      return;
    }
    // The finger lifted (or the screen was disposed) while permission/start
    // was still resolving — e.g. the first-run permission dialog. Discard
    // instead of entering a stuck recording state with no pointer to release.
    if (!_micHeld || !mounted) {
      final stale = await _native.stopRecording();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Hold to record a voice note')),
        );
      }
      if (stale != null) {
        try {
          await File(stale).delete();
        } catch (_) {}
      }
      return;
    }
    setState(() {
      _isRecordingVoice = true;
      _recordingSeconds = 0;
      // Close the emoji panel so a second finger can't insert text mid-hold
      // and flip the mic slot's icon branch while the gesture is live.
      _showEmojiPicker = false;
    });
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordingSeconds++);
    });
  }

  void _onMicPointerDown(PointerDownEvent event) {
    if (_micHeld || _micStarting || _isRecordingVoice) return;
    // The Listener also wraps the send button; a pointer down while text is
    // typed belongs to the send tap, not to voice recording.
    if (_messageController.text.trim().isNotEmpty) return;
    _micHeld = true;
    _micDownX = event.localPosition.dx;
    _micDownAt = DateTime.now();
    _micCancelArmed = false;
    _micStarting = true;
    _startVoiceRecording();
  }

  void _onMicPointerMove(PointerMoveEvent event) {
    if (!_micHeld || _micDownX == null) return;
    final armed = event.localPosition.dx < _micDownX! - 80;
    if (armed != _micCancelArmed) {
      setState(() => _micCancelArmed = armed);
    }
  }

  void _onMicPointerUp(PointerUpEvent event) {
    if (!_micHeld) return;
    _micHeld = false;
    final heldFor = DateTime.now().difference(_micDownAt ?? DateTime.now());
    _micDownX = null;
    _micDownAt = null;
    if (!_isRecordingVoice) {
      // Start still in flight; _startVoiceRecording will discard the file
      // and show the hold hint once it resolves.
      return;
    }
    // Recording active: the mic slot can't have flipped to the send icon
    // mid-hold (_isRecordingVoice keeps hasTypedText out of the icon branch),
    // so unconditionally resolve the gesture here.
    if (_micCancelArmed) {
      _micCancelArmed = false;
      _cancelVoiceRecording();
    } else if (heldFor.inMilliseconds >= 600 || _recordingSeconds >= 1) {
      _finishAndSendVoiceRecording();
    } else {
      _cancelVoiceRecording();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Hold to record a voice note')),
        );
      }
    }
  }

  void _onMicPointerCancel(PointerCancelEvent event) {
    if (!_micHeld) return;
    _micHeld = false;
    _micDownX = null;
    _micDownAt = null;
    _micCancelArmed = false;
    if (!_isRecordingVoice) {
      return; // _startVoiceRecording will discard the stale start.
    }
    _cancelVoiceRecording();
  }

  Widget _buildRecordingIndicator() {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: _theme.backgroundColor,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.fiber_manual_record,
            color: Colors.redAccent,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _micCancelArmed
                  ? 'Release to cancel'
                  : 'Recording ${_recordingSeconds}s — release to send',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _cancelVoiceRecording() async {
    _recordingTimer?.cancel();
    // Reset the UI before the async native/file cleanup: dart:io futures
    // don't resolve under the test's fake-async zone, and the bar should
    // snap back instantly on cancel anyway.
    if (mounted) {
      setState(() {
        _isRecordingVoice = false;
        _recordingSeconds = 0;
        _micCancelArmed = false;
      });
    }
    final path = await _native.stopRecording();
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  Future<void> _finishAndSendVoiceRecording() async {
    _recordingTimer?.cancel();
    final duration = _recordingSeconds < 1 ? 1 : _recordingSeconds;
    final path = await _native.stopRecording();
    if (mounted) {
      setState(() {
        _isRecordingVoice = false;
        _recordingSeconds = 0;
      });
    }
    if (path == null) return;
    try {
      final file = File(path);
      if (!file.existsSync()) return;
      final bytes = await file.readAsBytes();
      await file.delete();
      if (bytes.isEmpty) return;
      await _sendMessage(
        text: '🎤 Voice note (${duration}s)',
        audioBase64: base64Encode(bytes),
        audioDurationSeconds: duration,
      );
    } catch (_) {}
  }

  Future<void> _togglePlayVoiceNote(ChatMessage message) async {
    if (message.encryptedAudioData == null) return;
    if (_playingMessageId == message.id) {
      await _native.stopAudio();
      if (!mounted) return;
      setState(() => _playingMessageId = null);
      return;
    }
    setState(() => _playingMessageId = message.id);
    final ok = await _native.playEncryptedAudio(
      message.encryptedAudioData!,
      _encryption,
    );
    if (!ok && mounted) {
      setState(() => _playingMessageId = null);
    }
  }

  Future<void> _sendMessage({
    String? text,
    File? image,
    String? audioBase64,
    int? audioDurationSeconds,
  }) async {
    if (text == null && image == null && audioBase64 == null) return;
    if (text != null &&
        text.trim().isEmpty &&
        image == null &&
        audioBase64 == null) {
      return;
    }

    final replyTarget = _replyingTo;
    setState(() {
      _replyingTo = null;
    });
    _typingDebounce?.cancel();
    _firebase.updateTypingStatus(false);

    String? imageUrl;
    if (image != null) {
      imageUrl = await _firebase.uploadImage(image);
    }

    await _firebase.sendMessage(
      text?.trim() ?? '',
      imageUrl: imageUrl,
      audioBase64: audioBase64,
      audioDurationSeconds: audioDurationSeconds,
      replyToText:
          replyTarget?.text ??
          (replyTarget?.imageUrl != null ? '📷 Photo' : null),
      replyToSenderId: replyTarget != null
          ? (replyTarget.isMe ? _firebase.myPeerId : 'partner')
          : null,
      expiresInSeconds: _disappearingSeconds,
    );
    _messageController.clear();
    if (mounted) setState(() {});
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
      backgroundColor: _theme.appBarColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.photo_library, color: _theme.accentColor),
              title: const Text('Send Photo from Gallery'),
              onTap: () {
                Navigator.pop(context);
                _pickImage();
              },
            ),
            ListTile(
              leading: Icon(Icons.camera_alt, color: _theme.accentColor),
              title: const Text('Take Photo with Camera'),
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
      backgroundColor: _theme.appBarColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.call, color: Colors.greenAccent),
              title: const Text('Start Encrypted Voice Call'),
              subtitle: const Text('Live P2P encrypted voice stream'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const CallScreen(isVideo: false),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.videocam,
                color: Colors.lightBlueAccent,
              ),
              title: const Text('Start Encrypted Video Call'),
              subtitle: const Text('Live P2P video & encrypted audio call'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const CallScreen(isVideo: true),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showSecuritySettingsDialog() {
    final codeCtrl = TextEditingController(text: _firebase.customPasscode);
    var bioEnabled = _firebase.biometricEnabled;
    String? localError;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: _theme.appBarColor,
          title: const Row(
            children: [
              Icon(Icons.fingerprint, color: Colors.greenAccent),
              SizedBox(width: 8),
              Flexible(child: Text('Passcode & Biometric Lock')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Custom Secret Calculator Code (4–8 digits):',
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: codeCtrl,
                keyboardType: TextInputType.number,
                maxLength: 8,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  letterSpacing: 4,
                  fontWeight: FontWeight.bold,
                ),
                decoration: InputDecoration(
                  hintText: '1997',
                  filled: true,
                  fillColor: _theme.backgroundColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  errorText: localError,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fingerprint / Screen Lock'),
                subtitle: const Text(
                  'Ask for device fingerprint before opening Secret Chat',
                  style: TextStyle(fontSize: 12),
                ),
                value: bioEnabled,
                onChanged: (val) {
                  setDialogState(() => bioEnabled = val);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('CANCEL'),
            ),
            ElevatedButton(
              onPressed: () async {
                final ok = await _firebase.setCustomPasscode(codeCtrl.text);
                if (!ok) {
                  setDialogState(() {
                    localError = 'Enter 4 to 8 digits (0-9)';
                  });
                  return;
                }
                await _firebase.setBiometricEnabled(bioEnabled);
                if (!dialogContext.mounted) return;
                Navigator.pop(dialogContext);
                if (!mounted) return;
                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Saved! Passcode: ${_firebase.customPasscode} • Biometric: ${bioEnabled ? "ON" : "OFF"}',
                    ),
                  ),
                );
              },
              child: const Text('SAVE'),
            ),
          ],
        ),
      ),
    );
  }

  void _showMessageActions(ChatMessage message) {
    final myCurrentReaction = message.reactions[_firebase.myPeerId];
    showModalBottomSheet(
      context: context,
      backgroundColor: _theme.appBarColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: _reactionOptions.map((emoji) {
                    final isSelected = myCurrentReaction == emoji;
                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _firebase.toggleReaction(
                          message.id,
                          emoji,
                          currentReaction: myCurrentReaction,
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? _theme.accentColor.withValues(alpha: 0.3)
                              : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 26),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const Divider(height: 16),
              ListTile(
                leading: const Icon(Icons.reply, color: Colors.white),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  setState(() {
                    _replyingTo = message;
                  });
                },
              ),
              if (message.text != null && message.text!.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.copy, color: Colors.white),
                  title: const Text('Copy Text'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Clipboard.setData(ClipboardData(text: message.text!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Message copied to clipboard'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: Colors.redAccent,
                ),
                title: const Text(
                  'Delete for Everyone',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _firebase.deleteMessage(message.id);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showThemePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _theme.appBarColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose Chat Theme',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              ...List.generate(ChatThemePalette.presets.length, (index) {
                final item = ChatThemePalette.presets[index];
                final isSelected = index == _selectedThemeIndex;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: item.myBubbleGradient.first,
                    child: isSelected
                        ? const Icon(Icons.check, color: Colors.white)
                        : null,
                  ),
                  title: Text(item.name),
                  onTap: () {
                    setState(() {
                      _selectedThemeIndex = index;
                    });
                    Navigator.pop(sheetContext);
                  },
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  void _showDisappearingOptions() {
    const options = <MapEntry<String, int?>>[
      MapEntry('Off (Keep messages)', null),
      MapEntry('30 seconds', 30),
      MapEntry('5 minutes', 300),
      MapEntry('1 hour', 3600),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: _theme.appBarColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.timer_outlined, color: Colors.orangeAccent),
                  SizedBox(width: 8),
                  Text(
                    'Disappearing Messages Timer',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...options.map((opt) {
                final selected = _disappearingSeconds == opt.value;
                return ListTile(
                  leading: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: _theme.accentColor,
                  ),
                  title: Text(opt.key),
                  onTap: () {
                    setState(() {
                      _disappearingSeconds = opt.value;
                    });
                    Navigator.pop(sheetContext);
                  },
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  void _showRoomInfoDialog() {
    final code = _firebase.getShortCode();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _theme.appBarColor,
        title: const Row(
          children: [
            Icon(Icons.verified_user, color: Colors.greenAccent),
            SizedBox(width: 8),
            Text('Secret Room Info'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Room Pair Code:',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  code.isEmpty ? 'UNPAIRED' : code,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                    color: Colors.greenAccent,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  tooltip: 'Copy Code',
                  onPressed: code.isEmpty
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: code));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Room code copied!'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Encryption: AES-256-GCM (Per-message random nonce)',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 6),
            Text(
              'Partner Status: ${_isPartnerOnline ? "Online now" : (_partnerLastSeen.isEmpty ? "Offline" : "Last seen $_partnerLastSeen")}',
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('CLOSE'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearChat() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _theme.appBarColor,
        title: const Text('Clear Secret Chat?'),
        content: const Text(
          'This will permanently delete all messages in this room for both phones.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              'CLEAR ALL',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _firebase.clearAllMessages();
    }
  }

  void _openFullScreenImage(String imageUrl) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: const Text('Encrypted Photo'),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 4.0,
              child: Image.network(imageUrl),
            ),
          ),
        ),
      ),
    );
  }

  List<ChatMessage> get _filteredMessages {
    if (_searchQuery.trim().isEmpty) return _messages;
    final query = _searchQuery.trim().toLowerCase();
    return _messages
        .where((m) => (m.text ?? '').toLowerCase().contains(query))
        .toList();
  }

  String _statusSubtitle() {
    if (_isPartnerTyping) return 'typing...';
    if (_isPartnerOnline) return 'Online • AES-256';
    if (_partnerLastSeen.isNotEmpty) return 'Last seen $_partnerLastSeen';
    return 'Encrypted Room ${_firebase.getShortCode()}';
  }

  @override
  Widget build(BuildContext context) {
    final displayedMessages = _filteredMessages;
    final emojiCategoryKeys = _emojiCategories.keys.toList();
    final currentEmojis =
        _emojiCategories[emojiCategoryKeys[_selectedEmojiCategory]]!;
    final hasTypedText = _messageController.text.trim().isNotEmpty;

    return Scaffold(
      backgroundColor: _theme.backgroundColor,
      appBar: AppBar(
        backgroundColor: _theme.appBarColor,
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Search secret messages...',
                  hintStyle: TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                ),
                onChanged: (value) => setState(() => _searchQuery = value),
              )
            : Row(
                children: [
                  Stack(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: _theme.myBubbleGradient.first,
                        child: const Icon(
                          Icons.lock_person,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: _isPartnerOnline
                                ? Colors.greenAccent
                                : Colors.grey,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _theme.appBarColor,
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Flexible(
                              child: Text(
                                'Secret Chat',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (_disappearingSeconds != null) ...[
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.timer,
                                size: 14,
                                color: Colors.orangeAccent,
                              ),
                            ],
                          ],
                        ),
                        Text(
                          _statusSubtitle(),
                          style: TextStyle(
                            fontSize: 12,
                            fontStyle: _isPartnerTyping
                                ? FontStyle.italic
                                : FontStyle.normal,
                            color: _isPartnerTyping
                                ? Colors.amberAccent
                                : (_isPartnerOnline
                                      ? Colors.greenAccent
                                      : Colors.grey[400]),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
        actions: [
          IconButton(
            icon: const Icon(Icons.calculate_outlined),
            tooltip: 'Quick Hide to Calculator',
            onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
          ),
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            tooltip: 'Search Messages',
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchQuery = '';
                  _searchController.clear();
                }
              });
            },
          ),
          IconButton(icon: const Icon(Icons.call), onPressed: _showCallOptions),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: _theme.appBarColor,
            onSelected: (value) async {
              switch (value) {
                case 'room_info':
                  _showRoomInfoDialog();
                  break;
                case 'security':
                  _showSecuritySettingsDialog();
                  break;
                case 'theme':
                  _showThemePicker();
                  break;
                case 'disappearing':
                  _showDisappearingOptions();
                  break;
                case 'clear':
                  await _confirmClearChat();
                  break;
                case 're_pair':
                  await _firebase.leaveRoom();
                  if (!context.mounted) return;
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const PairingScreen(),
                    ),
                  );
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'room_info',
                child: Row(
                  children: [
                    Icon(Icons.vpn_key, size: 18, color: _theme.accentColor),
                    const SizedBox(width: 10),
                    Text('Room: ${_firebase.getShortCode()}'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'security',
                child: Row(
                  children: [
                    const Icon(
                      Icons.fingerprint,
                      size: 18,
                      color: Colors.greenAccent,
                    ),
                    const SizedBox(width: 10),
                    Text('Passcode (${_firebase.customPasscode}) & Bio Lock'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'theme',
                child: Row(
                  children: [
                    Icon(Icons.palette, size: 18, color: _theme.accentColor),
                    const SizedBox(width: 10),
                    const Text('Chat Theme'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'disappearing',
                child: Row(
                  children: [
                    const Icon(
                      Icons.timer_outlined,
                      size: 18,
                      color: Colors.orangeAccent,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _disappearingSeconds == null
                          ? 'Disappearing: Off'
                          : 'Disappearing: ${_disappearingSeconds}s',
                    ),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(
                      Icons.cleaning_services_outlined,
                      size: 18,
                      color: Colors.amberAccent,
                    ),
                    SizedBox(width: 10),
                    Text('Clear Chat History'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 're_pair',
                child: Row(
                  children: [
                    Icon(Icons.link_off, size: 18, color: Colors.redAccent),
                    SizedBox(width: 10),
                    Text('Pair New Device'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: _theme.appBarColor.withValues(alpha: 0.55),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 13,
                  color: _theme.accentColor,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'AES-256-GCM encrypted • Tap mic for voice note • Long-press to react/reply',
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: displayedMessages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: _theme.appBarColor,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.lock_outline,
                            size: 48,
                            color: _theme.accentColor,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _searchQuery.isNotEmpty
                              ? 'No matching messages found'
                              : 'Start a secret conversation',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w500,
                            color: Colors.grey[400],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Messages, voice notes & calls are AES-256-GCM encrypted',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    itemCount: displayedMessages.length,
                    itemBuilder: (context, index) {
                      final message = displayedMessages[index];
                      final prevMessage = index > 0
                          ? displayedMessages[index - 1]
                          : null;
                      final showDateHeader =
                          prevMessage == null ||
                          !_isSameDay(prevMessage.timestamp, message.timestamp);
                      return Column(
                        children: [
                          if (showDateHeader)
                            _buildDateSeparator(message.timestamp),
                          _buildMessageBubble(message),
                        ],
                      );
                    },
                  ),
          ),
          if (_showEmojiPicker)
            Container(
              height: 230,
              color: _theme.appBarColor,
              child: Column(
                children: [
                  SizedBox(
                    height: 40,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: emojiCategoryKeys.length,
                      itemBuilder: (context, idx) {
                        final selected = idx == _selectedEmojiCategory;
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                          child: ChoiceChip(
                            label: Text(emojiCategoryKeys[idx]),
                            selected: selected,
                            selectedColor: _theme.accentColor.withValues(
                              alpha: 0.3,
                            ),
                            onSelected: (_) {
                              setState(() => _selectedEmojiCategory = idx);
                            },
                          ),
                        );
                      },
                    ),
                  ),
                  Expanded(
                    child: GridView.builder(
                      padding: const EdgeInsets.all(8),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 8,
                            childAspectRatio: 1,
                          ),
                      itemCount: currentEmojis.length,
                      itemBuilder: (context, index) {
                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              _messageController.text += currentEmojis[index];
                              _messageController.selection =
                                  TextSelection.fromPosition(
                                    TextPosition(
                                      offset: _messageController.text.length,
                                    ),
                                  );
                            });
                          },
                          child: Center(
                            child: Text(
                              currentEmojis[index],
                              style: const TextStyle(fontSize: 24),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          if (_replyingTo != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: _theme.appBarColor,
                border: Border(
                  left: BorderSide(color: _theme.accentColor, width: 4),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.reply, size: 18, color: _theme.accentColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _replyingTo!.isMe
                              ? 'Replying to yourself'
                              : 'Replying to Partner',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: _theme.accentColor,
                          ),
                        ),
                        Text(
                          _replyingTo!.text ?? '📷 Photo',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _replyingTo = null),
                  ),
                ],
              ),
            ),
          // Input bar: one stable Row — children never swap out mid-hold, so
          // the mic Listener always receives the matching pointer-up/cancel.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            color: _theme.appBarColor,
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      _showEmojiPicker
                          ? Icons.keyboard
                          : Icons.emoji_emotions_outlined,
                      color: _theme.accentColor,
                    ),
                    onPressed: _isRecordingVoice
                        ? null
                        : () {
                            setState(() {
                              _showEmojiPicker = !_showEmojiPicker;
                            });
                          },
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.add_photo_alternate_outlined,
                      color: _theme.accentColor,
                    ),
                    onPressed: _isRecordingVoice ? null : _showImageOptions,
                  ),
                  Expanded(
                    child: _isRecordingVoice
                        ? _buildRecordingIndicator()
                        : TextField(
                            controller: _messageController,
                            onChanged: _onInputChanged,
                            decoration: InputDecoration(
                              hintText: _disappearingSeconds == null
                                  ? 'Type a secret message...'
                                  : 'Disappearing message (${_disappearingSeconds}s)...',
                              hintStyle: TextStyle(color: Colors.grey[500]),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                              filled: true,
                              fillColor: _theme.backgroundColor,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 10,
                              ),
                            ),
                            style: const TextStyle(color: Colors.white),
                            onSubmitted: (text) => _sendMessage(text: text),
                          ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: _theme.myBubbleGradient),
                      shape: BoxShape.circle,
                    ),
                    // The Listener never unmounts across text/recording
                    // state changes, so a held pointer always gets its
                    // matching pointer-up or pointercancel event.
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _onMicPointerDown,
                      onPointerMove: _onMicPointerMove,
                      onPointerUp: _onMicPointerUp,
                      onPointerCancel: _onMicPointerCancel,
                      child: IconButton(
                        // No tooltip while held: Tooltip triggers on
                        // long-press and would pop mid-recording.
                        tooltip: hasTypedText
                            ? 'Send Message'
                            : _isRecordingVoice
                            ? null
                            : 'Hold to Record Voice Note',
                        icon: Icon(
                          hasTypedText
                              ? Icons.send_rounded
                              : _micCancelArmed
                              ? Icons.delete_outline
                              : Icons.mic,
                          color: _micCancelArmed && !hasTypedText
                              ? Colors.redAccent
                              : Colors.white,
                        ),
                        onPressed: hasTypedText
                            ? () => _sendMessage(text: _messageController.text)
                            : () {},
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Widget _buildDateSeparator(DateTime date) {
    final now = DateTime.now();
    String label;
    if (_isSameDay(date, now)) {
      label = 'Today';
    } else if (_isSameDay(date, now.subtract(const Duration(days: 1)))) {
      label = 'Yesterday';
    } else {
      label =
          '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: _theme.appBarColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 11, color: Colors.grey[400]),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    final uniqueReactions = message.reactions.values.toSet().toList();
    final isPlayingVoice = _playingMessageId == message.id;

    return GestureDetector(
      onLongPress: () => _showMessageActions(message),
      onHorizontalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0).abs() > 150) {
          setState(() => _replyingTo = message);
        }
      },
      child: Align(
        alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: message.isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.76,
              ),
              decoration: BoxDecoration(
                gradient: message.isMe
                    ? LinearGradient(
                        colors: _theme.myBubbleGradient,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
                color: message.isMe ? null : _theme.partnerBubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(message.isMe ? 18 : 4),
                  bottomRight: Radius.circular(message.isMe ? 4 : 18),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.replyToText != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                        border: Border(
                          left: BorderSide(color: _theme.accentColor, width: 3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            message.replyToIsMe ? 'You' : 'Partner',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: _theme.accentColor,
                            ),
                          ),
                          Text(
                            message.replyToText!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (message.imageUrl != null)
                    GestureDetector(
                      onTap: () => _openFullScreenImage(message.imageUrl!),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            message.imageUrl!,
                            width: 220,
                            height: 220,
                            fit: BoxFit.cover,
                            loadingBuilder: (context, child, loadingProgress) {
                              if (loadingProgress == null) return child;
                              return Container(
                                width: 220,
                                height: 220,
                                color: Colors.grey[850],
                                child: Center(
                                  child: CircularProgressIndicator(
                                    value:
                                        loadingProgress.expectedTotalBytes !=
                                            null
                                        ? loadingProgress
                                                  .cumulativeBytesLoaded /
                                              loadingProgress
                                                  .expectedTotalBytes!
                                        : null,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  if (message.encryptedAudioData != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InkWell(
                            onTap: () => _togglePlayVoiceNote(message),
                            child: CircleAvatar(
                              radius: 16,
                              backgroundColor: Colors.white24,
                              child: Icon(
                                isPlayingVoice ? Icons.stop : Icons.play_arrow,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            isPlayingVoice
                                ? 'Playing encrypted audio...'
                                : 'Voice Note (${message.audioDurationSeconds ?? 1}s)',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (message.text != null && message.text!.isNotEmpty)
                    Text(
                      message.text!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15.5,
                        height: 1.3,
                      ),
                    ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.expiresAtMs != null) ...[
                        const Icon(
                          Icons.timer_outlined,
                          size: 11,
                          color: Colors.orangeAccent,
                        ),
                        const SizedBox(width: 3),
                      ],
                      Text(
                        '${message.timestamp.hour}:${message.timestamp.minute.toString().padLeft(2, '0')}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                        ),
                      ),
                      if (message.isMe) ...[
                        const SizedBox(width: 4),
                        Icon(
                          message.isSeen ? Icons.done_all : Icons.check,
                          size: 14,
                          color: message.isSeen
                              ? Colors.lightGreenAccent
                              : Colors.white70,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (uniqueReactions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 6, right: 6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _theme.appBarColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _theme.accentColor.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    '${uniqueReactions.join(' ')} ${message.reactions.length > 1 ? message.reactions.length : ''}'
                        .trim(),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ChatMessage {
  final String id;
  final String? text;
  final String? imageUrl;
  final String? encryptedAudioData;
  final int? audioDurationSeconds;
  final bool isMe;
  final bool isSeen;
  final DateTime timestamp;
  final String? replyToText;
  final bool replyToIsMe;
  final Map<String, String> reactions;
  final int? expiresAtMs;

  ChatMessage({
    required this.id,
    this.text,
    this.imageUrl,
    this.encryptedAudioData,
    this.audioDurationSeconds,
    required this.isMe,
    this.isSeen = false,
    required this.timestamp,
    this.replyToText,
    this.replyToIsMe = false,
    this.reactions = const <String, String>{},
    this.expiresAtMs,
  });
}
