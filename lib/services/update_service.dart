import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// A GitHub release that is newer than the installed build, with a
/// download target.
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releasePageUrl,
  });

  /// Version advertised by the release tag (e.g. `1.1.0`).
  final String version;

  /// Direct link to the signed APK asset; falls back to the release page
  /// when the release carries no APK.
  final String downloadUrl;

  /// The GitHub release page (notes, AAB, every asset).
  final String releasePageUrl;
}

/// The outcome of one update check.
class AppUpdateStatus {
  const AppUpdateStatus({this.currentVersion, this.update});

  /// Installed version from the package manifest, when readable.
  final String? currentVersion;

  /// Non-null when the latest release is newer than the installed build.
  final AppUpdateInfo? update;

  bool get hasUpdate => update != null;
}

/// Checks GitHub Releases for a newer build of this app and opens the
/// download.
///
/// The "Publish Signed Android Release" workflow tags every build
/// `v<version-name>` from pubspec.yaml and attaches a signed APK, so a
/// newer tag means a newer app. The APK asset is matched by file extension,
/// so renaming the release title cannot break the check.
abstract final class UpdateService {
  static const String _latestReleaseUrl =
      'https://api.github.com/repos/Keshab1997/secret-calculator/releases/latest';

  /// Test seam: replaces the whole check.
  @visibleForTesting
  static Future<AppUpdateStatus> Function()? checkOverride;

  /// Test seam: replaces the launcher used for downloads.
  @visibleForTesting
  static Future<bool> Function(Uri uri)? launchOverride;

  /// Reads the installed version and the latest release, then reports an
  /// update when the release is newer. Offline, no release yet, or any
  /// error resolves to "no update" — the check must never block the
  /// profile.
  static Future<AppUpdateStatus> checkForUpdate() async {
    final override = checkOverride;
    if (override != null) return override();

    String? current;
    try {
      current = (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      // Without the installed version there is nothing to compare.
    }
    final release = await _fetchLatestRelease();
    if (current == null || release == null) {
      return AppUpdateStatus(currentVersion: current);
    }
    return AppUpdateStatus(
      currentVersion: current,
      update: latestReleaseUpdate(release, currentVersion: current),
    );
  }

  /// Opens the download for [update] — the APK asset first, the release
  /// page as fallback. Returns true when a launcher accepted the URL.
  static Future<bool> openUpdate(AppUpdateInfo update) async {
    final launch = launchOverride ?? _launch;
    if (await launch(Uri.parse(update.downloadUrl))) return true;
    if (update.downloadUrl != update.releasePageUrl) {
      return launch(Uri.parse(update.releasePageUrl));
    }
    return false;
  }

  static Future<bool> _launch(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.platformDefault);
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, Object?>?> _fetchLatestRelease() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client
          .getUrl(Uri.parse(_latestReleaseUrl))
          .timeout(const Duration(seconds: 6));
      request.headers.set('user-agent', 'secret-calculator-update-check');
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != 200) return null;
      final body = await response
          .transform(const Utf8Decoder())
          .join()
          .timeout(const Duration(seconds: 10));

      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Pure parse + compare: latest-release JSON → an [AppUpdateInfo] when
  /// the release tag beats [currentVersion].
  static AppUpdateInfo? latestReleaseUpdate(
    Map<String, Object?> release, {
    required String currentVersion,
  }) {
    final rawTag = release['tag_name']?.toString() ?? '';
    final version = rawTag.startsWith('v') ? rawTag.substring(1) : rawTag;
    if (!isVersionNewer(version, currentVersion)) return null;
    final pageUrl = release['html_url']?.toString() ?? '';
    if (pageUrl.isEmpty) return null;
    var downloadUrl = pageUrl;
    final assets = release['assets'];
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = asset['name'];
        if (name is! String || !name.endsWith('.apk')) continue;
        final url = asset['browser_download_url'];
        if (url is String && url.isNotEmpty) {
          downloadUrl = url;
          break;
        }
      }
    }
    return AppUpdateInfo(
      version: version,
      downloadUrl: downloadUrl,
      releasePageUrl: pageUrl,
    );
  }

  /// `1.1.0` beats `1.0.9`. Only major/minor/patch are compared; build
  /// numbers and prerelease suffixes are ignored, and unparseable parts
  /// count as zero so a garbage tag can never win.
  static bool isVersionNewer(String candidate, String current) {
    final candidateParts = _versionParts(candidate);
    final currentParts = _versionParts(current);
    for (var i = 0; i < 3; i++) {
      if (candidateParts[i] != currentParts[i]) {
        return candidateParts[i] > currentParts[i];
      }
    }
    return false;
  }

  static List<int> _versionParts(String version) {
    final core = version.split('+').first.split('-').first;
    final parts = <int>[];
    for (final piece in core.split('.')) {
      parts.add(int.tryParse(piece) ?? 0);
      if (parts.length == 3) break;
    }
    while (parts.length < 3) {
      parts.add(0);
    }
    return parts;
  }
}
