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

  /// How long a call may ring before it is logged as missed and closed on
  /// both sides — an offline callee must not leave the caller "Ringing…"
  /// forever.
  ///
  /// Long enough to outlast a slow incoming screen: at 45s a callee whose
  /// phone started ringing late was still answering when this fired, and the
  /// timeout closed the call in their hand. An answered call is never cut by
  /// it either way (see [_onRingTimeout]).
  static const Duration ringTimeout = Duration(seconds: 60);

  /// 720p@30 capture target. Android already defaults to 1280x720, but the
  /// native parsers take plain numbers (their `ideal`-map handling is
  /// broken) and fall back to the closest camera format, so this pins the
  /// same crisp capture on platforms whose default is lower.
  static const Map<String, dynamic> _videoConstraints = {
    'facingMode': 'user',
    'width': 1280,
    'height': 720,
    'frameRate': 30,
  };

  /// Encoder profile for call video: give 720p room to breathe (2.5 Mbps
  /// ceiling), keep a modest floor so the picture never collapses to a blur
  /// on a slow link, and when the network dips, drop frames before letting
  /// the resolution smear.
  static const int _maxVideoBitrateBps = 2500000;
  static const int _minVideoBitrateBps = 250000;

  StreamSubscription<DatabaseEvent>? _callSub;
  Timer? _durationTimer;
  Timer? _ringTimer;
  Timer? _connectionWatchdog;

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
    if (widget.isIncoming) {
      // Ring on this phone until accepted, declined or disposed.
      _native.startRingtone();
    }
    _startRingTimer();
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
        // The node exists from here on — if the callee rejects before our
        // first stream event, the null snapshot must still close this screen
        // instead of leaving it on "Ringing…" forever.
        _hasSeenCallNode = true;
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
      'video': widget.isVideo ? _videoConstraints : false,
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
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        // Media lost (the peer hung up or vanished). If the end event never
        // arrives, this watchdog closes the call instead of leaving a live
        // screen counting up forever.
        _startConnectionWatchdog();
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _connectionWatchdog?.cancel();
      }
    };
    await _applySpeaker();
    await _applySendQuality();
  }

  /// Applies the encoder profile to the outgoing tracks. Best-effort: a
  /// platform that rejects a parameter must never block the call itself.
  Future<void> _applySendQuality() async {
    try {
      final pc = _pc;
      if (pc == null) return;
      final senders = await pc.getSenders();
      for (final sender in senders) {
        final track = sender.track;
        if (track == null || track.kind != 'video') continue;
        final params = sender.parameters;
        params.degradationPreference =
            RTCDegradationPreference.MAINTAIN_RESOLUTION;
        for (final encoding in params.encodings ?? const <RTCRtpEncoding>[]) {
          encoding.maxBitrate = _maxVideoBitrateBps;
          encoding.minBitrate = _minVideoBitrateBps;
          encoding.maxFramerate = 30;
          encoding.scaleResolutionDownBy = 1.0;
          encoding.priority = RTCPriorityType.high;
        }
        await sender.setParameters(params);
      }
    } catch (_) {
      // Quality hints are best-effort.
    }
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
        _ringTimer?.cancel();
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
    _native.stopRingtone();
    try {
      final accepted = await _firebase.acceptCall();
      if (!accepted) {
        // The caller hung up before accept landed — close instead of
        // resurrecting a dead call.
        _closeCallScreen();
        return;
      }
      if (mounted) {
        setState(() => _callStatus = 'connected');
        _ringTimer?.cancel();
        _startDurationTimer();
      }
      // Media and the peer connection only start after the user accepts.
      await _setupLocalMedia();
      await _handleRemoteSdp(_lastCallRaw ?? const {});
    } catch (_) {
      _failCall();
    }
  }

  /// How a user-initiated hangup is logged: a connected call completed; the
  /// caller cancelling while ringing leaves the callee a missed call; the
  /// callee hanging up while ringing is a decline, shown as rejected on both
  /// sides.
  String get _hangupOutcome => _callStatus == 'connected'
      ? 'completed'
      : (_isCaller ? 'missed' : 'declined');

  Future<void> _endCall() async {
    try {
      await _firebase.endCall(outcome: _hangupOutcome, callInfo: _lastCallRaw);
    } catch (_) {}
    _closeCallScreen();
  }

  Future<void> _failCall() async {
    if (_disposed || _isClosing || !mounted) return;
    _isClosing = true;
    try {
      await _firebase.endCall(outcome: _hangupOutcome, callInfo: _lastCallRaw);
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

  void _startRingTimer() {
    _ringTimer?.cancel();
    _ringTimer = Timer(ringTimeout, _onRingTimeout);
  }

  /// Closes a connected call whose media died without an end event. WebRTC
  /// can recover from a brief `disconnected`, so this waits out a grace
  /// period first.
  void _startConnectionWatchdog() {
    _connectionWatchdog?.cancel();
    _connectionWatchdog = Timer(const Duration(seconds: 8), () {
      if (_disposed || _isClosing || !mounted) return;
      if (_callStatus != 'connected') return; // ring timeout owns this phase
      _endCall();
    });
  }

  /// Nobody accepted in time: log the call as missed (even if this side is
  /// the callee — ringing out is not a decline) and close on both sides.
  ///
  /// The other phone's accept and this timer race at the deadline, and the
  /// worst outcome of that race is deleting a call the partner just answered
  /// — it drops a live call on both phones. So an answered call is adopted
  /// instead of ended: the local copy of the node settles the common case
  /// without a round-trip, and a fresh read covers the rest.
  Future<void> _onRingTimeout() async {
    if (_disposed || _isClosing || _callStatus == 'connected') return;
    if (_localCallIsConnected() || await _firebase.isCallConnected()) {
      _markConnected();
      return;
    }
    try {
      await _firebase.endCall(outcome: 'missed', callInfo: _lastCallRaw);
    } catch (_) {}
    _closeCallScreen();
  }

  /// True when the newest snapshot of the call node says it was answered.
  bool _localCallIsConnected() {
    final raw = _lastCallRaw;
    if (raw == null) return false;
    return raw['status']?.toString() == 'connected' ||
        raw['connectedAt'] != null;
  }

  /// Moves the screen to the in-call UI when the call turns out to be
  /// answered even though the status change never reached it — without this
  /// the screen would keep the ringing layout (and the ringtone) on a live
  /// call.
  void _markConnected() {
    if (_disposed || !mounted || _callStatus == 'connected') return;
    _native.stopRingtone();
    _ringTimer?.cancel();
    setState(() => _callStatus = 'connected');
    _startDurationTimer();
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
    _ringTimer?.cancel();
    _connectionWatchdog?.cancel();
    _callSub?.cancel();
    _teardownWebRTC();
    _native.stopAudio();
    _native.stopRingtone();
    // Swiping back hangs up for everyone; a no-op if the node is already gone.
    _firebase
        .endCall(outcome: _hangupOutcome, callInfo: _lastCallRaw)
        .catchError((_) {});
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
              // Below the floating header (lock row + name + timer).
              top: MediaQuery.of(context).padding.top + 124,
              right: 12,
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

    if (widget.isVideo) {
      return _buildVideoLayout(statusLabel, isRingingIncoming);
    }
    return _buildVoiceLayout(statusLabel, isRingingIncoming);
  }

  /// WhatsApp-style: video fills the whole screen and the header, timer and
  /// controls float on top of it behind gradient scrims.
  Widget _buildVideoLayout(String statusLabel, bool isRingingIncoming) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0914),
      body: Stack(
        children: [
          Positioned.fill(child: _buildVideoStage()),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xB3000000), Color(0x00000000)],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 26),
                  child: Column(
                    children: [
                      _buildTypeRow(),
                      const SizedBox(height: 10),
                      const Text(
                        'Secret Partner',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          shadows: [
                            Shadow(blurRadius: 8, color: Colors.black54),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        statusLabel,
                        style: TextStyle(
                          color: _callStatus == 'connected'
                              ? Colors.greenAccent
                              : Colors.amberAccent,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          shadows: const [
                            Shadow(blurRadius: 8, color: Colors.black54),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xCC000000)],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.only(
                    top: 28,
                    bottom: 20,
                    left: 24,
                    right: 24,
                  ),
                  child: isRingingIncoming
                      ? _buildRingControls()
                      : _buildActiveControls(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVoiceLayout(String statusLabel, bool isRingingIncoming) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0914),
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: _buildTypeRow(),
            ),

            const Spacer(),

            // Avatar stage
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
                  ? _buildRingControls()
                  : _buildActiveControls(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.lock_outline, size: 16, color: Colors.greenAccent),
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
    );
  }

  Widget _buildRingControls() {
    return Row(
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
    );
  }

  Widget _buildActiveControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildCallActionButton(
          icon: _isMuted ? Icons.mic_off : Icons.mic,
          label: _isMuted ? 'Unmute' : 'Mute',
          color: _isMuted ? Colors.orangeAccent : Colors.white12,
          onTap: _toggleMute,
        ),
        if (widget.isVideo)
          _buildCallActionButton(
            icon: _isCameraOff ? Icons.videocam_off : Icons.videocam,
            label: _isCameraOff ? 'Cam Off' : 'Camera',
            color: _isCameraOff ? Colors.redAccent : Colors.white12,
            onTap: _toggleCamera,
          ),
        _buildCallActionButton(
          icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_down,
          label: 'Speaker',
          color: _isSpeakerOn ? Colors.blueAccent : Colors.white12,
          onTap: _toggleSpeaker,
        ),
        _buildCallActionButton(
          icon: Icons.call_end,
          label: 'End',
          color: Colors.redAccent,
          onTap: _endCall,
        ),
      ],
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
