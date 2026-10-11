import 'package:calculator/screens/chats_screen.dart';
import 'package:calculator/screens/profile_screen.dart';
import 'package:calculator/services/firebase_service.dart';
import 'package:calculator/services/update_service.dart';
import 'package:calculator/widgets/messaging_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Update check against GitHub Releases: the "Publish Signed Android
/// Release" workflow tags each build with the pubspec version and attaches
/// a signed APK, so a newer tag means the user should install it.
void main() {
  group('isVersionNewer', () {
    test('bigger major, minor or patch is newer', () {
      expect(UpdateService.isVersionNewer('2.0.0', '1.9.9'), isTrue);
      expect(UpdateService.isVersionNewer('1.1.0', '1.0.9'), isTrue);
      expect(UpdateService.isVersionNewer('1.1.1', '1.1.0'), isTrue);
      expect(UpdateService.isVersionNewer('1.10.0', '1.9.9'), isTrue);
    });

    test('equal or older versions are not newer', () {
      expect(UpdateService.isVersionNewer('1.0.0', '1.0.0'), isFalse);
      expect(UpdateService.isVersionNewer('1.0.9', '1.1.0'), isFalse);
      expect(UpdateService.isVersionNewer('0.9.9', '1.0.0'), isFalse);
    });

    test('garbage tags never win', () {
      expect(UpdateService.isVersionNewer('', '1.0.0'), isFalse);
      expect(UpdateService.isVersionNewer('next', '1.0.0'), isFalse);
      expect(UpdateService.isVersionNewer('v1.0.0', '1.0.0'), isFalse);
    });
  });

  group('latestReleaseUpdate', () {
    const release = <String, Object>{
      'tag_name': 'v1.1.0',
      'html_url':
          'https://github.com/Keshab1997/secret-calculator/releases/tag/v1.1.0',
      'assets': [
        {
          'name': 'My-Flutter-App-v1.1.0.apk',
          'browser_download_url': 'https://github.com/Keshab1997/secret-calculator/releases/download/v1.1.0/My-Flutter-App-v1.1.0.apk',
        },
        {
          'name': 'My-Flutter-App-v1.1.0.aab',
          'browser_download_url': 'https://github.com/Keshab1997/secret-calculator/releases/download/v1.1.0/My-Flutter-App-v1.1.0.aab',
        },
      ],
    };

    test('a newer release yields the apk download', () {
      final update = UpdateService.latestReleaseUpdate(
        release,
        currentVersion: '1.0.0',
      );
      expect(update, isNotNull);
      expect(update!.version, '1.1.0');
      expect(update.downloadUrl, endsWith('My-Flutter-App-v1.1.0.apk'));
      expect(update.releasePageUrl, release['html_url']);
    });

    test('the same version yields no update', () {
      expect(
        UpdateService.latestReleaseUpdate(release, currentVersion: '1.1.0'),
        isNull,
      );
    });

    test('a newer release without an apk falls back to the release page', () {
      final noApk = Map<String, Object>.from(release)
        ..['assets'] = const [
          {
            'name': 'My-Flutter-App-v1.1.0.aab',
            'browser_download_url': 'https://github.com/Keshab1997/secret-calculator/releases/download/v1.1.0/My-Flutter-App-v1.1.0.aab',
          },
        ];
      final update = UpdateService.latestReleaseUpdate(
        noApk,
        currentVersion: '1.0.0',
      );
      expect(update, isNotNull);
      expect(update!.downloadUrl, update.releasePageUrl);
    });
  });

  group('latestReleaseInfo', () {
    test('reads the tag (minus the v) and the notes body', () {
      const release = <String, Object>{
        'tag_name': 'v1.2.0',
        'body': '  Bug fixes and a love sticker pack.  ',
      };
      final info = UpdateService.latestReleaseInfo(release);
      expect(info, isNotNull);
      expect(info!.tag, '1.2.0');
      expect(info.notes, 'Bug fixes and a love sticker pack.');
    });

    test('an empty body leaves notes null', () {
      const release = <String, Object>{'tag_name': 'v1.2.0', 'body': '   '};
      final info = UpdateService.latestReleaseInfo(release);
      expect(info, isNotNull);
      expect(info!.notes, isNull);
    });

    test('a release without a tag is ignored', () {
      expect(UpdateService.latestReleaseInfo(const <String, Object>{}), isNull);
    });
  });

  testWidgets('profile tile offers the download when an update exists', (
    tester,
  ) async {
    UpdateService.checkOverride = () async => const AppUpdateStatus(
      currentVersion: '1.0.0',
      update: AppUpdateInfo(
        version: '1.1.0',
        downloadUrl: 'https://github.com/Keshab1997/secret-calculator/releases/download/v1.1.0/My-Flutter-App-v1.1.0.apk',
        releasePageUrl: 'https://github.com/Keshab1997/secret-calculator/releases/tag/v1.1.0',
      ),
    );
    Uri? launched;
    UpdateService.launchOverride = (uri) async {
      launched = uri;
      return true;
    };
    addTearDown(() {
      UpdateService.checkOverride = null;
      UpdateService.launchOverride = null;
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: messagingTheme,
        // In the app the profile always sits on a scaffolded route, which
        // supplies the Material the text fields and tiles need.
        home: const Scaffold(body: ProfileScreen()),
      ),
    );
    await tester.pump(); // the override's check resolves
    final tile = find.text('App version');
    expect(tile, findsOneWidget);
    if (tile.hitTestable().evaluate().isEmpty) {
      // The profile root scrolls; the multiline About field has its own
      // Scrollable, so the default finder would be ambiguous. The root's
      // comes first in tree order.
      await tester.scrollUntilVisible(
        tile,
        200,
        scrollable: find.byType(Scrollable).first,
      );
    }
    expect(find.text('v1.1.0 is available'), findsOneWidget);

    await tester.tap(tile);
    await tester.pump();
    expect(launched, isNotNull);
    expect(launched!.path, endsWith('.apk'));
  });

  testWidgets('profile tile shows the installed version when up to date', (
    tester,
  ) async {
    UpdateService.checkOverride = () async =>
        const AppUpdateStatus(currentVersion: '1.0.0');
    addTearDown(() => UpdateService.checkOverride = null);

    await tester.pumpWidget(
      MaterialApp(
        theme: messagingTheme,
        home: const Scaffold(body: ProfileScreen()),
      ),
    );
    await tester.pump();
    final tile = find.text('App version');
    expect(tile, findsOneWidget);
    if (tile.hitTestable().evaluate().isEmpty) {
      // The profile root scrolls; the multiline About field has its own
      // Scrollable, so the default finder would be ambiguous. The root's
      // comes first in tree order.
      await tester.scrollUntilVisible(
        tile,
        200,
        scrollable: find.byType(Scrollable).first,
      );
    }
    expect(find.text('v1.0.0 — up to date'), findsOneWidget);
  });

  group('ChatsScreen release notes', () {
    final service = FirebaseService();

    setUp(() async {
      // Real-zone write: start each test from a known, already-seen tag.
      await service.markReleaseSeen('0.0.0');
    });

    testWidgets('shows the notes once for a freshly installed build', (
      tester,
    ) async {
      UpdateService.checkOverride = () async => const AppUpdateStatus(
        currentVersion: '1.1.0',
        latestTag: '1.1.0',
        latestNotes: 'New: love stickers\nFaster calls',
      );
      addTearDown(() => UpdateService.checkOverride = null);

      await tester.pumpWidget(
        MaterialApp(theme: messagingTheme, home: const ChatsScreen()),
      );
      // One pump lets the check's microtask run and request the dialog;
      // the next frames build and animate it in.
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('What’s new in 1.1.0'), findsOneWidget);
      expect(find.text('New: love stickers\nFaster calls'), findsOneWidget);

      await tester.tap(find.text('Okay'));
      await tester.pump();
      await tester.pump();
      expect(find.text('What’s new in 1.1.0'), findsNothing);
    });

    testWidgets('does not repeat notes that were already seen', (tester) async {
      // Real-zone write (the state file is real I/O, which the fake-async
      // test zone never completes).
      await tester.runAsync(() => service.markReleaseSeen('1.1.0'));
      UpdateService.checkOverride = () async => const AppUpdateStatus(
        currentVersion: '1.1.0',
        latestTag: '1.1.0',
        latestNotes: 'New: love stickers',
      );
      addTearDown(() => UpdateService.checkOverride = null);

      await tester.pumpWidget(
        MaterialApp(theme: messagingTheme, home: const ChatsScreen()),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.text('What’s new in 1.1.0'), findsNothing);
    });
  });
}
