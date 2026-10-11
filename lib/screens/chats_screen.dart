import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/encryption_service.dart';
import '../services/firebase_service.dart';
import '../widgets/messaging_style.dart';
import 'chat_screen.dart';
import 'call_screen.dart';
import 'pairing_screen.dart';
import 'profile_screen.dart';

class ChatsScreen extends StatefulWidget {
  final bool decoyMode;
  const ChatsScreen({super.key, this.decoyMode = false});
  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> with WidgetsBindingObserver {
  final _service = FirebaseService();
  final Map<String, List<StreamSubscription<DatabaseEvent>>> _subscriptions = {};
  final Map<String, Map> _rooms = {};
  String _query = '';
  String? _error;
  int _tab = 0;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!widget.decoyMode) {
      _subscribe();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) &&
        !_opening &&
        mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  void _subscribe() {
    for (final code in _subscriptions.keys.toList()) {
      if (!_service.pairedRooms.containsKey(code)) {
        for (final sub in _subscriptions.remove(code) ?? const []) {
          sub.cancel();
        }
        _rooms.remove(code);
      }
    }
    for (final code in _service.pairedRooms.keys) {
      if (_subscriptions.containsKey(code)) continue;
      _rooms.putIfAbsent(code, () => <String, dynamic>{});
      void putChild(String child, Object? value) {
        if (!mounted) return;
        setState(() {
          _rooms[code] = {
            ...?_rooms[code],
            child: value is Map ? value : <String, dynamic>{},
          };
          _error = null;
        });
      }

      void onError(Object _) {
        if (mounted) {
          setState(
            () => _error = 'Could not refresh chats. Check your connection.',
          );
        }
      }

      _subscriptions[code] = [
        _service.roomMessagesStream(code).listen(
          (event) => putChild('messages', event.snapshot.value),
          onError: onError,
        ),
        _service.roomChildStream(code, 'profiles').listen(
          (event) => putChild('profiles', event.snapshot.value),
          onError: onError,
        ),
        _service.roomChildStream(code, 'call').listen((event) {
          if (!mounted) return;
          final call = event.snapshot.value;
          final routeIsCurrent = ModalRoute.of(context)?.isCurrent == true;
          putChild('call', call);
          if (!_opening &&
              routeIsCurrent &&
              call is Map &&
              call['status'] == 'ringing' &&
              call['callerId'] != _service.peerId) {
            _incomingCall(code, call['type'] == 'video');
          }
        }, onError: onError),
      ];
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final subs in _subscriptions.values) {
      for (final sub in subs) {
        sub.cancel();
      }
    }
    super.dispose();
  }

  Future<void> _incomingCall(String code, bool video) async {
    _opening = true;
    try {
      await _service.selectRoom(code);
      if (!mounted) return;
      final route = messagingRoute(
        CallScreen(isVideo: video, isIncoming: true),
      );
      await Navigator.of(context).push(route);
      await route.completed;
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open incoming call.');
    } finally {
      _opening = false;
    }
  }

  Future<void> _open(String code, {bool? video}) async {
    if (_opening) return;
    _opening = true;
    try {
      await _service.selectRoom(code);
      if (!mounted) return;
      final profile = _service.partnerProfile(code, _rooms[code]?['profiles']);
      final route = messagingRoute(
        video == null
            ? ChatScreen(
                contactName: profile['name'] ?? 'Paired contact',
                contactPhoto: profile['photo'],
              )
            : CallScreen(isVideo: video),
      );
      await Navigator.of(context).push(route);
      await route.completed;
      if (mounted) {
        _subscribe();
        setState(() {});
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not open chat. Please try again.');
      }
    } finally {
      _opening = false;
    }
  }

  Future<void> _pair() async {
    if (_opening) return;
    _opening = true;
    final route = messagingRoute(const PairingScreen(returnToDirectory: true));
    await Navigator.of(context).push(route);
    await route.completed;
    _opening = false;
    if (mounted) {
      _subscribe();
      setState(() {});
    }
  }

  List<Map> _messages(String code) {
    final raw = _rooms[code]?['messages'];
    final now = DateTime.now().millisecondsSinceEpoch;
    final values = raw is Map
        ? raw.values
              .whereType<Map>()
              .where((m) => m['expiresAt'] is! int || m['expiresAt'] > now)
              .toList()
        : <Map>[];
    values.sort(
      (a, b) => ((b['timestamp'] as int?) ?? 0).compareTo(
        (a['timestamp'] as int?) ?? 0,
      ),
    );
    return values;
  }

  String _preview(String code, Map message) {
    if (message['callType'] != null) {
      return callLogText(
        callType: message['callType'] as String?,
        callSeconds: message['callSeconds'] as int?,
        callOutcome: message['callOutcome'] as String?,
        isMe: message['senderId'] == _service.peerId,
      ).title;
    }
    if (message['imageUrl'] != null) return 'Photo';
    if (message['audioData'] != null) return 'Voice message';
    try {
      final text = EncryptionService.withPassphrase(code)
          .decrypt(message['text'] as String);
      if (text.startsWith('sticker:v1:')) return 'Sticker';
      return text;
    } catch (_) {
      return 'Encrypted message';
    }
  }

  String _time(Object? value) {
    if (value is! int) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(value);
    final now = DateTime.now();
    if (date.year != now.year ||
        date.month != now.month ||
        date.day != now.day) {
      return '${date.day}/${date.month}';
    }
    return '${date.hour % 12 == 0 ? 12 : date.hour % 12}:${date.minute.toString().padLeft(2, '0')} ${date.hour < 12 ? 'am' : 'pm'}';
  }

