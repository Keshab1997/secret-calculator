import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/firebase_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/messaging_style.dart';
import 'chat_screen.dart';

class PairingScreen extends StatefulWidget {
  final bool returnToDirectory;
  const PairingScreen({super.key, this.returnToDirectory = false});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final FirebaseService _firebase = FirebaseService();
  final TextEditingController _personalIdController = TextEditingController();
  final TextEditingController _legacyCodeController = TextEditingController();
  StreamSubscription<DatabaseEvent>? _membersSub;
  late final Stream<DatabaseEvent> _incomingRequestsStream;
  late final Stream<DatabaseEvent> _outgoingRequestsStream;
  bool _isLoading = false;
  bool _loadingPersonalId = true;
  bool _hasNavigated = false;
  String? _personalId;
  String? _myInvite;
  String? _busyRequestId;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _personalId = _firebase.personalId;
    _loadingPersonalId = _personalId == null;
    _incomingRequestsStream = _firebase.incomingContactRequests();
    _outgoingRequestsStream = _firebase.sentContactRequests();
    unawaited(_loadPersonalId());
  }

  @override
  void dispose() {
    _membersSub?.cancel();
    _personalIdController.dispose();
    _legacyCodeController.dispose();
    super.dispose();
  }

  Future<void> _loadPersonalId() async {
    try {
      final id = await _firebase.getOrCreatePersonalId();
      if (mounted) {
        setState(() {
          _personalId = id;
          _loadingPersonalId = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingPersonalId = false;
          if (_personalId == null) {
            _error = _personalIdError();
          }
        });
      }
    }
  }

  /// A missing Auth identity is a Firebase configuration problem, not a network
  /// one, so report the configuration problem the service actually saw (no
  /// Firebase config in this build, provider switched off, or a refused sign-in)
  /// instead of guessing: "check your connection" and "enable Anonymous Auth"
  /// send the person holding the phone to two different places.
  String _personalIdError() {
    if (_firebase.authUid == null) return _firebase.authSetupHint;
    return 'Could not load your Personal ID. Check your connection and Firebase setup.';
  }

  Future<void> _sendRequest() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _notice = null;
    });
    try {
      await _firebase.sendContactRequest(_personalIdController.text);
      if (!mounted) return;
      setState(() {
        _notice = 'Request sent. They must approve it before a private room is created.';
        _personalIdController.clear();
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(error);
        _isLoading = false;
      });
    }
  }

  String _friendlyError(Object error) {
    if (error is FormatException) return error.message;
    if (error is FirebaseFunctionsException) {
      return switch (error.code) {
        'not-found' =>
          'No account has that Personal ID. Check it and try again.',
        'already-exists' =>
          error.message ??
              'You are already connected or have a pending request.',
        'resource-exhausted' =>
          error.message ?? 'Too many requests. Try again later.',
        'permission-denied' => 'This request is not available to your account.',
        _ => 'Could not complete the request. Check your connection and try again.',
      };
    }
    return 'Could not complete the request. Check your connection and Firebase setup.';
  }

  Future<void> _copyPersonalId() async {
    final id = _personalId;
    if (id == null) return;
    await Clipboard.setData(
      ClipboardData(text: FirebaseService.formatPersonalId(id)),
    );
    if (mounted) {
      AppToast.show(context, 'Personal ID copied', kind: AppToastKind.success);
    }
  }

  Future<void> _handleRequest(String requestId, {required bool accept}) async {
    setState(() {
      _busyRequestId = requestId;
      _error = null;
      _notice = null;
    });
    try {
      if (accept) {
        await _firebase.acceptContactRequest(requestId);
        if (!mounted) return;
        if (widget.returnToDirectory) {
          Navigator.pop(context);
        } else {
          Navigator.pushReplacement(
            context,
            messagingRoute(const ChatScreen()),
          );
        }
      } else {
        await _firebase.rejectContactRequest(requestId);
        if (!mounted) return;
        setState(() {
          _notice = 'Request declined. No room was created.';
          _busyRequestId = null;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(error);
        _busyRequestId = null;
      });
    }
  }

  Future<void> _generateLegacyInvite() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await _firebase.createRoom();
      if (!mounted) return;
      setState(() {
        _myInvite = _firebase.currentInviteCode;
        _isLoading = false;
      });
      _listenForPartnerJoin();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not create a legacy secure invite. Check your connection and Firebase setup.';
        _isLoading = false;
      });
    }
  }

  void _listenForPartnerJoin() {
    _membersSub?.cancel();
    _membersSub = _firebase.getRoomMembersStream().listen((event) {
      final raw = event.snapshot.value;
      if (raw is Map) {
        final ownUid = _firebase.authUid;
        final hasPartner =
            ownUid != null && raw.keys.any((key) => key.toString() != ownUid);
        if (hasPartner) _openLegacyChat();
      }
    });
  }

  Future<void> _openLegacyChat() async {
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

  Future<void> _joinLegacyRoom() async {
    final invitation = _legacyCodeController.text.trim();
    if (!FirebaseService.isValidInviteCode(invitation)) {
      setState(() => _error = 'Enter the complete legacy secure invite.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final success = await _firebase.joinRoom(invitation);
      if (!mounted) return;
      if (success) {
        await _openLegacyChat();
      } else {
        setState(() {
          _error = 'Invite is invalid, expired, or already paired.';
          _isLoading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Legacy secure pairing failed. Check your connection and try again.';
        _isLoading = false;
      });
    }
  }

  Widget _card({required Widget child}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: MessagingPalette.of(context).card,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: MessagingPalette.of(context).cardBorder),
    ),
    child: child,
  );

  List<MapEntry<String, Map<String, dynamic>>> _requestEntries(Object? value) {
    if (value is! Map) return const [];
    final result = <MapEntry<String, Map<String, dynamic>>>[];
    for (final entry in value.entries) {
      if (entry.key is String && entry.value is Map) {
        result.add(
          MapEntry(
            entry.key as String,
            Map<String, dynamic>.from(entry.value as Map),
          ),
        );
      }
    }
    result.sort((a, b) {
      final aTime = a.value['createdAt'];
      final bTime = b.value['createdAt'];
      return (bTime is num ? bTime.toInt() : 0).compareTo(
        aTime is num ? aTime.toInt() : 0,
      );
    });
    return result;
  }

  Widget _incomingRequests(MessagingPalette palette) {
    if (_firebase.authUid == null) return const SizedBox.shrink();
    return StreamBuilder<DatabaseEvent>(
      // Stable identity: rows above this card (error/notice text) come and
      // go, and a keyless child at a shifting position remounts — losing
      // the cached snapshot and resubscribing the stored stream.
      key: const ValueKey('incoming-requests'),
      stream: _incomingRequestsStream,
      builder: (context, snapshot) {
        final uid = _firebase.authUid;
        final requests = _requestEntries(snapshot.data?.snapshot.value)
            .where((entry) {
              if (entry.value['status'] == 'pending') return true;
              final awaitingLocalSetup =
                  entry.value['status'] == 'accepted' &&
                  entry.value['acceptedBy'] == uid &&
                  (entry.value['roomId'] is! String ||
                      !_firebase.pairedRooms.containsKey(
                        entry.value['roomId'] as String,
                      ));
              return awaitingLocalSetup;
            })
            .toList();
        if (requests.isEmpty) return const SizedBox.shrink();
        return _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Requests for you',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              for (final entry in requests) ...[
                if (entry != requests.first)
                  Divider(color: palette.cardBorder, height: 18),
                _incomingRequestTile(
                  entry,
                  alreadyApproved: entry.value['status'] == 'accepted',
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _incomingRequestTile(
    MapEntry<String, Map<String, dynamic>> entry, {
    required bool alreadyApproved,
  }) {
    final fromId = entry.value['fromPersonalId'];
    final requester = fromId is String
        ? FirebaseService.formatPersonalId(fromId)
        : 'A Secret Calculator user';
    final busy = _busyRequestId == entry.key;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          alreadyApproved
              ? 'Approval saved — finish setup for $requester'
              : 'Request from $requester',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (!alreadyApproved)
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => _handleRequest(entry.key, accept: false),
                icon: const Icon(Icons.close, size: 18),
                label: const Text('Decline'),
              ),
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => _handleRequest(entry.key, accept: true),
              style: FilledButton.styleFrom(backgroundColor: chatGreen),
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check, size: 18),
              label: Text(alreadyApproved ? 'Finish setup' : 'Accept'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _outgoingRequests() {
    if (_firebase.authUid == null) return const SizedBox.shrink();
    return StreamBuilder<DatabaseEvent>(
      // Stable identity, same reason as the incoming requests above.
      key: const ValueKey('outgoing-requests'),
      stream: _outgoingRequestsStream,
      builder: (context, snapshot) {
        final requests = _requestEntries(snapshot.data?.snapshot.value)
            .where(
              (entry) =>
                  entry.value['status'] == 'pending' ||
                  entry.value['status'] == 'rejected',
            )
            .toList();
        if (requests.isEmpty) return const SizedBox.shrink();
        return _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your requests',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              for (final entry in requests)
                Material(
                  color: Colors.transparent,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      entry.value['status'] == 'pending'
                          ? Icons.hourglass_top_rounded
                          : Icons.block_outlined,
                      color: entry.value['status'] == 'pending'
                          ? chatGreen
                          : MessagingPalette.of(context).sub,
                    ),
                    title: Text(
                      entry.value['status'] == 'pending'
                          ? 'Waiting for approval'
                          : 'Request declined',
                    ),
                    subtitle: Text(
                      entry.value['targetPersonalId'] is String
                          ? FirebaseService.formatPersonalId(
                              entry.value['targetPersonalId'] as String,
                            )
                          : 'Personal ID request',
                    ),
                    dense: true,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _copyLegacyInvite() async {
    final invite = _myInvite;
    if (invite == null) return;
    await Clipboard.setData(ClipboardData(text: invite));
    if (mounted) {
      AppToast.show(
        context,
        'Legacy invite copied',
        kind: AppToastKind.success,
      );
    }
  }

  Widget _legacySection() => Material(
    color: MessagingPalette.of(context).card,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: MessagingPalette.of(context).cardBorder),
    ),
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      key: const PageStorageKey<String>('legacy-pairing'),
      onExpansionChanged: (expanded) {
        if (expanded && _myInvite == null && !_isLoading) {
          unawaited(_generateLegacyInvite());
        }
      },
      leading: const Icon(Icons.key_outlined, color: chatGreen),
      title: const Text('Legacy secure invite'),
      subtitle: const Text('For people who already use a room invite'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        if (_myInvite != null) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Your invite',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  // Same PageStorage slot trap as the invite field below:
                  // without a key of its own, this selectable's internal
                  // scrollable restores from the tile's saved *bool* under
                  // 'legacy-pairing' and crashes casting it to a double
                  // offset — the invite only has to finish generating.
                  key: const PageStorageKey<String>('legacy-invite-code'),
                  _myInvite!,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
              IconButton(
                tooltip: 'Copy legacy invite',
                onPressed: _copyLegacyInvite,
                icon: const Icon(Icons.copy, color: chatGreen),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        TextField(
          // Unique PageStorage slot for this field's internal Scrollable. The
          // ExpansionTile above saves a *bool* (its expanded state) under
          // 'legacy-pairing'; without a distinct key here the field's scroll
          // position restores from that same slot and crashes casting the bool
          // to a double offset.
          key: const PageStorageKey<String>('legacy-invite-field'),
          controller: _legacyCodeController,
          keyboardType: TextInputType.visiblePassword,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: 50,
          decoration: const InputDecoration(
            labelText: 'Full ROOMID.SECRET invite',
            counterText: '',
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _isLoading ? null : _joinLegacyRoom,
            child: const Text('Join using legacy invite'),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final palette = MessagingPalette.of(context);
    final displayedId = _personalId == null
        ? null
        : FirebaseService.formatPersonalId(_personalId!);
    return Scaffold(
      backgroundColor: palette.page,
      appBar: AppBar(
        title: const Text('Connect by Personal ID'),
        backgroundColor: palette.page,
        foregroundColor: palette.ink,
        elevation: 0,
        scrolledUnderElevation: 0.5,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
          children: [
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Your Personal ID',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy Personal ID',
                        onPressed: displayedId == null ? null : _copyPersonalId,
                        icon: const Icon(Icons.copy, color: chatGreen),
                      ),
                    ],
                  ),
                  if (displayedId == null && _loadingPersonalId)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: LinearProgressIndicator(color: chatGreen),
                    )
                  else if (displayedId == null)
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _loadingPersonalId = true;
                          _error = null;
                        });
                        unawaited(_loadPersonalId());
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Personal ID unavailable — retry'),
                    )
                  else
                    SelectableText(
                      displayedId,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 22,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w700,
                        color: chatGreen,
                      ),
                    ),
                  const SizedBox(height: 7),
                  Text(
                    'This ID belongs to this app installation. Reinstalling or changing phones can give you a new ID.',
                    style: TextStyle(color: palette.sub, height: 1.35),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Add a contact',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _personalIdController,
                    textCapitalization: TextCapitalization.characters,
                    keyboardType: TextInputType.visiblePassword,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 12,
                    decoration: const InputDecoration(
                      labelText: 'Enter their 10-character Personal ID',
                      hintText: 'ABCDE-FG234',
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isLoading ? null : _sendRequest,
                      style: FilledButton.styleFrom(
                        backgroundColor: chatGreen,
                        minimumSize: const Size.fromHeight(48),
                      ),
                      icon: _isLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.person_add_alt_1),
                      label: Text(_isLoading ? 'Please wait…' : 'Send request'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _card(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, color: palette.sub, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'The recipient must approve before a room is created. Personal IDs discover accounts, but the server relays the first public keys without proving the other person’s identity. Verify the ID through a trusted channel if man-in-the-middle protection matters.',
                      style: TextStyle(
                        color: palette.sub,
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Color(0xFFD64541))),
            ],
            if (_notice != null) ...[
              const SizedBox(height: 12),
              Text(_notice!, style: const TextStyle(color: chatGreen)),
            ],
            const SizedBox(height: 12),
            _incomingRequests(palette),
            _outgoingRequests(),
            const SizedBox(height: 12),
            _legacySection(),
          ],
        ),
      ),
    );
  }
}
