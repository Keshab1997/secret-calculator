import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/encryption_service.dart';
import '../services/firebase_service.dart';
import '../services/native_bridge_service.dart';

class CallScreen extends StatefulWidget {
  final bool isVideo;
  final bool isIncoming;

  const CallScreen({
    super.key,
    required this.isVideo,
    this.isIncoming = false,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final FirebaseService _firebase = FirebaseService();
  final NativeBridgeService _native = NativeBridgeService();
  final EncryptionService _encryption = EncryptionService();

  StreamSubscription<DatabaseEvent>? _callSub;
  Timer? _durationTimer;
  Timer? _audioChunkTimer;

  String _callStatus = 'ringing';
  int _elapsedSeconds = 0;
  int _lastPartnerAudioTs = 0;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  late bool _isVideoEnabled;
  bool _hasSeenCallNode = false;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    _isVideoEnabled = widget.isVideo;
    _isSpeakerOn = widget.isVideo;
    _initCall();
  }

  Future<void> _initCall() async {
    await _native.ensureMicPermission();
    await _native.setSpeakerphone(_isSpeakerOn);
    if (!widget.isIncoming) {
      await _firebase.startCall(isVideo: widget.isVideo);
    }
    _listenToCallState();
  }

  void _listenToCallState() {
    _callSub = _firebase.getCallStream().listen((event) {
      final raw = event.snapshot.value;
      if (raw == null || raw is! Map) {
        if (_hasSeenCallNode) {
          _closeCallScreen();
        }
        return;
      }

      _hasSeenCallNode = true;
      final newStatus = raw['status']?.toString() ?? 'ringing';

      // Play incoming encrypted partner audio chunk if present
      final audioStream = raw['audioStream'];
      if (audioStream is Map) {
        audioStream.forEach((peerKey, packet) {
          if (peerKey.toString() != _firebase.myPeerId && packet is Map) {
            final ts = (packet['ts'] as int?) ?? 0;
            final encryptedData = packet['data']?.toString();
            if (ts > _lastPartnerAudioTs &&
                encryptedData != null &&
                encryptedData.isNotEmpty) {
              _lastPartnerAudioTs = ts;
              _native.playEncryptedAudio(encryptedData, _encryption);
            }
          }
        });
      }

      if (!mounted) return;
      if (newStatus == 'connected' && _callStatus != 'connected') {
        _startConnectedTimers();
      }
      setState(() {
        _callStatus = newStatus;
      });
    });
  }

  void _startConnectedTimers() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsedSeconds++;
      });
    });

    // Live voice relay loop (records 2.5s segments when unmuted and streams encrypted)
    _startAudioRelayLoop();
  }

  Future<void> _startAudioRelayLoop() async {
    await _native.startRecording();
    _audioChunkTimer?.cancel();
    _audioChunkTimer = Timer.periodic(const Duration(milliseconds: 2500), (
      _,
    ) async {
      if (!mounted || _callStatus != 'connected') return;
      if (_isMuted) {
        await _native.stopRecording();
        return;
      }
      final recordedPath = await _native.stopRecording();
      await _native.startRecording();
      if (recordedPath != null) {
        try {
          final file = File(recordedPath);
          if (file.existsSync()) {
            final bytes = await file.readAsBytes();
            if (bytes.isNotEmpty && bytes.length < 250000) {
              await _firebase.sendCallAudioChunk(base64Encode(bytes));
            }
            await file.delete();
          }
        } catch (_) {}
      }
    });
  }

  Future<void> _acceptIncomingCall() async {
    await _firebase.acceptCall();
    if (!mounted) return;
    setState(() {
      _callStatus = 'connected';
    });
    _startConnectedTimers();
  }

  Future<void> _endCall() async {
    await _firebase.endCall();
    _closeCallScreen();
  }

  void _closeCallScreen() {
    if (_isClosing || !mounted) return;
    _isClosing = true;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _audioChunkTimer?.cancel();
    _callSub?.cancel();
    _native.stopRecording();
    _native.stopAudio();
    _native.setSpeakerphone(false);
    super.dispose();
  }

  String _formatDuration(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final isRingingIncoming = widget.isIncoming && _callStatus == 'ringing';
    final statusLabel = _callStatus == 'connected'
        ? _formatDuration(_elapsedSeconds)
        : (isRingingIncoming ? 'Incoming Encrypted Call...' : 'Ringing...');

    return Scaffold(
      backgroundColor: const Color(0xFF0B0914),
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 16,
                    color: Colors.greenAccent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _isVideoEnabled
                        ? 'End-to-End Encrypted Video Call'
                        : 'End-to-End Encrypted Voice Call',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),

            const Spacer(),

            // Avatar / Video stage
            Container(
              width: _isVideoEnabled ? 240 : 150,
              height: _isVideoEnabled ? 300 : 150,
              decoration: BoxDecoration(
                shape: _isVideoEnabled ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: _isVideoEnabled
                    ? BorderRadius.circular(28)
                    : null,
                gradient: const LinearGradient(
                  colors: [Color(0xFF6A3DE8), Color(0xFF9B4DFF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF6A3DE8).withValues(alpha: 0.45),
                    blurRadius: 32,
                    spreadRadius: 6,
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isVideoEnabled ? Icons.videocam : Icons.person,
                    size: 64,
                    color: Colors.white,
                  ),
                  if (_isVideoEnabled) ...[
                    const SizedBox(height: 12),
                    Text(
                      _callStatus == 'connected'
                          ? 'Live Encrypted Stream'
                          : 'Camera Ready',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 28),
            const Text(
              'Secret Partner',
              style: TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              statusLabel,
              style: TextStyle(
                color: _callStatus == 'connected'
                    ? Colors.greenAccent
                    : Colors.amberAccent,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),

            const Spacer(),

            // Call controls
            Padding(
              padding: const EdgeInsets.only(bottom: 40, left: 24, right: 24),
              child: isRingingIncoming
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildCallActionButton(
                          icon: Icons.call_end,
                          label: 'Decline',
                          color: Colors.redAccent,
                          onTap: _endCall,
                        ),
                        _buildCallActionButton(
                          icon: Icons.call,
                          label: 'Accept',
                          color: Colors.green,
                          onTap: _acceptIncomingCall,
                        ),
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildCallActionButton(
                          icon: _isMuted ? Icons.mic_off : Icons.mic,
                          label: _isMuted ? 'Unmute' : 'Mute',
                          color: _isMuted
                              ? Colors.orangeAccent
                              : Colors.white12,
                          onTap: () {
                            setState(() => _isMuted = !_isMuted);
                          },
                        ),
                        _buildCallActionButton(
                          icon: _isSpeakerOn
                              ? Icons.volume_up
                              : Icons.volume_down,
                          label: 'Speaker',
                          color: _isSpeakerOn
                              ? Colors.blueAccent
                              : Colors.white12,
                          onTap: () {
                            setState(() => _isSpeakerOn = !_isSpeakerOn);
                            _native.setSpeakerphone(_isSpeakerOn);
                          },
                        ),
                        _buildCallActionButton(
                          icon: _isVideoEnabled
                              ? Icons.videocam
                              : Icons.videocam_off,
                          label: 'Video',
                          color: _isVideoEnabled
                              ? Colors.purpleAccent
                              : Colors.white12,
                          onTap: () {
                            setState(() => _isVideoEnabled = !_isVideoEnabled);
                          },
                        ),
                        _buildCallActionButton(
                          icon: Icons.call_end,
                          label: 'End',
                          color: Colors.redAccent,
                          onTap: _endCall,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(36),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}