  @override
  Widget build(BuildContext context) {
    final codes = widget.decoyMode
        ? <String>[]
        : (_service.pairedRooms.keys.where((code) {
              final p = _service.partnerProfile(
                code,
                _rooms[code]?['profiles'],
              );
              return '${p['name'] ?? 'Paired contact'} $code'
                  .toLowerCase()
                  .contains(_query.toLowerCase());
            }).toList()
              ..sort((a, b) {
                final ma = _messages(a), mb = _messages(b);
                return (mb.isEmpty ? 0 : (mb.first['timestamp'] as int? ?? 0))
                    .compareTo(
                      ma.isEmpty ? 0 : (ma.first['timestamp'] as int? ?? 0),
                    );
              }));
    final calls = <Map<String, dynamic>>[];
    for (final code in codes) {
      for (final m in _messages(code).where((m) => m['callType'] != null)) {
        calls.add({'room': code, 'message': m});
      }
    }
    calls.sort(
      (a, b) => (b['message']['timestamp'] as int).compareTo(
        a['message']['timestamp'] as int,
      ),
    );
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(
          _tab == 0
              ? 'Chats'
              : _tab == 1
              ? 'Calls'
              : 'You',
          style: const TextStyle(
            color: Color(0xFF168B53),
            fontWeight: FontWeight.bold,
            fontSize: 28,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Quick Hide to Calculator',
            icon: const Icon(Icons.calculate_outlined),
            onPressed: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
          ),
        ],
      ),
      body: _tab == 2
          ? widget.decoyMode
                // Decoy mode never exposes real security settings — the You
                // tab shows the same empty-state story as the chats list.
                ? _empty(
                    'Your profile',
                    'Pair a device to set up your profile.',
                    Icons.person_outline,
                  )
                : const ProfileScreen()
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: TextField(
                    onChanged: (value) => setState(() => _query = value),
                    decoration: InputDecoration(
                      hintText: 'Search paired contacts',
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      fillColor: const Color(0xFFF4F3F1),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(30),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                Expanded(
                  child: _tab == 0
                      ? codes.isEmpty
                            ? _empty(
                                'Your private conversations',
                                'Pair a device to start chatting. Your contacts appear here.',
                                Icons.forum_outlined,
                              )
                            : ListView.builder(
                                itemCount: codes.length,
                                itemBuilder: (_, index) {
                                  final code = codes[index],
                                      messages = _messages(code);
                                  final profile = _service.partnerProfile(
                                    code,
                                    _rooms[code]?['profiles'],
                                  );
                                  final unread = messages
                                      .where(
                                        (m) =>
                                            m['senderId'] != _service.peerId &&
                                            m['seen'] != true,
                                      )
                                      .length;
                                  return ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    leading: ProfileAvatar(
                                      photo: profile['photo'],
                                    ),
                                    title: Text(
                                      profile['name'] ?? 'Paired contact',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 18),
                                    ),
                                    subtitle: Text(
                                      messages.isEmpty
                                          ? 'Say hello'
                                          : _preview(code, messages.first),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          messages.isEmpty
                                              ? ''
                                              : _time(
                                                  messages.first['timestamp'],
                                                ),
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: unread > 0
                                                ? chatGreen
                                                : Colors.grey,
                                          ),
                                        ),
                                        const SizedBox(height: 5),
                                        if (unread > 0)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 3,
                                            ),
                                            decoration: const BoxDecoration(
                                              color: chatGreen,
                                              borderRadius: BorderRadius.all(
                                                Radius.circular(20),
                                              ),
                                            ),
                                            child: Text(
                                              '$unread',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    onTap: () => _open(code),
                                  );
                                },
                              )
                      : calls.isEmpty
                      ? _empty(
                          'No calls yet',
                          'Voice and video call history will appear here.',
                          Icons.call_outlined,
                        )
                      : ListView.builder(
                          itemCount: calls.length,
                          itemBuilder: (_, index) {
                            final code = calls[index]['room'] as String,
                                message = calls[index]['message'] as Map;
                            final profile = _service.partnerProfile(
                              code,
                              _rooms[code]?['profiles'],
                            );
                            return ListTile(
                              leading: ProfileAvatar(photo: profile['photo']),
                              title: Text(profile['name'] ?? 'Paired contact'),
                              subtitle: Text(
                                '${_preview(code, message)} · ${_time(message['timestamp'])}',
                              ),
                              trailing: Icon(
                                message['callType'] == 'video'
                                    ? Icons.videocam_outlined
                                    : Icons.call_outlined,
                                color: chatGreen,
                              ),
                              onTap: () => _open(
                                code,
                                video: message['callType'] == 'video',
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: _tab == 0 && !widget.decoyMode
          ? FloatingActionButton(
              backgroundColor: chatGreen,
              foregroundColor: Colors.white,
              tooltip: 'Pair new contact',
              onPressed: _pair,
              child: const Icon(Icons.add_comment),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        backgroundColor: Colors.white,
        indicatorColor: const Color(0xFFD9FDD3),
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.call_outlined),
            selectedIcon: Icon(Icons.call),
            label: 'Calls',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'You',
          ),
        ],
      ),
    );
  }

  Widget _empty(String title, String subtitle, IconData icon) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 54, color: chatGreen),
          const SizedBox(height: 20),
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ],
      ),
    ),
  );
}
