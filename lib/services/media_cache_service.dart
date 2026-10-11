import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Persistent disk + in-memory cache for chat photos and base64 profile avatars.
///
/// Avoids re-downloading Firebase Storage images or re-decoding base64 avatars
/// on every scroll/rebuild, reducing Firebase Storage egress bandwidth.
class MediaCacheService {
  static final MediaCacheService _instance = MediaCacheService._internal();
  factory MediaCacheService() => _instance;
  MediaCacheService._internal();

  @visibleForTesting
  Directory? cacheDirOverride;

  final Map<String, MemoryImage> _avatarMemoryCache = {};
  final Map<String, File> _resolvedFileCache = {};
  final Map<String, Future<File?>> _inFlightDownloads = {};

  static const int _maxAvatarEntries = 64;

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

  /// Returns a cached [MemoryImage] for a base64-encoded avatar string so
  /// widget rebuilds do not repeatedly run [base64Decode].
  ImageProvider? avatarProvider(String? base64Photo) {
    if (base64Photo == null || base64Photo.isEmpty) return null;
    final key = _stableHash(base64Photo);
    final existing = _avatarMemoryCache[key];
    if (existing != null) return existing;
    try {
      final bytes = base64Decode(base64Photo);
      if (bytes.isEmpty) return null;
      if (_avatarMemoryCache.length >= _maxAvatarEntries) {
        _avatarMemoryCache.remove(_avatarMemoryCache.keys.first);
      }
      final provider = MemoryImage(Uint8List.fromList(bytes));
      _avatarMemoryCache[key] = provider;
      return provider;
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _cacheDir() async {
    if (cacheDirOverride != null) {
      await cacheDirOverride!.create(recursive: true);
      return cacheDirOverride!;
    }
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/media_cache');
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      final fallback = Directory('${Directory.systemTemp.path}/media_cache');
      await fallback.create(recursive: true);
      return fallback;
    }
  }

  static const int _maxDiskCacheBytes = 50 * 1024 * 1024;

  /// Pre-seeds the local disk cache with [sourceFile] under [url] so the
  /// sender never re-downloads their own uploaded photo from Firebase Storage.
  Future<void> seedCachedImage(String url, File sourceFile) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty || !sourceFile.existsSync()) return;
    try {
      final dir = await _cacheDir();
      final hash = _stableHash(trimmed);
      final target = File('${dir.path}/img_$hash.jpg');
      if (sourceFile.path != target.path) {
        await sourceFile.copy(target.path);
      }
      _resolvedFileCache[trimmed] = target;
      await pruneDiskCacheIfNeeded();
    } catch (_) {}
  }

  /// Returns a cached `.m4a` file for a decrypted voice note, writing it once.
  Future<File?> getOrCacheVoiceNote(
    String cacheKey,
    List<int> audioBytes,
  ) async {
    if (audioBytes.isEmpty) return null;
    final key = 'voice_${_stableHash(cacheKey)}';
    final mem = _resolvedFileCache[key];
    if (mem != null && mem.existsSync() && mem.lengthSync() > 0) {
      return mem;
    }
    try {
      final dir = await _cacheDir();
      final file = File('${dir.path}/$key.m4a');
      if (!await file.exists() || await file.length() == 0) {
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsBytes(audioBytes, flush: true);
        await tmp.rename(file.path);
        await pruneDiskCacheIfNeeded();
      }
      _resolvedFileCache[key] = file;
      return file;
    } catch (_) {
      return null;
    }
  }

  /// Prunes oldest cached media files when total cache exceeds 50 MB.
  Future<void> pruneDiskCacheIfNeeded() async {
    try {
      final dir = await _cacheDir();
      final entries = dir
          .listSync()
          .whereType<File>()
          .where((f) => !f.path.endsWith('.tmp'))
          .toList();
      var total = 0;
      final stats = <({File file, int size, DateTime modified})>[];
      for (final file in entries) {
        final stat = file.statSync();
        total += stat.size;
        stats.add((file: file, size: stat.size, modified: stat.modified));
      }
      if (total <= _maxDiskCacheBytes) return;
      stats.sort((a, b) => a.modified.compareTo(b.modified));
      for (final item in stats) {
        if (total <= _maxDiskCacheBytes) break;
        try {
          item.file.deleteSync();
          total -= item.size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Returns the local cached [File] for [url], downloading it once if needed.
  Future<File?> getOrDownloadImage(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return Future.value(null);
    final memFile = _resolvedFileCache[trimmed];
    if (memFile != null && memFile.existsSync() && memFile.lengthSync() > 0) {
      return Future.value(memFile);
    }
    return _inFlightDownloads.putIfAbsent(trimmed, () async {
      try {
        final dir = await _cacheDir();
        final hash = _stableHash(trimmed);
        final file = File('${dir.path}/img_$hash.jpg');
        if (await file.exists() && await file.length() > 0) {
          _resolvedFileCache[trimmed] = file;
          return file;
        }
        if (Platform.environment.containsKey('FLUTTER_TEST')) {
          return null;
        }
        final uri = Uri.tryParse(trimmed);
        if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
          return null;
        }
        final client = HttpClient();
        try {
          final request = await client.getUrl(uri);
          final response = await request.close();
          if (response.statusCode != HttpStatus.ok) return null;
          final bytes = await consolidateHttpClientResponseBytes(response);
          if (bytes.isEmpty) return null;
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsBytes(bytes, flush: true);
          await tmp.rename(file.path);
          _resolvedFileCache[trimmed] = file;
          return file;
        } finally {
          client.close();
        }
      } catch (_) {
        return null;
      } finally {
        _inFlightDownloads.remove(trimmed);
      }
    });
  }
}

/// Displays a remote image backed by persistent local disk caching.
class CachedChatImage extends StatefulWidget {
  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;

  const CachedChatImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  @override
  State<CachedChatImage> createState() => _CachedChatImageState();
}

class _CachedChatImageState extends State<CachedChatImage> {
  Future<File?>? _fileFuture;

  @override
  void initState() {
    super.initState();
    _fileFuture = MediaCacheService().getOrDownloadImage(widget.imageUrl);
  }

  @override
  void didUpdateWidget(covariant CachedChatImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _fileFuture = MediaCacheService().getOrDownloadImage(widget.imageUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _fileFuture,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file != null) {
          return Image.file(
            file,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
          );
        }
        return Image.network(
          widget.imageUrl,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return Container(
              width: widget.width,
              height: widget.height,
              color: Colors.grey[850],
              child: const Center(child: CircularProgressIndicator()),
            );
          },
          errorBuilder: (context, error, stackTrace) {
            return Container(
              width: widget.width,
              height: widget.height,
              color: Colors.grey[850],
              alignment: Alignment.center,
              child: const Icon(Icons.broken_image, color: Colors.white54),
            );
          },
        );
      },
    );
  }
}
