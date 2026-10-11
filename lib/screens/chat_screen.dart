import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/encryption_service.dart';
import '../services/firebase_service.dart';
import '../services/media_cache_service.dart';
import '../services/native_bridge_service.dart';
import '../services/notification_service.dart';
import '../widgets/emoji_keyboard.dart';
import '../widgets/sticker_keyboard.dart';
import '../widgets/messaging_style.dart';
import '../widgets/sticker_art.dart';
import 'call_screen.dart';

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
      name: 'Classic Green',
      appBarColor: Colors.white,
      backgroundColor: Color(0xFFF5F1E8),
      myBubbleGradient: [Color(0xFFD9FDD3), Color(0xFFD9FDD3)],
      partnerBubbleColor: Colors.white,
      accentColor: Color(0xFF168B53),
    ),
  ];
}

class ChatScreen extends StatefulWidget {
  @visibleForTesting
  final List<ChatMessage> initialMessages;
  final String contactName;
  final String? contactPhoto;
  const ChatScreen({
    super.key,
    this.initialMessages = const [],
    this.contactName = 'Paired contact',
    this.contactPhoto,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
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

  // Animation controllers
  late AnimationController _messageAnimController;
  final Map<String, AnimationController> _emojiAnimControllers = {};

  StreamSubscription<DatabaseEvent>? _messagesSub;
  StreamSubscription<DatabaseEvent>? _statusSub;
  StreamSubscription<DatabaseEvent>? _callSub;
  Timer? _typingDebounce;
  Timer? _expiryTimer;
  Timer? _recordingTimer;

  bool _showEmojiPicker = false;
  bool _showStickerKeyboard = false;
  bool _isSearching = false;
  String _searchQuery = '';
  bool _isPartnerOnline = false;
  bool _isPartnerTyping = false;
  bool _myReportedTyping = false;
  String _partnerLastSeen = '';
  bool _messagesPrimed = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  final Map<String, ({String cipher, String? plain})> _decryptCache = {};
  int _selectedThemeIndex = 0;
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
  bool _isShowingCall = false;
  bool _pickingExternalMedia = false;

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

  ChatThemePalette get _theme => ChatThemePalette.presets[_selectedThemeIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _messages.addAll(widget.initialMessages);
    _disappearingSeconds = _firebase.disappearingSeconds;
    _firebase.updateOnlineStatus(true);

    // Animation controller for message entrance animations
    _messageAnimController = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 300),
    );

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
    _messageAnimController.dispose();
    // Clean up emoji animation controllers
    for (final controller in _emojiAnimControllers.values) {
      controller.dispose();
    }
    _firebase.updateOnlineStatus(false, isTyping: false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _firebase.updateOnlineStatus(true);
    } else {
      _myReportedTyping = false;
      _firebase.updateOnlineStatus(false, isTyping: false);
      if ((state == AppLifecycleState.paused ||
              state == AppLifecycleState.hidden) &&
          !_pickingExternalMedia &&
          !_micStarting &&
          !_isRecordingVoice &&
          !_isShowingCall) {
        _quickHide();
      }
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
          !_isShowingCall) {
        _isShowingCall = true;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => CallScreen(
              isVideo: isVideo,
              isIncoming: true,
              contactName: widget.contactName,
            ),
          ),
        ).whenComplete(() {
          _isShowingCall = false;
        });
      }
    });
  }

  void _pruneExpiredMessages() {
    if (!mounted || _messages.isEmpty) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final expired = <ChatMessage>[];
    for (final msg in _messages) {
      if (msg.expiresAtMs != null && msg.expiresAtMs! <= nowMs) {
        expired.add(msg);
      }
    }
    if (expired.isEmpty) return;
    for (final msg in expired) {
      _firebase.deleteMessage(msg.id, imageUrl: msg.imageUrl);
    }
    setState(() {
      _messages.removeWhere(
        (m) => m.expiresAtMs != null && m.expiresAtMs! <= nowMs,
      );
    });
  }

  String? _safeDecrypt(Object? rawValue, {String? cacheKey}) {
    if (rawValue is! String || rawValue.isEmpty) return null;
    if (cacheKey != null) {
      final cached = _decryptCache[cacheKey];
      if (cached != null && cached.cipher == rawValue) {
        return cached.plain;
      }
    }
    String? decoded;
    try {
      decoded = _encryption.decrypt(rawValue);
    } on FormatException {
      decoded = '[Unable to decrypt message]';
    }
    if (cacheKey != null) {
      _decryptCache[cacheKey] = (cipher: rawValue, plain: decoded);
    }
    return decoded;
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
      String? newPartnerMessageId;

      for (final entry in entries) {
        final message = entry.value;
        final expiresAt = message['expiresAt'] as int?;
        if (expiresAt != null && expiresAt <= nowMs) {
          _firebase.deleteMessage(
            entry.key,
            imageUrl: message['imageUrl'] as String?,
          );
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
            callType: message['callType'] as String?,
            callSeconds: message['callSeconds'] as int?,
            callOutcome: message['callOutcome'] as String?,
            text: _safeDecrypt(message['text'], cacheKey: '${entry.key}:t'),
            imageUrl: message['imageUrl'] as String?,
            encryptedAudioData: message['audioData'] as String?,
            audioDurationSeconds: message['audioDuration'] as int?,
            isMe: isMe,
            isSeen: isSeen,
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              (message['timestamp'] as int?) ?? 0,
            ),
            replyToText: _safeDecrypt(
              message['replyToText'],
              cacheKey: '${entry.key}:r',
            ),
            replyToIsMe:
                replySender != null && replySender == _firebase.myPeerId,
            reactions: reactions,
            expiresAtMs: expiresAt,
          ),
        );

        final isNewKey = _seenMessageKeys.add(entry.key);
        final hasSmsContent =
            message['text'] != null ||
            message['imageUrl'] != null ||
            message['audioData'] != null;
        if (_messagesPrimed && isNewKey && !isMe && hasSmsContent) {
          newPartnerMessageId = entry.key;
        }
      }
      _messagesPrimed = true;

      if (unseenPartnerKeys.isNotEmpty &&
          _lifecycleState == AppLifecycleState.resumed) {
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

      // Only notify if the app is backgrounded while this chat stays mounted;
      // when the user is actively reading this chat, notifications are noisy.
      if (newPartnerMessageId != null &&
          _lifecycleState != AppLifecycleState.resumed) {
        _notifications.showFakeNotification(messageId: newPartnerMessageId);
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

  void _quickHide() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _showEmojiPicker = false;
      _showStickerKeyboard = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    });
  }

  void _onInputChanged(String value) {
    setState(() {});
    final isTyping = value.trim().isNotEmpty;
    if (isTyping != _myReportedTyping) {
      _myReportedTyping = isTyping;
      _firebase.updateTypingStatus(isTyping);
    }
    _typingDebounce?.cancel();
    if (isTyping) {
      _typingDebounce = Timer(const Duration(seconds: 2), () {
        if (_myReportedTyping) {
          _myReportedTyping = false;
          _firebase.updateTypingStatus(false);
        }
      });
    }
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
      _showStickerKeyboard = false;
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
                color: chatInk,
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
    if (!mounted) return;
    final sendingRoom = _firebase.getShortCode();
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
      if (imageUrl == null) {
        // Storage rejected the upload (rules/size/network). Never push an
        // empty message — tell the user instead.
        _showErrorSnack('Image upload failed');
        return;
      }
    }

    if (!mounted || sendingRoom != _firebase.getShortCode()) return;
    try {
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
      if (!mounted) return;
      _messageController.clear();
      setState(() {});
    } catch (_) {
      _showErrorSnack('Message could not be sent. Please try again.');
    }
  }

  void _showErrorSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _handleKeyboardContent(KeyboardInsertedContent content) async {
    final data = content.data;
    if (data == null || data.isEmpty) return;
    try {
      final tempFile = File(
        '${Directory.systemTemp.path}/kb_sticker_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await tempFile.writeAsBytes(data, flush: true);
      await _sendMessage(image: tempFile);
    } catch (_) {
      _showErrorSnack('Could not send keyboard sticker');
    }
  }

  Future<void> _pickImage() async {
    _pickingExternalMedia = true;
    try {
      // Downscale before upload: keeps files under the 5 MB Storage rule
      // and makes uploads fast on mobile data.
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 75,
      );
      if (image != null) {
        await _sendMessage(image: File(image.path));
      }
    } catch (_) {
      _showErrorSnack('Could not open the gallery');
    } finally {
      _pickingExternalMedia = false;
    }
  }

  Future<void> _takePhoto() async {
    _pickingExternalMedia = true;
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 75,
      );
      if (image != null) {
        await _sendMessage(image: File(image.path));
      }
    } catch (_) {
      _showErrorSnack('Could not open the camera');
    } finally {
      _pickingExternalMedia = false;
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

  void _showCallOptions({bool isVideo = false}) {
    // Outgoing calls share the incoming-call exemption: an active call must
    // survive backgrounding (auto-lock) without being popped mid-call.
    _isShowingCall = true;
    Navigator.push(
      context,
      messagingRoute(
        CallScreen(isVideo: isVideo, contactName: widget.contactName),
      ),
    ).whenComplete(() {
      _isShowingCall = false;
    });
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
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: codeCtrl,
                keyboardType: TextInputType.number,
                maxLength: 8,
                style: const TextStyle(
                  color: chatInk,
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
                leading: const Icon(Icons.reply, color: chatInk),
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
                  leading: const Icon(Icons.copy, color: chatInk),
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
                  _firebase.deleteMessage(
                    message.id,
                    imageUrl: message.imageUrl,
                  );
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

  String _formatDisappearing(int seconds) {
    if (seconds % 3600 == 0) return '${seconds ~/ 3600}h';
    if (seconds % 60 == 0) return '${seconds ~/ 60}m';
    return '${seconds}s';
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
                    // Persist so leaving the chat doesn't reset the timer.
                    _firebase.setDisappearingSeconds(opt.value);
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
            foregroundColor: chatInk,
            title: const Text('Encrypted Photo'),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 4.0,
              child: CachedChatImage(imageUrl: imageUrl, fit: BoxFit.contain),
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
    if (_isPartnerOnline) return 'online';
    if (_partnerLastSeen.isNotEmpty) return 'Last seen $_partnerLastSeen';
    return 'Tap menu for contact info';
  }

  @override
  Widget build(BuildContext context) {
    final displayedMessages = _filteredMessages;
    final hasTypedText = _messageController.text.trim().isNotEmpty;

    return PopScope(
      canPop: !_showEmojiPicker && !_showStickerKeyboard,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          setState(() {
            _showEmojiPicker = false;
            _showStickerKeyboard = false;
          });
        }
      },
      child: Scaffold(
        backgroundColor: _theme.backgroundColor,
        appBar: AppBar(
          backgroundColor: _theme.appBarColor,
          foregroundColor: chatInk,
          titleSpacing: 0,
          title: _isSearching
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  style: const TextStyle(color: chatInk),
                  decoration: const InputDecoration(
                    hintText: 'Search messages…',
                    hintStyle: TextStyle(color: Colors.black45),
                    border: InputBorder.none,
                  ),
                  onChanged: (value) => setState(() => _searchQuery = value),
                )
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: _quickHide,
                  child: Row(
                    children: [
                      Stack(
                        children: [
                          ProfileAvatar(photo: widget.contactPhoto, radius: 20),
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
                                Flexible(
                                  child: Text(
                                    widget.contactName,
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
                ),
          actions: [
            IconButton(
              tooltip: 'Video call',
              icon: const Icon(Icons.videocam_outlined),
              onPressed: () {
                _isShowingCall = true;
                Navigator.push(
                  context,
                  messagingRoute(
                    CallScreen(isVideo: true, contactName: widget.contactName),
                  ),
                ).whenComplete(() {
                  _isShowingCall = false;
                });
              },
            ),
            IconButton(
              tooltip: 'Voice call',
              icon: const Icon(Icons.call_outlined),
              onPressed: _showCallOptions,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              color: _theme.appBarColor,
              onSelected: (value) async {
                switch (value) {
                  case 'hide':
                    _quickHide();
                    break;
                  case 'search':
                    setState(() {
                      _isSearching = !_isSearching;
                      _searchQuery = '';
                      _searchController.clear();
                    });
                    break;
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
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Unpair this contact?'),
                        content: const Text(
                          'This removes the contact from this device. Shared message history is not deleted.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Unpair'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true) return;
                    await _firebase.leaveRoom();
                    if (context.mounted) Navigator.pop(context);
                    break;
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'hide',
                  child: Text('Quick Hide to Calculator'),
                ),
                const PopupMenuItem(
                  value: 'search',
                  child: Text('Search Messages'),
                ),
                PopupMenuItem(
                  value: 'room_info',
                  child: Text('Room: ${_firebase.getShortCode()}'),
                ),
                const PopupMenuItem(
                  value: 'security',
                  child: Text('Passcode & Bio Lock'),
                ),
                const PopupMenuItem(value: 'theme', child: Text('Chat Theme')),
                PopupMenuItem(
                  value: 'disappearing',
                  child: Text(
                    'Disappearing: ${_disappearingSeconds == null ? 'Off' : _formatDisappearing(_disappearingSeconds!)}',
                  ),
                ),
                const PopupMenuItem(
                  value: 'clear',
                  child: Text('Clear chat history'),
                ),
                const PopupMenuItem(
                  value: 're_pair',
                  child: Text('Unpair this contact'),
                ),
              ],
            ),
          ],
        ),
        body: CustomPaint(
          painter: ChatWallpaper(),
          child: Column(
            children: [
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
                                color: Colors.grey[600],
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Only your paired conversation appears here',
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
                              !_isSameDay(
                                prevMessage.timestamp,
                                message.timestamp,
                              );
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
              if (_replyingTo != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
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
                                color: Colors.black54,
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
              // Keep the microphone mounted throughout hold-to-record gestures.
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: SafeArea(
                  top: false,
                  bottom: !_showEmojiPicker && !_showStickerKeyboard,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(28),
                          ),
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: 'Emoji keyboard',
                                icon: Icon(
                                  _showEmojiPicker
                                      ? Icons.keyboard
                                      : Icons.emoji_emotions_outlined,
                                  color: Colors.blueGrey,
                                ),
                                onPressed: _isRecordingVoice
                                    ? null
                                    : () {
                                        FocusScope.of(context).unfocus();
                                        setState(() {
                                          _showStickerKeyboard = false;
                                          _showEmojiPicker = !_showEmojiPicker;
                                        });
                                      },
                              ),
                              Expanded(
                                child: _isRecordingVoice
                                    ? _buildRecordingIndicator()
                                    : TextField(
                                        controller: _messageController,
                                        contentInsertionConfiguration:
                                            ContentInsertionConfiguration(
                                              allowedMimeTypes: const [
                                                'image/png',
                                                'image/gif',
                                                'image/webp',
                                                'image/jpeg',
                                              ],
                                              onContentInserted:
                                                  _handleKeyboardContent,
                                            ),
                                        onChanged: _onInputChanged,
                                        onTap: () => setState(() {
                                          _showEmojiPicker = false;
                                          _showStickerKeyboard = false;
                                        }),
                                        minLines: 1,
                                        maxLines: 5,
                                        decoration: const InputDecoration(
                                          hintText: 'Message',
                                          border: InputBorder.none,
                                          contentPadding: EdgeInsets.symmetric(
                                            vertical: 12,
                                          ),
                                        ),
                                        style: const TextStyle(
                                          color: chatInk,
                                          fontSize: 17,
                                        ),
                                        onSubmitted: (text) =>
                                            _sendMessage(text: text),
                                      ),
                              ),
                              IconButton(
                                tooltip: 'Attach photo',
                                icon: const Icon(
                                  Icons.attach_file,
                                  color: Colors.blueGrey,
                                ),
                                onPressed: _isRecordingVoice
                                    ? null
                                    : _showImageOptions,
                              ),
                              if (!hasTypedText && !_isRecordingVoice)
                                IconButton(
                                  tooltip: 'Camera',
                                  icon: const Icon(
                                    Icons.camera_alt_outlined,
                                    color: Colors.blueGrey,
                                  ),
                                  onPressed: _takePhoto,
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        decoration: BoxDecoration(
                          color: chatGreen,
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
                                ? () => _sendMessage(
                                    text: _messageController.text,
                                  )
                                : () {},
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_showEmojiPicker || _showStickerKeyboard)
                Container(
                  color: Colors.white,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          onPressed: () => setState(() {
                            _showEmojiPicker = true;
                            _showStickerKeyboard = false;
                          }),
                          icon: const Icon(Icons.emoji_emotions_outlined),
                          label: const Text('Emoji'),
                        ),
                      ),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: () => setState(() {
                            _showEmojiPicker = false;
                            _showStickerKeyboard = true;
                          }),
                          icon: const Icon(Icons.emoji_objects_outlined),
                          label: const Text('Stickers'),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close keyboard',
                        onPressed: () => setState(() {
                          _showEmojiPicker = false;
                          _showStickerKeyboard = false;
                        }),
                        icon: const Icon(Icons.keyboard_arrow_down),
                      ),
                    ],
                  ),
                ),
              if (_showEmojiPicker)
                EmojiKeyboard(
                  controller: _messageController,
                  onTextChanged: () => _onInputChanged(_messageController.text),
                  onEmojiSelected: (_) =>
                      _onInputChanged(_messageController.text),
                  backgroundColor: _theme.appBarColor,
                ),
              if (_showStickerKeyboard)
                StickerKeyboard(
                  onStickerSelected: (emoji) =>
                      _sendMessage(text: 'sticker:v1:$emoji'),
                ),
            ],
          ),
        ),
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
          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    final isSticker = message.text?.startsWith('sticker:v1:') ?? false;
    final uniqueReactions = message.reactions.values.toSet().toList();
    final isPlayingVoice = _playingMessageId == message.id;
    final callText = message.callType == null
        ? null
        : callLogText(
            callType: message.callType,
            callSeconds: message.callSeconds,
            callOutcome: message.callOutcome,
            isMe: message.isMe,
          );

    // Create a simple slide+fade animation for new messages
    final animController = _messageAnimController;

    return SizeTransition(
      sizeFactor: CurvedAnimation(
        parent: animController,
        curve: Curves.easeOutBack,
      ),
      axis: Axis.vertical,
      child: FadeTransition(
        opacity: CurvedAnimation(parent: animController, curve: Curves.easeOut),
        child: GestureDetector(
          onLongPress: () => _showMessageActions(message),
          onHorizontalDragEnd: (details) {
            if ((details.primaryVelocity ?? 0).abs() > 150) {
              setState(() => _replyingTo = message);
            }
          },
          child: Align(
            alignment: message.isMe
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: message.isMe
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.76,
                  ),
                  decoration: BoxDecoration(
                    gradient: message.isMe && !isSticker
                        ? LinearGradient(
                            colors: _theme.myBubbleGradient,
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    color: isSticker
                        ? Colors.transparent
                        : message.isMe
                        ? null
                        : _theme.partnerBubbleColor,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(message.isMe ? 16 : 4),
                      topRight: Radius.circular(message.isMe ? 4 : 16),
                      bottomLeft: const Radius.circular(16),
                      bottomRight: const Radius.circular(16),
                    ),
                    boxShadow: isSticker
                        ? []
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (message.replyToText != null)
                        Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(8),
                            border: Border(
                              left: BorderSide(
                                color: _theme.accentColor,
                                width: 3,
                              ),
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
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (message.callType != null)
                        InkWell(
                          onTap: () => _showCallOptions(
                            isVideo: message.callType == 'video',
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircleAvatar(
                                  backgroundColor: Colors.black.withValues(
                                    alpha: 0.04,
                                  ),
                                  child: Icon(
                                    message.callType == 'video'
                                        ? Icons.videocam
                                        : Icons.call,
                                    color: message.callSeconds == null
                                        ? Colors.red
                                        : chatGreen,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        callText?.title ?? '',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 16,
                                        ),
                                      ),
                                      Text(
                                        callText?.detail ?? '',
                                        style: const TextStyle(
                                          color: Colors.black54,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else if (message.imageUrl != null)
                        GestureDetector(
                          onTap: () => _openFullScreenImage(message.imageUrl!),
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: CachedChatImage(
                                imageUrl: message.imageUrl!,
                                width: 220,
                                height: 220,
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
                                  backgroundColor: Colors.black12,
                                  child: Icon(
                                    isPlayingVoice
                                        ? Icons.stop
                                        : Icons.play_arrow,
                                    color: chatInk,
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
                                  color: chatInk,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        )
                      else if (isSticker)
                        StickerArt(
                          emoji: message.text!.substring('sticker:v1:'.length),
                          size: 136,
                        )
                      else if (message.text != null && message.text!.isNotEmpty)
                        Text(
                          isSticker
                              ? message.text!.substring('sticker:v1:'.length)
                              : message.text!,
                          style: TextStyle(
                            color: chatInk,
                            fontSize: isSticker ? 68 : 16,
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
                              color: Colors.black54,
                              fontSize: 10,
                            ),
                          ),
                          if (message.isMe) ...[
                            const SizedBox(width: 4),
                            Icon(
                              message.isSeen ? Icons.done_all : Icons.check,
                              size: 14,
                              color: message.isSeen
                                  ? Colors.blue
                                  : Colors.black54,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (uniqueReactions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(
                      bottom: 6,
                      left: 6,
                      right: 6,
                    ),
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
        ),
      ),
    );
  }
}

class ChatMessage {
  final String id;
  final String? callType;
  final int? callSeconds;
  final String? callOutcome;
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
    this.callType,
    this.callSeconds,
    this.callOutcome,
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
