import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
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
import '../widgets/option_sheet.dart';
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

  /// Id of the message that arrived most recently; only that bubble plays the
  /// entrance animation (see [_buildMessageBubble]).
  String? _freshMessageId;
  bool _myReportedTyping = false;
  String _partnerLastSeen = '';
  bool _messagesPrimed = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  final Map<String, ({String cipher, String? plain})> _decryptCache = {};
  int _selectedThemeIndex = 0;
  int? _disappearingSeconds;
  ChatMessage? _replyingTo;

  /// Messages this phone is still sending, drawn at the end of the list until
  /// the room echoes them back.
  final List<_PendingSend> _outgoing = [];

  bool _isRecordingVoice = false;
  int _recordingSeconds = 0;
  bool _micHeld = false;
  bool _micStarting = false;
  double? _micDownX;
  DateTime? _micDownAt;
  bool _micCancelArmed = false;
  String? _playingMessageId;

  /// Playback progress (0..1) of the note currently playing. The native side
  /// plays the decrypted audio, so the waveform is driven by a timer over the
  /// known duration rather than a decoder position.
  double _voiceProgress = 0;
  Timer? _voiceProgressTimer;
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
    _voiceProgressTimer?.cancel();
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
      final previousNewestId = _messages.isEmpty ? null : _messages.last.id;
      setState(() {
        _messages
          ..clear()
          ..addAll(rebuilt);
      });

      if (rebuilt.length > previousCount) {
        final newestId = rebuilt.isEmpty ? null : rebuilt.last.id;
        if (newestId != null && newestId != previousNewestId) {
          _freshMessageId = newestId;
          _messageAnimController.forward(from: 0);
        }
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
      _stopVoiceProgress();
      await _native.stopAudio();
      if (!mounted) return;
      setState(() => _playingMessageId = null);
      return;
    }
    setState(() {
      _playingMessageId = message.id;
      _voiceProgress = 0;
    });
    final ok = await _native.playEncryptedAudio(
      message.encryptedAudioData!,
      _encryption,
    );
    if (!ok) {
      _stopVoiceProgress();
      if (mounted) setState(() => _playingMessageId = null);
      return;
    }
    _startVoiceProgress(message.audioDurationSeconds ?? 1);
  }

  void _startVoiceProgress(int durationSeconds) {
    _stopVoiceProgress();
    final total = durationSeconds < 1 ? 1 : durationSeconds;
    _voiceProgressTimer = Timer.periodic(const Duration(milliseconds: 200), (
      timer,
    ) {
      if (!mounted) return;
      setState(() {
        _voiceProgress = (_voiceProgress + 0.2 / total).clamp(0.0, 1.0);
      });
      if (_voiceProgress >= 1.0) timer.cancel();
    });
  }

  void _stopVoiceProgress() {
    _voiceProgressTimer?.cancel();
    _voiceProgressTimer = null;
    _voiceProgress = 0;
  }

  /// m:ss
  String _voiceClock(int seconds) =>
      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  Future<void> _sendMessage({
    String? text,
    File? image,
    String? audioBase64,
    int? audioDurationSeconds,
  }) async {
    if (!mounted) return;
    if (text == null && image == null && audioBase64 == null) return;
    if (text != null &&
        text.trim().isEmpty &&
        image == null &&
        audioBase64 == null) {
      return;
    }

    // The bubble appears before the network is touched: the photo shows up in
    // the conversation while it uploads, carries its own progress, and its own
    // failure with a retry. A send never vanishes into a snackbar.
    final pending = _PendingSend(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      text: text?.trim(),
      image: image,
      audioBase64: audioBase64,
      audioDurationSeconds: audioDurationSeconds,
      replyTarget: _replyingTo,
    );
    setState(() {
      _replyingTo = null;
      _outgoing.add(pending);
    });
    _messageController.clear();
    _typingDebounce?.cancel();
    _firebase.updateTypingStatus(false);
    _scrollToBottom();
    await _flushPending(pending);
  }

  Future<void> _flushPending(_PendingSend pending) async {
    final sendingRoom = _firebase.getShortCode();
    try {
      String? imageUrl;
      if (pending.image != null) {
        if (mounted) setState(() => pending.progress = 0);
        imageUrl = await _firebase.uploadImage(
          pending.image!,
          onProgress: (value) {
            if (!mounted) return;
            setState(() => pending.progress = value);
          },
        );
      }
      if (!mounted) return;
      if (sendingRoom != _firebase.getShortCode()) {
        // The user moved to another room mid-send; drop it quietly rather
        // than posting it into the wrong conversation.
        _removePending(pending);
        return;
      }
      final reply = pending.replyTarget;
      await _firebase.sendMessage(
        pending.text ?? '',
        imageUrl: imageUrl,
        audioBase64: pending.audioBase64,
        audioDurationSeconds: pending.audioDurationSeconds,
        replyToText:
            reply?.text ?? (reply?.imageUrl != null ? '📷 Photo' : null),
        replyToSenderId: reply == null
            ? null
            : (reply.isMe ? _firebase.myPeerId : 'partner'),
        expiresInSeconds: _disappearingSeconds,
      );
      if (!mounted) return;
      _removePending(pending);
    } catch (e) {
      // The console line is for `flutter run`; the bubble is for the phone.
      debugPrint('send failed: $e');
      if (!mounted) return;
      setState(() {
        pending.progress = null;
        pending.error = _sendFailureReason(e);
      });
      HapticFeedback.mediumImpact();
    }
  }

  Future<void> _retryPending(_PendingSend pending) async {
    HapticFeedback.selectionClick();
    setState(() {
      pending.error = null;
      pending.progress = 0;
    });
    await _flushPending(pending);
  }

  void _removePending(_PendingSend pending) {
    if (!mounted) return;
    setState(() => _outgoing.removeWhere((p) => p.id == pending.id));
  }

  /// Names the step that actually failed. "Could not be sent" is true and
  /// useless: an upload that Storage refused and a message the room's rules
  /// rejected need different fixes.
  String _sendFailureReason(Object error) {
    if (error is MediaUploadException) return error.message;
    if (error is FirebaseException) {
      switch (error.code) {
        case 'permission-denied':
          return 'The room refused this message (permission denied).';
        case 'network-request-failed':
          return 'No connection — tap to retry.';
        case 'unavailable':
          return 'The database is unreachable right now.';
        default:
          return 'Send failed (${error.code}).';
      }
    }
    return 'Message could not be sent. Please try again.';
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

  Future<void> _showImageOptions() async {
    final choice = await showOptionSheet(
      context,
      title: 'Send a photo',
      subtitle: 'Photos are encrypted before they leave this phone',
      items: const [
        OptionSheetItem(
          value: 'gallery',
          icon: Icons.photo_library_outlined,
          label: 'Gallery',
        ),
        OptionSheetItem(
          value: 'camera',
          icon: Icons.camera_alt_outlined,
          label: 'Camera',
        ),
      ],
    );
    if (choice == 'gallery') {
      await _pickImage();
    } else if (choice == 'camera') {
      await _takePhoto();
    }
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

  /// The chat's overflow menu: everything that acts on *this* conversation,
  /// and nothing that is really a device setting — those live on the profile
  /// (see `showSecuritySettingsSheet`).
  Future<void> _showChatOptions() async {
    final value = await showOptionSheet(
      context,
      title: widget.contactName,
      subtitle: 'Options for this secret conversation',
      items: [
        const OptionSheetItem(
          value: 'hide',
          icon: Icons.calculate_outlined,
          label: 'Quick Hide to Calculator',
        ),
        const OptionSheetItem(
          value: 'search',
          icon: Icons.search,
          label: 'Search Messages',
        ),
        OptionSheetItem(
          value: 'room_info',
          icon: Icons.verified_user_outlined,
          label: 'Room: ${_firebase.getShortCode()}',
          subtitle: 'Secret room pairing code',
        ),
        const OptionSheetItem(
          value: 'theme',
          icon: Icons.palette_outlined,
          label: 'Chat Theme',
          subtitle: 'Wallpaper and bubble colours',
        ),
        OptionSheetItem(
          value: 'disappearing',
          icon: Icons.timer_outlined,
          label: 'Disappearing messages',
          subtitle: _disappearingSeconds == null
              ? 'Off'
              : 'Clears after ${_formatDisappearing(_disappearingSeconds!)}',
        ),
        const OptionSheetItem(
          value: 'clear',
          icon: Icons.cleaning_services_outlined,
          label: 'Clear chat history',
          destructive: true,
        ),
        const OptionSheetItem(
          value: 're_pair',
          icon: Icons.link_off,
          label: 'Unpair this contact',
          destructive: true,
        ),
      ],
    );
    if (value == null || !mounted) return;
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
        if (!mounted) return;
        Navigator.pop(context);
        break;
    }
  }

  /// The reaction row that heads the message sheet: one tap reacts and
  /// closes, and the current reaction wears a ring instead of a plain tint.
  Widget _buildReactionBar(ChatMessage message) {
    final myCurrentReaction = message.reactions[_firebase.myPeerId];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: _reactionOptions.map((emoji) {
          final isSelected = myCurrentReaction == emoji;
          return InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              Navigator.pop(context);
              _firebase.toggleReaction(
                message.id,
                emoji,
                currentReaction: myCurrentReaction,
              );
            },
            customBorder: const CircleBorder(),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected ? chatGreen.withValues(alpha: 0.12) : null,
                border: isSelected
                    ? Border.all(color: chatGreen, width: 1.6)
                    : null,
              ),
              child: Text(emoji, style: const TextStyle(fontSize: 26)),
            ),
          );
        }).toList(),
      ),
    );
  }

  Future<void> _showMessageActions(ChatMessage message) async {
    final canCopy = message.text != null && message.text!.isNotEmpty;
    final value = await showOptionSheet(
      context,
      title: 'Message',
      subtitle:
          'Sent ${message.timestamp.hour}:${message.timestamp.minute.toString().padLeft(2, '0')}',
      header: _buildReactionBar(message),
      items: [
        const OptionSheetItem(
          value: 'reply',
          icon: Icons.reply,
          label: 'Reply',
        ),
        if (canCopy)
          const OptionSheetItem(
            value: 'copy',
            icon: Icons.copy,
            label: 'Copy Text',
          ),
        const OptionSheetItem(
          value: 'delete',
          icon: Icons.delete_outline,
          label: 'Delete for Everyone',
          destructive: true,
        ),
      ],
    );
    if (value == null || !mounted) return;
    switch (value) {
      case 'reply':
        setState(() => _replyingTo = message);
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.text!));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Message copied to clipboard'),
            duration: Duration(seconds: 1),
          ),
        );
        break;
      case 'delete':
        _firebase.deleteMessage(message.id, imageUrl: message.imageUrl);
        break;
    }
  }

  void _showThemePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 10),
                child: Text(
                  'Choose Chat Theme',
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
              ),
              ...List.generate(ChatThemePalette.presets.length, (index) {
                final item = ChatThemePalette.presets[index];
                final isSelected = index == _selectedThemeIndex;
                return InkWell(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _selectedThemeIndex = index;
                    });
                    Navigator.pop(sheetContext);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: item.myBubbleGradient,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            item.name,
                            style: Theme.of(sheetContext).textTheme.titleMedium
                                ?.copyWith(
                                  color: isSelected ? chatGreen : chatInk,
                                ),
                          ),
                        ),
                        if (isSelected)
                          const Icon(Icons.check_circle, color: chatGreen),
                      ],
                    ),
                  ),
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
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Disappearing messages',
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'New messages clear themselves here and on the other phone',
                      style: Theme.of(sheetContext).textTheme.bodySmall
                          ?.copyWith(color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
              ...options.map((opt) {
                final selected = _disappearingSeconds == opt.value;
                return InkWell(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _disappearingSeconds = opt.value;
                    });
                    // Persist so leaving the chat doesn't reset the timer.
                    _firebase.setDisappearingSeconds(opt.value);
                    Navigator.pop(sheetContext);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          selected ? Icons.check_circle : Icons.circle_outlined,
                          color: selected ? chatGreen : Colors.grey[400],
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            opt.key,
                            style: Theme.of(sheetContext).textTheme.titleMedium
                                ?.copyWith(
                                  color: selected ? chatGreen : chatInk,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  /// The little grabber every sheet carries, so the sheets read as one family.
  Widget _sheetHandle() => Center(
    child: Container(
      width: 40,
      height: 4,
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(4),
      ),
    ),
  );

  void _showRoomInfoDialog() {
    final code = _firebase.getShortCode();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _theme.appBarColor,
        title: const Row(
          children: [
            Icon(Icons.verified_user, color: chatGreen),
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
                    color: chatGreen,
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
                          // The list's avatar flies into this one (see the
                          // matching Hero on the chat rows).
                          Hero(
                            tag: 'chat-avatar-${_firebase.getShortCode()}',
                            child: ProfileAvatar(
                              photo: widget.contactPhoto,
                              radius: 20,
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
                            if (_isPartnerTyping)
                              const _TypingDots()
                            else
                              Text(
                                _statusSubtitle(),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _isPartnerOnline
                                      ? Colors.greenAccent
                                      : Colors.grey[400],
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
            IconButton(
              tooltip: 'More options',
              icon: const Icon(Icons.more_vert),
              onPressed: _showChatOptions,
            ),
          ],
        ),
        body: CustomPaint(
          painter: ChatWallpaper(),
          child: Column(
            children: [
              Expanded(
                child: displayedMessages.isEmpty && _outgoing.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 88,
                                height: 88,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: chatGreen.withValues(alpha: 0.08),
                                ),
                                child: Icon(
                                  _searchQuery.isNotEmpty
                                      ? Icons.search_off
                                      : Icons.lock_outline,
                                  size: 38,
                                  color: chatGreen,
                                ),
                              ),
                              const SizedBox(height: 20),
                              Text(
                                _searchQuery.isNotEmpty
                                    ? 'No matching messages found'
                                    : 'Start a secret conversation',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Only your paired conversation appears here',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  height: 1.35,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        itemCount: displayedMessages.length + _outgoing.length,
                        itemBuilder: (context, index) {
                          if (index >= displayedMessages.length) {
                            return _buildPendingBubble(
                              _outgoing[index - displayedMessages.length],
                            );
                          }
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
                                ? () {
                                    HapticFeedback.selectionClick();
                                    _sendMessage(text: _messageController.text);
                                  }
                                : () {},
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // One animated container for the whole keyboard area, so the
              // panel slides open and shut instead of popping.
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                        onTextChanged: () =>
                            _onInputChanged(_messageController.text),
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

  /// The bubble for a message that is still on its way out: the photo (or the
  /// text) is already in the conversation, with a progress ring while it
  /// uploads and its own retry when it fails.
  Widget _buildPendingBubble(_PendingSend pending) {
    final failed = pending.error != null;
    final uploading = !failed && pending.progress != null;
    final progress = pending.progress ?? 0;

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: failed
              ? const Color(0xFFFFE9E7)
              : _theme.myBubbleGradient.first.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pending.image != null)
                Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: failed
                        ? const Icon(
                            Icons.image_not_supported_outlined,
                            color: Colors.white70,
                          )
                        : Text(
                            '${(progress * 100).round()}%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
              if (pending.image != null &&
                  pending.text != null &&
                  pending.text!.isNotEmpty)
                const SizedBox(height: 6),
              if (pending.text != null && pending.text!.isNotEmpty)
                Text(
                  pending.text!,
                  style: const TextStyle(fontSize: 15, color: chatInk),
                ),
              if (pending.audioBase64 != null)
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.mic, size: 16, color: chatInk),
                    SizedBox(width: 6),
                    Text('Voice message', style: TextStyle(fontSize: 15)),
                  ],
                ),
              const SizedBox(height: 6),
              if (failed)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 15,
                      color: Color(0xFFD64541),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        pending.error!,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFFD64541),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _retryPending(pending),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      child: const Text(
                        'Retry',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: chatGreen,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Discard',
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      icon: const Icon(Icons.close, color: Colors.black38),
                      onPressed: () => _removePending(pending),
                    ),
                  ],
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: chatInk.withValues(alpha: 0.55),
                        value: uploading ? progress : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      uploading ? 'Uploading photo…' : 'Sending…',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: chatInk.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
            ],
          ),
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

    // Only the message that just arrived plays an entrance; the controller
    // stays parked at 1 for every other bubble, so an incoming snapshot can
    // never make the whole list shimmer.
    final isArriving = message.id == _freshMessageId;
    final bubble = GestureDetector(
      onLongPress: () {
        HapticFeedback.mediumImpact();
        _showMessageActions(message);
      },
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
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                                isPlayingVoice ? Icons.pause : Icons.play_arrow,
                                color: chatInk,
                                size: 20,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _VoiceWaveform(
                            seed: message.id,
                            progress: isPlayingVoice ? _voiceProgress : 0,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            isPlayingVoice
                                ? '${_voiceClock((_voiceProgress * (message.audioDurationSeconds ?? 1)).round())} / ${_voiceClock(message.audioDurationSeconds ?? 1)}'
                                : _voiceClock(
                                    message.audioDurationSeconds ?? 1,
                                  ),
                            style: const TextStyle(
                              color: chatInk,
                              fontSize: 12,
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
                          color: message.isSeen ? Colors.blue : Colors.black54,
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

    if (!isArriving) return bubble;
    return SizeTransition(
      sizeFactor: CurvedAnimation(
        parent: _messageAnimController,
        curve: Curves.easeOutCubic,
      ),
      axis: Axis.vertical,
      child: FadeTransition(
        opacity: CurvedAnimation(
          parent: _messageAnimController,
          curve: Curves.easeOut,
        ),
        child: bubble,
      ),
    );
  }
}

/// Three dots that ripple in the header while the partner is typing — the
/// status line's version of the same activity the composer reports.
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 14,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = (_controller.value + i / 3) % 1.0;
            final t = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
            return Container(
              margin: EdgeInsets.only(right: i == 2 ? 0 : 3),
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.amberAccent.withValues(alpha: 0.35 + 0.65 * t),
              ),
            );
          }),
        ),
      ),
    );
  }
}

