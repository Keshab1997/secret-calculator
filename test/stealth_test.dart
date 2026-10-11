import 'dart:io';

import 'package:calculator/models/calculator_engine.dart';
import 'package:calculator/screens/chats_screen.dart';
import 'package:calculator/services/firebase_service.dart';
import 'package:calculator/services/media_cache_service.dart';
import 'package:calculator/widgets/messaging_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Decoy passcode & stealth protections', () {
    test('CalculatorEngine distinguishes decoy code from real unlock code', () {
      final engine = CalculatorEngine(customCode: '2580')..decoyCode = '0000';

      for (final d in '12+0000'.split('')) {
        final unlocked = engine.press(d);
        if (d == '0' && engine.unlockedDecoy) {
          expect(unlocked, isTrue);
          expect(engine.unlockedDecoy, isTrue);
          expect(engine.output, '0');
          break;
        }
      }

      for (final d in '2580'.split('')) {
        final unlocked = engine.press(d);
        if (d == '0') {
          expect(unlocked, isTrue);
          expect(engine.unlockedDecoy, isFalse);
        }
      }
    });

    test(
      'FirebaseService persists and validates distinct decoyPasscode',
      () async {
        final tempDir = Directory.systemTemp.createTempSync('decoy-test-');
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final stateFile = File('${tempDir.path}/state.json');
        final service = FirebaseService.forTesting(stateFile);

        await service.setCustomPasscode('2580');
        // Cannot match real unlock code or default 1997
        expect(await service.setDecoyPasscode('2580'), isFalse);
        expect(await service.setDecoyPasscode('1997'), isFalse);
        expect(await service.setDecoyPasscode('9999'), isTrue);
        expect(service.decoyPasscode, '9999');

        final reloaded = FirebaseService.forTesting(stateFile);
        await reloaded.loadSavedState();
        expect(reloaded.decoyPasscode, '9999');

        expect(await reloaded.setDecoyPasscode(''), isTrue);
        expect(reloaded.decoyPasscode, isNull);
      },
    );

    test(
      'MediaCacheService pre-seeds uploaded images and caches voice notes',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'media-cache-test-',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final cache = MediaCacheService()..cacheDirOverride = tempDir;

        final sampleImg = File('${tempDir.path}/source.jpg')
          ..writeAsBytesSync([1, 2, 3, 4, 5]);
        const url = 'https://example.com/photo1.jpg';
        await cache.seedCachedImage(url, sampleImg);

        final cachedImg = await cache.getOrDownloadImage(url);
        expect(cachedImg, isNotNull);
        expect(cachedImg!.readAsBytesSync(), [1, 2, 3, 4, 5]);

        final voiceFile = await cache.getOrCacheVoiceNote('payload-1', [
          9,
          8,
          7,
        ]);
        expect(voiceFile, isNotNull);
        expect(voiceFile!.readAsBytesSync(), [9, 8, 7]);
        cache.cacheDirOverride = null;
      },
    );

    testWidgets('ChatsScreen decoyMode hides paired rooms and security', (
      tester,
    ) async {
      final tempDir = Directory.systemTemp.createTempSync('decoy-widget-');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final service = FirebaseService()
        ..stateFileOverride = File('${tempDir.path}/state.json');
      // Real file I/O must run inside runAsync under the test binding.
      await tester.runAsync(() async {
        for (final code in ['AB23CD', 'EF45GH']) {
          service.setRoomIdForTesting(code);
          await service.markRoomPaired();
        }
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          for (final code in ['AB23CD', 'EF45GH']) {
            service.setRoomIdForTesting(code);
            await service.leaveRoom();
          }
          service.setRoomIdForTesting(null);
          service.stateFileOverride = null;
        });
      });

      // Control: with real pairs present, the directory lists them and the
      // You tab shows the real security settings.
      await tester.pumpWidget(
        MaterialApp(
          theme: messagingTheme,
          home: const ChatsScreen(decoyMode: false),
        ),
      );
      expect(find.text('Paired contact'), findsNWidgets(2));
      await tester.tap(find.text('You'));
      await tester.pump();
      expect(find.textContaining('Decoy passcode'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());

      // Decoy: same service state, but the view must show nothing real.
      await tester.pumpWidget(
        MaterialApp(
          theme: messagingTheme,
          home: const ChatsScreen(decoyMode: true),
        ),
      );
      expect(find.text('Your private conversations'), findsOneWidget);
      expect(find.text('Paired contact'), findsNothing);
      expect(find.text('Say hello'), findsNothing);
      expect(find.byTooltip('Pair new contact'), findsNothing);

      // Decoy "You" tab must not expose real security settings.
      await tester.tap(find.text('You'));
      await tester.pump();
      expect(find.text('Your profile'), findsOneWidget);
      expect(find.textContaining('Decoy passcode'), findsNothing);
      expect(find.textContaining('unlock code'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
