import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/firebase_service.dart';
import '../services/update_service.dart';
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

class _ChatsScreenState extends State<ChatsScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _service = FirebaseService();
  final Map<String, List<StreamSubscription<DatabaseEvent>>> _subscriptions =
      {};
  final Map<String, Map> _rooms = {};
  String _query = '';
  String? _error;
  int _tab = 0;
  bool _opening = false;

  /// Drives the one-time settle-in of the list rows; finished after the first
  /// appearance, so later rebuilds (a new message, coming back from a chat)
  /// never replay it.
  late final AnimationController _intro;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    )..forward();
    if (!widget.decoyMode) {
      _subscribe();
      _maybeShowReleaseNotes();
    }
  }

  /// Right after installing a newer build, the latest release matches the
  /// installed version — its notes are the "what's new" for this launch.
  /// Shown once per tag (remembered in the local state file); a pending
  /// update is left to the profile's version tile.
  Future<void> _maybeShowReleaseNotes() async {
    final status = await UpdateService.checkForUpdate();
    if (!mounted) return;
    final tag = status.latestTag;
    if (tag == null || status.hasUpdate) return;
    if (_service.lastSeenRelease == tag) return;
    // Fire-and-forget: the state-file write must never hold up the dialog.
    unawaited(_service.markReleaseSeen(tag));
    if (!mounted) return;
    _showReleaseNotesDialog(tag, status.latestNotes);
  }

  void _showReleaseNotesDialog(String tag, String? notes) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('What’s new in $tag'),
        content: SingleChildScrollView(
          child: Text(
            (notes ?? 'Bug fixes and improvements.').trim(),
            style: Theme.of(dialogContext).textTheme.bodyMedium,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Okay'),
          ),
        ],
      ),
    );
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
        _service
            .roomMessagesStream(code)
            .listen(
              (event) => putChild('messages', event.snapshot.value),
              onError: onError,
            ),
        _service
            .roomChildStream(code, 'profiles')
            .listen(
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
    _intro.dispose();
    super.dispose();
  }

  Future<void> _incomingCall(String code, bool video) async {
    _opening = true;
    try {
      await _service.selectRoom(code);
      if (!mounted) return;
      final profile = _service.partnerProfile(code, _rooms[code]?['profiles']);
      final route = messagingRoute(
        CallScreen(
          isVideo: video,
          isIncoming: true,
          contactName: profile['name'],
        ),
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
            : CallScreen(isVideo: video, contactName: profile['name']),
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
        ? raw.values.whereType<Map>().where((message) {
            final expiresAt = message['expiresAt'];
            final timestamp = message['timestamp'];
            final seconds = message['expiresInSeconds'];
            final effectiveExpiry = expiresAt is int
                ? expiresAt
                : timestamp is int && seconds is int
                ? timestamp + seconds * 1000
                : null;
            return effectiveExpiry == null || effectiveExpiry > now;
          }).toList()
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
      final text = _service.decryptTextForRoom(code, message['text'] as String);
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
            final p = _service.partnerProfile(code, _rooms[code]?['profiles']);
            return '${p['name'] ?? 'Paired contact'} $code'
                .toLowerCase()
                .contains(_query.toLowerCase());
          }).toList()..sort((a, b) {
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
    final palette = MessagingPalette.of(context);
    return Scaffold(
      backgroundColor: palette.page,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(
          _tab == 0
              ? 'Chats'
              : _tab == 1
              ? 'Calls'
              : 'You',
          style: TextStyle(
            color: MessagingPalette.isDark(context)
                ? const Color(0xFF25D366)
                : const Color(0xFF168B53),
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
                if (!widget.decoyMode && _service.needsSecureRePair)
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF4D6),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFE7C66A)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.security, color: Color(0xFF8A6500)),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Security update: pair each contact again using a secure invite. Old room codes alone no longer open conversations.',
                            style: TextStyle(color: Color(0xFF594300)),
                          ),
                        ),
                        TextButton(onPressed: _pair, child: const Text('Pair')),
                        IconButton(
                          tooltip: 'Dismiss security notice',
                          visualDensity: VisualDensity.compact,
                          onPressed: () async {
                            await _service.acknowledgeSecureRePairNotice();
                            if (mounted) setState(() {});
                          },
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                  ),
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
                                action: FilledButton.icon(
                                  onPressed: _pair,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: chatGreen,
                                  ),
                                  icon: const Icon(Icons.add_comment_outlined),
                                  label: const Text('Pair a device'),
                                ),
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
                                  return _staggered(
                                    index,
                                    ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 8,
                                          ),
                                      leading: Hero(
                                        tag: 'chat-avatar-$code',
                                        child: ProfileAvatar(
                                          photo: profile['photo'],
                                        ),
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
                                                  : palette.sub,
                                            ),
                                          ),
                                          const SizedBox(height: 5),
                                          if (unread > 0)
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
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
                                    ),
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
                            final isCaller =
                                message['senderId'] == _service.peerId;
                            final log = callLogText(
                              callType: message['callType'] as String?,
                              callSeconds: message['callSeconds'] as int?,
                              callOutcome: message['callOutcome'] as String?,
                              isMe: isCaller,
                            );
                            final rowIcon = callRowIcon(
                              isMe: isCaller,
                              callOutcome: message['callOutcome'] as String?,
                            );
                            final missedMine =
                                (message['callOutcome'] ?? 'missed') ==
                                    'missed' &&
                                !isCaller;
                            final headline = log.detail.isEmpty
                                ? log.title
                                : '${log.title} · ${log.detail}';
                            return _staggered(
                              index,
                              ListTile(
                                leading: ProfileAvatar(photo: profile['photo']),
                                title: Text(
                                  profile['name'] ?? 'Paired contact',
                                  style: missedMine
                                      ? const TextStyle(
                                          color: Color(0xFFE5484D),
                                        )
                                      : null,
                                ),
                                subtitle: Text(
                                  '$headline · ${_time(message['timestamp'])}',
                                ),
                                trailing: Icon(
                                  rowIcon.icon,
                                  color: rowIcon.color,
                                ),
                                onTap: () => _open(
                                  code,
                                  video: message['callType'] == 'video',
                                ),
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
        backgroundColor: palette.page,
        indicatorColor: MessagingPalette.isDark(context)
            ? const Color(0xFF2A3942)
            : const Color(0xFFD9FDD3),
        onDestinationSelected: (index) {
          if (index != _tab) HapticFeedback.selectionClick();
          setState(() => _tab = index);
        },
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

  /// Rows settle in one after another on the list's first appearance. The
  /// offset grows with the index, so the cascade reads as one gesture rather
  /// than a list that is still loading.
  Widget _staggered(int index, Widget child) {
    if (index > 9) return child;
    final start = (index * 0.06).clamp(0.0, 0.55);
    final curved = CurvedAnimation(
      parent: _intro,
      curve: Interval(
        start,
        (start + 0.45).clamp(0.0, 1.0),
        curve: Curves.easeOutCubic,
      ),
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }

  /// The empty state: a soft badge, the explanation, and — where there is
  /// something to do about it — the action itself instead of a dead end.
  Widget _empty(
    String title,
    String subtitle,
    IconData icon, {
    Widget? action,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: chatGreen.withValues(alpha: 0.08),
            ),
            child: Icon(icon, size: 42, color: chatGreen),
          ),
          const SizedBox(height: 22),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: MessagingPalette.of(context).sub,
              fontSize: 13.5,
              height: 1.35,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 22), action],
        ],
      ),
    ),
  );
}