/// One message still on its way out. Mutable on purpose: the same bubble is
/// updated with upload progress, then with the failure and its reason.
class _PendingSend {
  _PendingSend({
    required this.id,
    this.text,
    this.image,
    this.audioBase64,
    this.audioDurationSeconds,
    this.replyTarget,
  });

  final String id;
  final String? text;
  final File? image;
  final String? audioBase64;
  final int? audioDurationSeconds;
  final ChatMessage? replyTarget;

  /// Upload progress 0..1 while a photo is moving; null once it is queued.
  double? progress;

  /// Set when the send failed, with a reason worth reading.
  String? error;
}

/// Deterministic pseudo-waveform for a voice note: seeded from the message
/// id, so the same note always draws the same bars — stable across rebuilds
/// and app launches, with no audio decoding and no network.
List<double> voiceWaveformHeights(String seed, {int barCount = 24}) {
  var hash = 0x811c9dc5;
  for (final unit in seed.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  final heights = <double>[];
  for (var i = 0; i < barCount; i++) {
    hash = (hash + 0x9e3779b9) & 0xFFFFFFFF;
    final z = (hash ^ (hash >> 16)) & 0xFFFFFFFF;
    heights.add(0.25 + (z % 1000) / 1000 * 0.75);
  }
  return heights;
}

/// The note's bars: played portion in accent green, the rest soft white.
class _VoiceWaveform extends StatelessWidget {
  final String seed;
  final double progress;

  static const double _height = 28;

  const _VoiceWaveform({required this.seed, required this.progress});

  @override
  Widget build(BuildContext context) {
    final heights = voiceWaveformHeights(seed);
    return SizedBox(
      width: 120,
      height: _height,
      child: Row(
        children: [
          for (var i = 0; i < heights.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              child: Center(
                child: Container(
                  width: 3,
                  height: (_height * heights[i]).clamp(6.0, _height),
                  decoration: BoxDecoration(
                    color: progress > 0 && i / heights.length <= progress
                        ? chatGreen
                        : Colors.white.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ],
        ],
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
