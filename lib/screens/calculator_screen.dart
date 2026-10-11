import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_database/firebase_database.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/calculator_engine.dart';
import '../services/calculator_history_store.dart';
import '../services/firebase_service.dart';
import '../services/native_bridge_service.dart';
import '../services/notification_service.dart';
import '../widgets/messaging_style.dart';
import 'call_screen.dart';
import 'chats_screen.dart';
export '../models/calculator_engine.dart';

class CalculatorScreen extends StatefulWidget {
  final CalculatorHistoryStore? historyStore;
  const CalculatorScreen({super.key, this.historyStore});
  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  static const _background = Colors.black;
  static const _surface = Color(0xFF303030);
  static const _accent = Colors.orange;
  final CalculatorEngine _engine = CalculatorEngine();
  final FirebaseService _firebase = FirebaseService();
  final NativeBridgeService _native = NativeBridgeService();
  final NotificationService _notifications = NotificationService();
  final Map<String, StreamSubscription<DatabaseEvent>> _roomMessageSubs = {};
  final Map<String, Set<String>> _seenRoomMessageIds = {};
  final Map<String, StreamSubscription<DatabaseEvent>> _roomCallSubs = {};
  dynamic _lastHandledRingId;
  final ScrollController _expressionScroll = ScrollController();
  late final CalculatorHistoryStore _store;
  late final Future<void> _historyReady;
  List<CalculationEntry> _history = [];
  bool _historyAvailable = true;
  bool _unsavedHistory = false;
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
    _store = widget.historyStore ?? CalculatorHistoryStore();
    _historyReady = _loadHistory();
    _syncRoomMessageListeners();
    _syncRoomCallListeners();
  }

  Future<void> _loadHistory() async {
    try {
      _history = await _store.load();
    } catch (_) {
      _historyAvailable = false;
    }
    if (mounted) setState(() {});
  }

  void _syncRoomMessageListeners() {
    for (final code in _roomMessageSubs.keys.toList()) {
      if (!_firebase.pairedRooms.containsKey(code)) {
        _roomMessageSubs.remove(code)?.cancel();
        _seenRoomMessageIds.remove(code);
      }
    }
    for (final code in _firebase.pairedRooms.keys) {
      _roomMessageSubs.putIfAbsent(code, () {
        var primed = false;
        final seen = _seenRoomMessageIds.putIfAbsent(code, () => <String>{});
        return _firebase.roomLatestMessageStream(code).listen((event) {
          final messages = event.snapshot.value;
          if (messages is! Map) {
            primed = true;
            return;
          }
          String? incomingKey;
          for (final entry in messages.entries) {
            final key = entry.key.toString();
            final isNew = seen.add(key);
            final msg = entry.value;
            if (!primed || !isNew || msg is! Map) continue;
            final senderId = msg['senderId']?.toString() ?? '';
            final hasBody =
                msg['text'] != null ||
                msg['imageUrl'] != null ||
                msg['audioData'] != null;
            if (hasBody &&
                senderId.isNotEmpty &&
                senderId != _firebase.peerId) {
              incomingKey = key;
            }
          }
          primed = true;
          if (incomingKey != null && !_navigating) {
            _notifications.showFakeNotification(messageId: incomingKey);
          }
        }, onError: (_) {});
      });
    }
  }

  /// Rings for real calls even while the calculator is the visible screen.
  /// The chat list and open chat keep their own listeners, so this only acts
  /// while the calculator route is current (also true when the app sits
  /// backgrounded on the calculator).
  void _syncRoomCallListeners() {
    for (final code in _roomCallSubs.keys.toList()) {
      if (!_firebase.pairedRooms.containsKey(code)) {
        _roomCallSubs.remove(code)?.cancel();
      }
    }
    for (final code in _firebase.pairedRooms.keys) {
      _roomCallSubs.putIfAbsent(code, () {
        return _firebase.roomChildStream(code, 'call').listen((event) {
          final call = event.snapshot.value;
          if (call is! Map) return;
          if (call['status']?.toString() != 'ringing') return;
          final callerId = call['callerId']?.toString() ?? '';
          if (callerId.isEmpty || callerId == _firebase.peerId) return;
          final ringId = call['startedAt'];
          if (ringId == null || ringId == _lastHandledRingId) return;
          if (_navigating) return;
          if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
          _lastHandledRingId = ringId;
          _openIncomingCall(code, call['type']?.toString() == 'video', ringId);
        }, onError: (_) {});
      });
    }
  }

  Future<void> _openIncomingCall(
    String code,
    bool isVideo,
    Object ringId,
  ) async {
    _navigating = true;
    try {
      await _firebase.selectRoom(code);
      if (!mounted) return;
      _notifications.showFakeNotification(messageId: 'call_$ringId');
      unawaited(_native.setSecureScreen(true));
      await Navigator.push(
        context,
        messagingRoute(CallScreen(isVideo: isVideo, isIncoming: true)),
      );
    } catch (_) {
      // The node-driven UI catches up on the next snapshot; a missed call is
      // still logged on the caller side when the ring times out.
    } finally {
      unawaited(_native.setSecureScreen(false));
      _navigating = false;
      if (mounted) {
        _syncRoomMessageListeners();
        _syncRoomCallListeners();
      }
    }
  }

  @override
  void dispose() {
    for (final sub in _roomMessageSubs.values) {
      sub.cancel();
    }
    for (final sub in _roomCallSubs.values) {
      sub.cancel();
    }
    _expressionScroll.dispose();
    super.dispose();
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    _notice('Copied');
  }

  Future<void> _onButtonPressed(String value) async {
    if (_navigating) return;
    _engine.customCode = _firebase.customPasscode;
    _engine.decoyCode = _firebase.decoyPasscode;
    var navigate = false;
    setState(() {
      navigate = _engine.press(value);
    });
    if (navigate) {
      await _navigateToChat();
      return;
    }
    _scrollToEnd();
    final calculation = _engine.completedCalculation;
    if (calculation != null) {
      final entry = CalculationEntry.fromCalculation(calculation);
      await _historyReady;
      if (!_historyAvailable) {
        _notice('History unavailable. This result was not saved.');
        return;
      }
      _history = [
        entry,
        ..._history,
      ].take(CalculatorHistoryStore.maxEntries).toList();
      if (mounted) setState(() {});
      try {
        await _store.save(_history);
        if (mounted) setState(() => _unsavedHistory = false);
      } catch (_) {
        if (mounted) setState(() => _unsavedHistory = true);
        _notice('Could not save history on this device.');
      }
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _expressionScroll.hasClients) {
        _expressionScroll.jumpTo(_expressionScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _navigateToChat() async {
    _navigating = true;
    final isDecoy = _engine.unlockedDecoy;
    try {
      if (_firebase.biometricEnabled) {
        final verified = await _native.authenticateDevice();
        if (!verified || !mounted) return;
      }
      if (!mounted) return;
      unawaited(_native.setSecureScreen(true));
      await Navigator.push(
        context,
        messagingRoute(ChatsScreen(decoyMode: isDecoy)),
      );
    } finally {
      unawaited(_native.setSecureScreen(false));
      _navigating = false;
      if (mounted) {
        _syncRoomMessageListeners();
        _syncRoomCallListeners();
      }
    }
  }

  static String _groupNumber(String value) {
    if (value == 'Error' || value.contains('e')) return value;
    final parts = value.split('.');
    final whole = parts.first.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]},',
    );
    return parts.length == 2 ? '$whole.${parts[1]}' : whole;
  }

  String _entryExpression(CalculationEntry entry) {
    final engine = CalculatorEngine()..restoreExpression(entry.expression);
    return engine.displayExpression;
  }

  Future<void> _showHistory() async {
    await _historyReady;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refresh) {
          Future<void> removeEntries({CalculationEntry? entry}) async {
            if (entry == null) {
              final confirmed = await showDialog<bool>(
                context: sheetContext,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Clear calculation history?'),
                  content: const Text(
                    'Saved calculations on this device will be removed. This cannot be undone.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Clear history'),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
            }
            final next = entry == null
                ? <CalculationEntry>[]
                : _history.where((item) => item.id != entry.id).toList();
            try {
              await _store.save(next);
              _history = next;
              _historyAvailable = true;
              _unsavedHistory = false;
              if (mounted) setState(() {});
              if (sheetContext.mounted) refresh(() {});
            } catch (_) {
              _notice('Could not update history. Please try again.');
            }
          }

          void reuse(CalculationEntry entry, bool resultOnly) {
            setState(() {
              if (resultOnly) {
                _engine.useResult(entry.result);
              } else {
                _engine.restoreExpression(entry.expression);
              }
            });
            Navigator.pop(sheetContext);
            _scrollToEnd();
          }

          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(sheetContext).height * .82,
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 16, 12, 4),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'History',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (_history.isNotEmpty || !_historyAvailable)
                          IconButton(
                            tooltip: 'Clear history',
                            onPressed: () => removeEntries(),
                            icon: const Icon(
                              Icons.delete_sweep_outlined,
                              color: _accent,
                            ),
                          ),
                        IconButton(
                          tooltip: 'Close history',
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 8,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _unsavedHistory
                            ? 'Session only · History could not be saved'
                            : 'Saved on this device · Last 200 calculations',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ),
                  ),
                  Expanded(
                    child: !_historyAvailable
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                'History could not be read. Existing data has not been overwritten.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white70),
                              ),
                            ),
                          )
                        : _history.isEmpty
                        ? const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.history, color: _accent, size: 48),
                                SizedBox(height: 18),
                                Text(
                                  'No calculations yet',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                  ),
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Press = to save a calculation here.',
                                  style: TextStyle(color: Colors.white54),
                                ),
                              ],
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                            itemCount: _history.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 10),
                            itemBuilder: (_, index) {
                              final entry = _history[index];
                              final time = entry.createdAt.toLocal();
                              return Material(
                                color: _surface,
                                borderRadius: BorderRadius.circular(18),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(18),
                                  onTap: () => reuse(entry, false),
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      8,
                                      8,
                                      16,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                '${time.day}/${time.month}/${time.year} · ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                                                style: const TextStyle(
                                                  color: Colors.white38,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ),
                                            PopupMenuButton<String>(
                                              tooltip: 'Calculation options',
                                              iconColor: Colors.white54,
                                              onSelected: (action) {
                                                if (action == 'expression') {
                                                  reuse(entry, false);
                                                }
                                                if (action == 'result') {
                                                  reuse(entry, true);
                                                }
                                                if (action == 'copy') {
                                                  _copy(
                                                    '${_entryExpression(entry)} = ${entry.result}',
                                                  );
                                                }
                                                if (action == 'delete') {
                                                  removeEntries(entry: entry);
                                                }
                                              },
                                              itemBuilder: (_) => const [
                                                PopupMenuItem(
                                                  value: 'expression',
                                                  child: Text('Use expression'),
                                                ),
                                                PopupMenuItem(
                                                  value: 'result',
                                                  child: Text('Use result'),
                                                ),
                                                PopupMenuItem(
                                                  value: 'copy',
                                                  child: Text(
                                                    'Copy calculation',
                                                  ),
                                                ),
                                                PopupMenuItem(
                                                  value: 'delete',
                                                  child: Text('Delete'),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                        SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          child: Text(
                                            _entryExpression(entry),
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 16,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: Text(
                                            '= ${_groupNumber(entry.result)}',
                                            style: const TextStyle(
                                              color: _accent,
                                              fontSize: 26,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showRules() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Calculation rules'),
        content: const Text(
          '× and ÷ are calculated before + and −.\n\n% divides the preceding number by 100. For example, 200 × 10% = 20.\n\nEnter up to 15 digits per number. Results use up to 15 significant digits; very large or small results use scientific notation.\n\nPress = to save. Tap a history entry to edit its expression.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Widget _display() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        const Spacer(),
        Text(
          _engine.isFinished ? 'RESULT' : 'RUNNING RESULT',
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 10,
            letterSpacing: 2,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 34,
          child: SingleChildScrollView(
            controller: _expressionScroll,
            scrollDirection: Axis.horizontal,
            child: Text(
              _engine.expression.isEmpty ? '0' : _engine.displayExpression,
              key: const ValueKey('calculator-expression'),
              style: const TextStyle(color: Colors.white60, fontSize: 23),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Flexible(
          child: GestureDetector(
            onLongPress: () => _copy(_engine.output),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                _groupNumber(_engine.output),
                key: const ValueKey('calculator-result'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 64,
                  fontWeight: FontWeight.w300,
                  letterSpacing: -1.5,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _engine.errorMessage ??
              (_engine.expression.length > 20
                  ? 'Swipe the expression to review all numbers'
                  : 'Long press result to copy'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: _engine.errorMessage == null
                ? Colors.white30
                : Colors.orangeAccent,
            fontSize: 11,
          ),
        ),
      ],
    ),
  );

  Widget _key(String label) {
    final isEquals = label == '=';
    final isOperator = ['÷', '×', '-', '+'].contains(label);
    final isUtility = ['C', '±', '%', '⌫'].contains(label);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: SizedBox.expand(
          child: ElevatedButton(
            key: ValueKey('calculator-key-$label'),
            onPressed: () => _onButtonPressed(label),
            style: ElevatedButton.styleFrom(
              backgroundColor: isEquals || isOperator
                  ? _accent
                  : isUtility
                  ? const Color(0xFF616161)
                  : _surface,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: label == '⌫'
                ? const Icon(
                    Icons.backspace_outlined,
                    semanticLabel: 'Backspace',
                  )
                : FittedBox(
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Text(
                        label,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _keypad() => Padding(
    padding: const EdgeInsets.fromLTRB(11, 8, 11, 14),
    child: Column(
      children: [
        for (final row in [
          ['C', '±', '%', '÷'],
          ['7', '8', '9', '×'],
          ['4', '5', '6', '-'],
          ['1', '2', '3', '+'],
          ['⌫', '0', '.', '='],
        ])
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: row.map(_key).toList(),
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Theme(
    data: ThemeData.dark(useMaterial3: true).copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: _accent,
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: _background,
    ),
    child: Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: _background,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'Calculator',
          style: TextStyle(
            color: Colors.white,
            fontSize: 21,
            fontWeight: FontWeight.w500,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'History',
            onPressed: _showHistory,
            icon: const Icon(Icons.history, color: _accent),
          ),
          IconButton(
            tooltip: 'Calculation rules',
            onPressed: _showRules,
            icon: const Icon(Icons.more_horiz, color: Colors.white54),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (_, constraints) {
            if (constraints.maxWidth > 550 &&
                constraints.maxWidth > constraints.maxHeight * 1.3) {
              return Row(
                children: [
                  Expanded(child: _display()),
                  Expanded(child: _keypad()),
                ],
              );
            }
            final keypadHeight = math.min(440.0, constraints.maxHeight * .63);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _display()),
                const Divider(
                  height: 1,
                  color: Color(0xFF303030),
                  indent: 16,
                  endIndent: 16,
                ),
                SizedBox(height: keypadHeight, child: _keypad()),
              ],
            );
          },
        ),
      ),
    ),
  );
}
