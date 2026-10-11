import 'dart:async';

import 'package:flutter/material.dart';

enum AppToastKind { info, success, warning, error }

/// A short, accessible status card that appears below the app bar.
///
/// A new toast replaces the current one, so quick actions never stack a row
/// of messages over the screen. The root overlay lets a notice survive a route
/// pop (for example, when a call fails and its screen closes immediately).
abstract final class AppToast {
  static OverlayEntry? _entry;
  static const toastKey = ValueKey<String>('app-toast-card');

  static void show(
    BuildContext context,
    String message, {
    AppToastKind kind = AppToastKind.info,
    Duration? duration,
  }) {
    final cleanMessage = message.trim();
    if (!context.mounted || cleanMessage.isEmpty) return;

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _removeCurrent();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _AppToastOverlay(
        message: cleanMessage,
        kind: kind,
        duration: duration ?? _durationFor(cleanMessage),
        onDismissed: () {
          if (!identical(_entry, entry)) return;
          _entry = null;
          entry.remove();
          entry.dispose();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static Duration _durationFor(String message) => message.length > 72
      ? const Duration(seconds: 4)
      : const Duration(milliseconds: 2400);

  static void _removeCurrent() {
    final current = _entry;
    if (current == null) return;
    _entry = null;
    current.remove();
    current.dispose();
  }
}

class _AppToastOverlay extends StatefulWidget {
  const _AppToastOverlay({
    required this.message,
    required this.kind,
    required this.duration,
    required this.onDismissed,
  });

  final String message;
  final AppToastKind kind;
  final Duration duration;
  final VoidCallback onDismissed;

  @override
  State<_AppToastOverlay> createState() => _AppToastOverlayState();
}

class _AppToastOverlayState extends State<_AppToastOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 180),
    );
    final entrance = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _fade = entrance;
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.24),
      end: Offset.zero,
    ).animate(entrance);
    _controller.forward();
    _dismissTimer = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (!mounted) return;
    await _controller.reverse();
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accentFor(widget.kind);
    final top = MediaQuery.of(context).padding.top + kToolbarHeight + 8;

    return Positioned(
      top: top,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: FadeTransition(
              opacity: _fade,
              child: SlideTransition(
                position: _slide,
                child: Semantics(
                  container: true,
                  liveRegion: true,
                  label: widget.message,
                  child: Material(
                    key: AppToast.toastKey,
                    color: const Color(0xFF19242A),
                    elevation: 14,
                    shadowColor: Colors.black.withValues(alpha: 0.35),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.09),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 13,
                      ),
                      child: Row(
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.16),
                              shape: BoxShape.circle,
                            ),
                            child: SizedBox(
                              width: 38,
                              height: 38,
                              child: Icon(
                                _iconFor(widget.kind),
                                color: accent,
                                size: 21,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              widget.message,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: const Color(0xFFF4F7F8),
                                    fontWeight: FontWeight.w500,
                                    height: 1.25,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Color _accentFor(AppToastKind kind) => switch (kind) {
    AppToastKind.info => const Color(0xFF82CFFF),
    AppToastKind.success => const Color(0xFF62D995),
    AppToastKind.warning => const Color(0xFFFFC857),
    AppToastKind.error => const Color(0xFFFF7777),
  };

  static IconData _iconFor(AppToastKind kind) => switch (kind) {
    AppToastKind.info => Icons.info_outline_rounded,
    AppToastKind.success => Icons.check_circle_outline_rounded,
    AppToastKind.warning => Icons.warning_amber_rounded,
    AppToastKind.error => Icons.error_outline_rounded,
  };
}
