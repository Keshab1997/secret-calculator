import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/firebase_service.dart';
import '../services/native_bridge_service.dart';

class CallScreen extends StatefulWidget {
  final bool isVideo;
  final bool isIncoming;

  const CallScreen({super.key, required this.isVideo, this.isIncoming = false});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final FirebaseService _firebase = FirebaseService();
  final NativeBridgeService _native = NativeBridgeService();

  /// STUN-only ICE config. No TURN server is configured, so calls between
  /// some hard NAT pairs may fail to connect (media itself is free P2P).
  static const Map<String, dynamic> _rtcConfig = {
    'iceServers': [
      {
        'urls': [
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
        ],
      },
    ],
    'sdpSemantics': 'unified-plan',
  };

  StreamSubscription<DatabaseEvent>? _callSub;
  Timer? _durationTimer;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  String _callStatus = 'ringing';
  int _elapsedSeconds = 0;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _isCameraOff = false;
  bool _remoteVideoReady = false;
  late final bool _isCaller;

  bool _hasSeenCallNode = false;
  bool _isClosing = false;
  bool _disposed = false;
  bool _accepting = false;
  bool _remoteDescSet = false;
  bool _sdpInFlight = false;
  bool _tornDown = false;
  Map<dynamic, dynamic>? _lastCallRaw;
  final Set<String> _seenIce = <String>{};
  final List<RTCIceCandidate> _pendingIce = <RTCIceCandidate>[];

  @override
  void initState() {
    super.initState();
    _isCaller = !widget.isIncoming;
    _isSpeakerOn = widget.isVideo;
    // The incoming screen is only pushed while the call node exists, so a
    // null snapshot right away means the caller already cancelled.
    _hasSeenCallNode = widget.isIncoming;
    _initCall();
  }

  Future<void> _initCall() async {
    try {
      final micOk = await _native.ensureMicPermission();
      if (!micOk) {
        throw StateError('microphone permission denied');
      }
      if (_isCaller) {
        // Order matters: media + peer connection first, then startCall
        // (it replaces the whole call node), then the offer signal.
        await _setupLocalMedia();
        await _firebase.startCall(isVideo: widget.isVideo);
        await _writeOffer();
      }
      _listenToCallState();
    } catch (_) {
      _failCall();
    }
  }

