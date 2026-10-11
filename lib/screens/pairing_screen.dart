import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/firebase_service.dart';
import 'chat_screen.dart';
import '../widgets/messaging_style.dart';

class PairingScreen extends StatefulWidget {
  final bool returnToDirectory;
  const PairingScreen({super.key, this.returnToDirectory = false});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final FirebaseService _firebase = FirebaseService();
  final TextEditingController _codeController = TextEditingController();
  StreamSubscription<DatabaseEvent>? _membersSub;
  bool _isLoading = false;
  bool _hasNavigated = false;
  String? _myCode;
  String? _error;

  @override
  void initState() {
    super.initState();
    _generateCode();
  }

  @override
  void dispose() {
    _membersSub?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _generateCode() async {
    setState(() => _isLoading = true);
    try {
      await _firebase.createRoom();
      if (!mounted) return;
      setState(() {
        _myCode = _firebase.getShortCode();
        _isLoading = false;
      });
      _listenForPartnerJoin();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to create room';
        _isLoading = false;
      });
    }
  }

  void _listenForPartnerJoin() {
    _membersSub?.cancel();
    _membersSub = _firebase.getRoomMembersStream().listen((event) {
      final raw = event.snapshot.value;
      if (raw is Map) {
        final hasPartner = raw.keys.any(
          (key) => key.toString() != _firebase.myPeerId,
        );
        if (hasPartner) {
          _openChat();
        }
      }
    });
  }

  Future<void> _openChat() async {
    if (!mounted || _hasNavigated) return;
    _hasNavigated = true;
    _membersSub?.cancel();
    try {
      await _firebase.markRoomPaired();
    } catch (_) {
      if (mounted) {
        setState(() {
          _hasNavigated = false;
          _isLoading = false;
          _error = 'Could not save pairing. Please try again.';
        });
      }
      return;
    }
    if (!mounted) return;
    if (widget.returnToDirectory) {
      Navigator.pop(context);
    } else {
      Navigator.pushReplacement(context, messagingRoute(const ChatScreen()));
    }
  }

  Future<void> _joinRoom() async {
    final code = _codeController.text.trim().toUpperCase();
    if (!FirebaseService.isValidRoomCode(code)) {
      setState(() => _error = 'Please enter a valid 6-character code');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final success = await _firebase.joinRoom(code);
      if (!mounted) return;
      if (success) {
        _openChat();
      } else {
        setState(() {
          _error = 'Room not found';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to join room';
        _isLoading = false;
      });
    }
  }

  /// One card of the pairing screen; both halves share the same shape so the
  /// screen reads as a pair of choices rather than two different designs.
  Widget _card({required Widget child}) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: const Color(0xFFF7F8FA),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFE7E9EE)),
    ),
    child: child,
  );

  Widget _cardTitle(IconData icon, String title, String subtitle) => Column(
    children: [
      Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: chatGreen.withValues(alpha: 0.10),
        ),
        child: Icon(icon, size: 26, color: chatGreen),
      ),
      const SizedBox(height: 14),
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(
        subtitle,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, color: Colors.grey[600], height: 1.3),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Pair Device'),
        backgroundColor: Colors.white,
        foregroundColor: chatInk,
        elevation: 0,
        scrolledUnderElevation: 0.5,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(
          children: [
            // My code
            _card(
              child: Column(
                children: [
                  _cardTitle(
                    Icons.phone_android,
                    'Your Pair Code',
                    'Share this code with your partner',
                  ),
                  const SizedBox(height: 18),
                  if (_isLoading && _myCode == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: CircularProgressIndicator(color: chatGreen),
                    )
                  else if (_myCode != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE7E9EE)),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _myCode!,
                          style: const TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 8,
                            color: chatGreen,
                          ),
                        ),
                      ),
                    ),
                  if (_myCode != null) ...[
                    const SizedBox(height: 6),
                    TextButton.icon(
                      icon: const Icon(Icons.copy, size: 18, color: chatGreen),
                      label: const Text(
                        'Copy pairing code',
                        style: TextStyle(color: chatGreen),
                      ),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _myCode!));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Pairing code copied'),
                            ),
                          );
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 22),

            // Divider
            Row(
              children: [
                Expanded(child: Divider(color: Colors.grey[300])),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Text(
                    'OR',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                Expanded(child: Divider(color: Colors.grey[300])),
              ],
            ),

            const SizedBox(height: 22),

            // Join
            _card(
              child: Column(
                children: [
                  _cardTitle(
                    Icons.link,
                    'Join Partner',
                    "Enter your partner's code to link this phone",
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _codeController,
                    textAlign: TextAlign.center,
                    maxLength: 6,
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(
                      fontSize: 24,
                      letterSpacing: 8,
                      fontWeight: FontWeight.bold,
                      color: chatInk,
                    ),
                    decoration: InputDecoration(
                      hintText: 'CODE',
                      counterText: '',
                      hintStyle: TextStyle(color: Colors.grey[400]),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFFE7E9EE)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: chatGreen,
                          width: 1.4,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _isLoading ? null : _joinRoom,
                      style: FilledButton.styleFrom(
                        backgroundColor: chatGreen,
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.4,
                              ),
                            )
                          : const Text(
                              'JOIN',
                              style: TextStyle(
                                fontSize: 16,
                                letterSpacing: 1,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),

            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFD64541)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
