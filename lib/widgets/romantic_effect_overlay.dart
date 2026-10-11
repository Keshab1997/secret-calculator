import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/romantic_message_effect.dart';

/// A brief, decorative reaction shown locally when an affectionate message
/// arrives. It never blocks taps or covers the chat with a dimming scrim.
class RomanticEffectOverlay extends StatefulWidget {
  const RomanticEffectOverlay({
    super.key,
    required this.effect,
    required this.onFinished,
  });

  final RomanticMessageEffect effect;
  final VoidCallback onFinished;

  @override
  State<RomanticEffectOverlay> createState() => _RomanticEffectOverlayState();
}

class _RomanticEffectOverlayState extends State<RomanticEffectOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..addStatusListener(_onAnimationStatus);
    _controller.forward();
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) widget.onFinished();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final screen = MediaQuery.sizeOf(context);
            final size = Size(
              constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : screen.width,
              constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : screen.height,
            );
            return AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final progress = _controller.value;
                return Stack(
                  clipBehavior: Clip.none,
                  children: widget.effect == RomanticMessageEffect.kiss
                      ? _kissParticles(size, progress)
                      : _loveConfetti(size, progress),
                );
              },
            );
          },
        ),
      ),
    );
  }

  List<Widget> _kissParticles(Size size, double progress) {
    final travel = Curves.easeInOutCubic.transform(_unit(progress / 0.82));
    final left = size.width * (0.12 + 0.50 * travel);
    final top = size.height * 0.39 - math.sin(travel * math.pi) * 34;
    final fade = progress < 0.76 ? 1.0 : _unit((1 - progress) / 0.24);
    final pop = Curves.elasticOut.transform(_unit(progress / 0.28));
    final widgets = <Widget>[];

    for (var i = 0; i < 8; i++) {
      final sparkleProgress = _unit((progress - 0.08 - i * 0.025) / 0.55);
      final opacity = progress < 0.08 + i * 0.025
          ? 0.0
          : _unit(1 - sparkleProgress) * fade;
      final angle = i * math.pi / 4;
      final distance = 14 + sparkleProgress * 40;
      final x = left + 42 + math.cos(angle) * distance;
      final y = top + 40 + math.sin(angle) * distance - sparkleProgress * 10;
      widgets.add(
        Positioned(
          left: x,
          top: y,
          child: Opacity(
            opacity: opacity,
            child: Transform.rotate(
              angle: angle * 0.18,
              child: Text(
                i.isEven ? '💗' : '✨',
                style: TextStyle(fontSize: i % 3 == 0 ? 23 : 18),
              ),
            ),
          ),
        ),
      );
    }

    widgets.add(
      Positioned(
        left: left,
        top: top,
        child: Opacity(
          opacity: fade,
          child: Transform.rotate(
            angle: -0.14 + travel * 0.28,
            child: Transform.scale(
              scale: 0.42 + pop * 0.65,
              child: const Text(
                '😘',
                style: TextStyle(
                  fontSize: 82,
                  shadows: [
                    Shadow(
                      color: Color(0x55C04868),
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    widgets.add(
      Positioned(
        left: left + 55,
        top: top + 3,
        child: Opacity(
          opacity: fade * 0.88,
          child: const Text('💋', style: TextStyle(fontSize: 30)),
        ),
      ),
    );
    return widgets;
  }

  List<Widget> _loveConfetti(Size size, double progress) {
    const confetti = ['💖', '💕', '💗', '✨', '💘', '🌸', '💝', '🌷'];
    final widgets = <Widget>[];
    for (var i = 0; i < 24; i++) {
      final delay = (i % 7) * 0.045;
      final started = progress >= delay;
      final fall = _unit((progress - delay) / (1 - delay));
      final opacity = started ? _unit((1 - fall) * 3.2) * 0.92 : 0.0;
      final startX = ((i * 47 + 13) % 100) / 100 * size.width;
      final drift = math.sin(fall * math.pi * 2 + i * 0.9) * 22;
      final x = (startX + drift).clamp(-8.0, size.width - 12).toDouble();
      final y = -26 - (i % 4) * 20 + fall * (size.height + 88 + (i % 3) * 14);
      final angle = (fall - 0.5) * (i.isEven ? 1 : -1) * 1.25;

      widgets.add(
        Positioned(
          left: x,
          top: y,
          child: Opacity(
            opacity: opacity,
            child: Transform.rotate(
              angle: angle,
              child: Text(
                confetti[i % confetti.length],
                style: TextStyle(
                  fontSize: 18 + (i % 4) * 5,
                  shadows: const [
                    Shadow(
                      color: Color(0x22000000),
                      blurRadius: 5,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  double _unit(double value) => value.clamp(0.0, 1.0).toDouble();
}
