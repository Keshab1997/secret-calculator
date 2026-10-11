import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'firebase_service.dart';

/// Bounded in-memory cache for decrypted chat photos and profile avatars.
/// Decrypted media is deliberately never written to the app's cache directory.
class MediaCacheService {
  static final MediaCacheService _instance = MediaCacheService._internal();
  factory MediaCacheService() => _instance;
  MediaCacheService._internal();

  final Map<String, MemoryImage> _avatarMemoryCache = {};
  final LinkedHashMap<String, Uint8List> _decryptedImages = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _inFlightDownloads = {};

  static const int _maxAvatarEntries = 64;
  static const int _maxImageEntries = 16;
  static const int _maxImageCacheBytes = 12 * 1024 * 1024;
  int _decryptedImageBytes = 0;

  static String _stableHash(String input) {
    var h1 = 0x811c9dc5;
    var h2 = 0xcbf29ce4;
    for (final unit in input.codeUnits) {
      h1 ^= unit;
      h1 = (h1 * 0x01000193) & 0xffffffff;
      h2 ^= (unit * 31) & 0xffffffff;
      h2 = (h2 * 0x01000193) & 0xffffffff;
    }
    return '${h1.toRadixString(16).padLeft(8, '0')}'
        '${h2.toRadixString(16).padLeft(8, '0')}'
        '_${input.length}';
  }

  /// Returns a cached [MemoryImage] for a base64-encoded avatar so widget
  /// rebuilds do not repeatedly decode it.
  ImageProvider? avatarProvider(String? base64Photo) {
    if (base64Photo == null || base64Photo.isEmpty) return null;
    final key = _stableHash(base64Photo);
    final existing = _avatarMemoryCache.remove(key);
    if (existing != null) {
      _avatarMemoryCache[key] = existing;
      return existing;
    }
    try {
      final bytes = base64Decode(base64Photo);
      if (bytes.isEmpty) return null;
      while (_avatarMemoryCache.length >= _maxAvatarEntries) {
        _avatarMemoryCache.remove(_avatarMemoryCache.keys.first);
      }
      final provider = MemoryImage(Uint8List.fromList(bytes));
      _avatarMemoryCache[key] = provider;
      return provider;
    } catch (_) {
      return null;
    }
  }

  /// Loads an encrypted photo, decrypts it through [loader], and caches only
  /// the decrypted bytes in a size-bounded LRU memory cache.
  Future<Uint8List?> getDecryptedImage(
    String cacheKey,
    Future<Uint8List?> Function() loader,
  ) {
    final cached = _decryptedImages.remove(cacheKey);
    if (cached != null) {
      _decryptedImages[cacheKey] = cached;
      return Future.value(cached);
    }
    return _inFlightDownloads.putIfAbsent(cacheKey, () async {
      try {
        final bytes = await loader();
        if (bytes == null || bytes.isEmpty) return null;
        if (bytes.length <= _maxImageCacheBytes) {
          while (_decryptedImages.isNotEmpty &&
              (_decryptedImages.length >= _maxImageEntries ||
                  _decryptedImageBytes + bytes.length > _maxImageCacheBytes)) {
            final oldestKey = _decryptedImages.keys.first;
            _decryptedImageBytes -= _decryptedImages.remove(oldestKey)!.length;
          }
          final copy = Uint8List.fromList(bytes);
          _decryptedImages[cacheKey] = copy;
          _decryptedImageBytes += copy.length;
          return copy;
        }
        return bytes;
      } finally {
        _inFlightDownloads.remove(cacheKey);
      }
    });
  }

  /// Drops decrypted-photo memory for a room after it is unpaired.
  void clearRoomImages(String roomId) {
    final prefix = '$roomId:';
    final keys = _decryptedImages.keys
        .where((key) => key.startsWith(prefix))
        .toList();
    for (final key in keys) {
      _decryptedImageBytes -= _decryptedImages.remove(key)!.length;
    }
  }

  @visibleForTesting
  int get cachedImageCount => _decryptedImages.length;

  @visibleForTesting
  int get cachedImageBytes => _decryptedImageBytes;
}

/// Displays a room-encrypted photo. The plaintext exists only as bounded
/// in-memory bytes; it is never cached as a file on disk.
class CachedChatImage extends StatefulWidget {
  final String imageUrl;
  final String roomId;
  final double? width;
  final double? height;
  final BoxFit fit;

  const CachedChatImage({
    super.key,
    required this.imageUrl,
    required this.roomId,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  @override
  State<CachedChatImage> createState() => _CachedChatImageState();
}

class _CachedChatImageState extends State<CachedChatImage> {
  late Future<Uint8List?> _bytesFuture;

  @override
  void initState() {
    super.initState();
    _bytesFuture = _load();
  }

  Future<Uint8List?> _load() => MediaCacheService().getDecryptedImage(
    '${widget.roomId}:${widget.imageUrl}',
    () => FirebaseService().downloadDecryptedImage(
      widget.imageUrl,
      roomId: widget.roomId,
    ),
  );

  @override
  void didUpdateWidget(covariant CachedChatImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.roomId != widget.roomId) {
      _bytesFuture = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytesFuture,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null && bytes.isNotEmpty) {
          return Image.memory(
            bytes,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            gaplessPlayback: true,
          );
        }
        final width = widget.width ?? 220.0;
        final height = widget.height ?? 180.0;
        if (snapshot.connectionState == ConnectionState.waiting) {
          return SizedBox(
            width: width,
            height: height,
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return SizedBox(
          width: width,
          height: height,
          child: const Center(child: Icon(Icons.broken_image_outlined)),
        );
      },
    );
  }
}
