import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/firebase_service.dart';
import 'chat_screen.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

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
    await _firebase.markRoomPaired();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const ChatScreen()),
    );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair Device'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // My Code Section
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    const Icon(
                      Icons.phone_android,
                      size: 48,
                      color: Colors.deepPurple,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Your Pair Code',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_isLoading)
                      const CircularProgressIndicator()
                    else if (_myCode != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey[900],
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _myCode!,
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 8,
                            color: Colors.green,
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    const Text(
                      'Share this code with your partner',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 32),

            // Divider
            Row(
              children: [
                Expanded(child: Divider(color: Colors.grey[600])),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text('OR', style: TextStyle(color: Colors.grey[600])),
                ),
                Expanded(child: Divider(color: Colors.grey[600])),
              ],
            ),

            const SizedBox(height: 32),

            // Join Section
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    const Icon(Icons.link, size: 48, color: Colors.orange),
                    const SizedBox(height: 16),
                    const Text(
                      'Join Partner',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _codeController,
                      textAlign: TextAlign.center,
                      maxLength: 6,
                      textCapitalization: TextCapitalization.characters,
                      style: const TextStyle(
                        fontSize: 24,
                        letterSpacing: 8,
                        fontWeight: FontWeight.bold,
                      ),
                      decoration: InputDecoration(
                        hintText: 'CODE',
                        hintStyle: TextStyle(color: Colors.grey[600]),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: Colors.grey[900],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _joinRoom,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isLoading
                            ? const CircularProgressIndicator(
                                color: Colors.white,
                              )
                            : const Text(
                                'JOIN',
                                style: TextStyle(fontSize: 18),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
    );
  }
}