  Future<void> _setupLocalMedia() async {
    if (_localStream != null) return;
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': widget.isVideo ? {'facingMode': 'user'} : false,
    });
    await _localRenderer.initialize();
    _localRenderer.srcObject = _localStream;
    await _remoteRenderer.initialize();

    _pc = await createPeerConnection(_rtcConfig);
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }
    _pc!.onIceCandidate = (candidate) async {
      final c = candidate.candidate;
      if (c == null || c.isEmpty) return;
      try {
        await _firebase.writeCallIceCandidate(
          c,
          candidate.sdpMid,
          candidate.sdpMLineIndex,
        );
      } catch (_) {}
    };
    _pc!.onTrack = (event) {
      if (!widget.isVideo || event.track.kind != 'video') return;
      if (event.streams.isEmpty) return;
      _remoteStream = event.streams.first;
      _remoteRenderer.srcObject = _remoteStream;
      if (mounted && !_disposed) setState(() => _remoteVideoReady = true);
    };
    _pc!.onAddStream = (stream) {
      if (!widget.isVideo) return;
      _remoteStream = stream;
      _remoteRenderer.srcObject = stream;
      if (mounted && !_disposed) setState(() => _remoteVideoReady = true);
    };
    _pc!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _failCall();
      }
    };
    await _applySpeaker();
  }

  Future<void> _writeOffer() async {
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    final sdp = offer.sdp;
    if (sdp == null || sdp.isEmpty) {
      throw StateError('empty offer sdp');
    }
    await _firebase.writeCallSignal('offer', sdp);
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
      _lastCallRaw = raw;

      final newStatus = raw['status']?.toString() ?? 'ringing';
      if (newStatus == 'connected' && _callStatus != 'connected') {
        _startDurationTimer();
      }
      if (mounted && newStatus != _callStatus) {
        setState(() => _callStatus = newStatus);
      }

      _handleRemoteSdp(raw);
      _handleRemoteIce(raw);
    });
  }

  /// Applies the remote SDP (answer for the caller, offer for the callee)
  /// exactly once; for the callee it answers immediately after.
  Future<void> _handleRemoteSdp(Map<dynamic, dynamic> raw) async {
    final pc = _pc;
    if (pc == null || _remoteDescSet || _sdpInFlight) return;
    final signal = raw['signal'];
    if (signal is! Map) return;

    String? sdpType;
    String? sdp;
    for (final entry in signal.entries) {
      if (entry.key.toString() == _firebase.myPeerId) continue;
      if (entry.value is! Map) continue;
      final v = entry.value as Map;
      final t = v['type']?.toString();
      final s = v['sdp']?.toString();
      if (s == null || s.isEmpty) continue;
      if ((_isCaller && t == 'answer') || (!_isCaller && t == 'offer')) {
        sdpType = t;
        sdp = s;
        break;
      }
    }
    if (sdp == null || sdpType == null) return;

    _sdpInFlight = true;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, sdpType));
      _remoteDescSet = true;
      await _flushPendingIce();
      if (!_isCaller) {
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        final answerSdp = answer.sdp;
        if (answerSdp != null && answerSdp.isNotEmpty) {
          await _firebase.writeCallSignal('answer', answerSdp);
        }
      }
    } catch (_) {
      // Bad SDP or signalling race; connection-state failure closes the call.
    } finally {
      _sdpInFlight = false;
    }
  }

  /// Buffers remote ICE seen before the remote description is applied,
  /// deduplicates by `peerId/pushId`, and forwards the rest to the PC.
  void _handleRemoteIce(Map<dynamic, dynamic> raw) {
    final ice = raw['ice'];
    if (ice is! Map) return;
    ice.forEach((peerKey, entries) {
      if (peerKey.toString() == _firebase.myPeerId) return;
      if (entries is! Map) return;
      entries.forEach((pushId, value) {
        if (value is! Map) return;
        if (!_seenIce.add('$peerKey/$pushId')) return;
        final candidateStr = value['candidate']?.toString();
        if (candidateStr == null || candidateStr.isEmpty) return;
        _addIce(
          RTCIceCandidate(
            candidateStr,
            value['sdpMid']?.toString(),
            (value['sdpMLineIndex'] as num?)?.toInt(),
          ),
        );
      });
    });
  }

  void _addIce(RTCIceCandidate candidate) {
    final pc = _pc;
    if (pc == null || !_remoteDescSet) {
      _pendingIce.add(candidate);
      return;
    }
    pc.addCandidate(candidate).catchError((_) {});
  }

  Future<void> _flushPendingIce() async {
    while (_pendingIce.isNotEmpty) {
      final pc = _pc;
      if (pc == null || !_remoteDescSet) return;
      final candidate = _pendingIce.removeAt(0);
      try {
        await pc.addCandidate(candidate);
      } catch (_) {}
    }
  }

  Future<void> _acceptIncomingCall() async {
    if (_accepting) return;
    _accepting = true;
    try {
      await _firebase.acceptCall();
      if (mounted) {
        setState(() => _callStatus = 'connected');
        _startDurationTimer();
      }
      // Media and the peer connection only start after the user accepts.
      await _setupLocalMedia();
      await _handleRemoteSdp(_lastCallRaw ?? const {});
    } catch (_) {
      _failCall();
    }
  }

  Future<void> _endCall() async {
    try {
      await _firebase.endCall();
    } catch (_) {}
    _closeCallScreen();
  }

  Future<void> _failCall() async {
    if (_disposed || _isClosing || !mounted) return;
    _isClosing = true;
    try {
      await _firebase.endCall();
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Call unavailable')));
    Navigator.of(context).pop();
  }

  void _closeCallScreen() {
    if (_disposed || _isClosing || !mounted) return;
    _isClosing = true;
    Navigator.of(context).pop();
  }

  void _startDurationTimer() {
    if (_durationTimer?.isActive ?? false) return;
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsedSeconds++;
      });
    });
  }

  void _toggleMute() {
    setState(() => _isMuted = !_isMuted);
    for (final track in _localStream?.getAudioTracks() ?? const []) {
      track.enabled = !_isMuted;
    }
  }

  void _toggleCamera() {
    if (!widget.isVideo) return;
    setState(() => _isCameraOff = !_isCameraOff);
    for (final track in _localStream?.getVideoTracks() ?? const []) {
      track.enabled = !_isCameraOff;
    }
  }

  Future<void> _toggleSpeaker() async {
    setState(() => _isSpeakerOn = !_isSpeakerOn);
    await _applySpeaker();
  }

  Future<void> _applySpeaker() async {
    try {
      await Helper.setSpeakerphoneOn(_isSpeakerOn);
    } catch (_) {}
  }

  Future<void> _teardownWebRTC() async {
    if (_tornDown) return;
    _tornDown = true;
    try {
      final pc = _pc;
      _pc = null;
      if (pc != null) {
        await pc.close();
        await pc.dispose();
      }
      final local = _localStream;
      _localStream = null;
      if (local != null) {
        for (final track in local.getTracks()) {
          try {
            await track.stop();
          } catch (_) {}
        }
        await local.dispose();
      }
      final remote = _remoteStream;
      _remoteStream = null;
      if (remote != null) {
        await remote.dispose();
      }
      _localRenderer.srcObject = null;
      await _localRenderer.dispose();
      _remoteRenderer.srcObject = null;
      await _remoteRenderer.dispose();
    } catch (_) {}
    try {
      await Helper.setSpeakerphoneOn(false);
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _durationTimer?.cancel();
    _callSub?.cancel();
    _teardownWebRTC();
    _native.stopAudio();
    // Swiping back hangs up for everyone; a no-op if the node is already gone.
    _firebase.endCall().catchError((_) {});
    super.dispose();
  }

  String _formatDuration(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Widget _buildAvatarStage() {
    return Container(
      width: widget.isVideo ? 240 : 150,
      height: widget.isVideo ? 300 : 150,
      decoration: BoxDecoration(
        shape: widget.isVideo ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: widget.isVideo ? BorderRadius.circular(28) : null,
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
            widget.isVideo ? Icons.videocam : Icons.person,
            size: 64,
            color: Colors.white,
          ),
          if (widget.isVideo) ...[
            const SizedBox(height: 12),
            Text(
              _callStatus == 'connected' ? 'Live P2P Stream' : 'Camera Ready',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVideoStage() {
    if (_remoteVideoReady) {
      return Stack(
        children: [
          Positioned.fill(
            child: RTCVideoView(
              _remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
          if (_localStream != null)
            Positioned(
              top: 16,
              right: 16,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 104,
                  height: 148,
                  child: RTCVideoView(
                    _localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),
        ],
      );
    }
    if (_localStream != null) {
      // Full-stage mirrored self view until the partner's track arrives.
      return SizedBox.expand(
        child: RTCVideoView(
          _localRenderer,
          mirror: true,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
      );
    }
    return Center(child: _buildAvatarStage());
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
                    widget.isVideo
                        ? 'Peer-to-Peer Video Call'
                        : 'Peer-to-Peer Voice Call',
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

            // Avatar / video stage
            if (widget.isVideo)
              Expanded(child: _buildVideoStage())
            else
              _buildAvatarStage(),

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
                          onTap: _toggleMute,
                        ),
                        if (widget.isVideo)
                          _buildCallActionButton(
                            icon: _isCameraOff
                                ? Icons.videocam_off
                                : Icons.videocam,
                            label: _isCameraOff ? 'Cam Off' : 'Camera',
                            color: _isCameraOff
                                ? Colors.redAccent
                                : Colors.white12,
                            onTap: _toggleCamera,
                          ),
                        _buildCallActionButton(
                          icon: _isSpeakerOn
                              ? Icons.volume_up
                              : Icons.volume_down,
                          label: 'Speaker',
                          color: _isSpeakerOn
                              ? Colors.blueAccent
                              : Colors.white12,
                          onTap: _toggleSpeaker,
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
