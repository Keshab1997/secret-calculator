import 'dart:io';

import 'package:flutter/material.dart';

/// A local photo preview with a visible upload animation and byte progress.
/// The spinner stays indeterminate until Storage reports actual bytes, so an
/// initial 0% value never looks like a frozen ring.
class PhotoUploadIndicator extends StatelessWidget {
  const PhotoUploadIndicator({
    super.key,
    required this.image,
    required this.progress,
    required this.failed,
  });

  final File image;
  final double? progress;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final visibleProgress = progress == null || progress! <= 0
        ? null
        : progress!.clamp(0.0, 1.0).toDouble();

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 150,
        height: 150,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              image,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => const ColoredBox(
                color: Color(0xFF566168),
                child: Center(
                  child: Icon(
                    Icons.image_outlined,
                    color: Colors.white70,
                    size: 32,
                  ),
                ),
              ),
            ),
            ColoredBox(
              color: Colors.black.withValues(alpha: failed ? 0.62 : 0.48),
              child: Center(
                child: failed
                    ? const Icon(
                        Icons.image_not_supported_outlined,
                        color: Colors.white70,
                        size: 30,
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 42,
                            height: 42,
                            child: CircularProgressIndicator(
                              value: visibleProgress,
                              strokeWidth: 3,
                              strokeCap: StrokeCap.round,
                              color: Colors.white,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.26,
                              ),
                              semanticsLabel: 'Uploading photo',
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            visibleProgress == null
                                ? 'Uploading…'
                                : '${(visibleProgress * 100).round()}%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
