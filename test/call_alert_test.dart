import 'package:calculator/screens/profile_screen.dart';
import 'package:calculator/services/firebase_service.dart';
import 'package:calculator/widgets/messaging_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Incoming-call alert mode: how this phone alerts on a call — sound,
/// vibrate-only or silent. A persisted preference like the theme mode.
void main() {
  final service = FirebaseService();

  // setUp runs outside the fake-async zone, so the state-file write
  // (real dart:io) completes here; it would hang inside a test body.
  setUp(() async {
    await service.setCallAlert('sound');
  });
  tearDown(() async {
    await service.setCallAlert('sound');
  });

  test('call alert defaults to sound', () {
    expect(service.callAlert, 'sound');
    expect(service.callAlertChanged.value, 'sound');
  });

  test(
    'setCallAlert updates the getter and publishes on the notifier',
    () async {
      await service.setCallAlert('vibrate');
      expect(service.callAlert, 'vibrate');
      expect(service.callAlertChanged.value, 'vibrate');

      await service.setCallAlert('silent');
      expect(service.callAlert, 'silent');
      expect(service.callAlertChanged.value, 'silent');

      await service.setCallAlert('sound');
      expect(service.callAlert, 'sound');
    },
  );

  test('setCallAlert ignores unknown values', () async {
    await service.setCallAlert('loud');
    expect(service.callAlert, 'sound');
    await service.setCallAlert('');
    expect(service.callAlert, 'sound');
  });

  testWidgets('profile offers sound, vibrate and silent for incoming calls', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: messagingTheme,
        // In the app the profile always sits on a scaffolded route, which
        // supplies the Material the text fields and tiles need.
        home: const Scaffold(body: ProfileScreen()),
      ),
    );
    final tile = find.text('Incoming call alert');
    expect(tile, findsOneWidget);
    expect(find.text('Sound + vibrate'), findsOneWidget);

    if (tile.hitTestable().evaluate().isEmpty) {
      await tester.scrollUntilVisible(tile, 200);
    }
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.text('Incoming call alert'), findsWidgets);
    expect(find.text('Sound'), findsOneWidget);
    expect(find.text('Vibrate'), findsOneWidget);
    expect(find.text('Silent'), findsOneWidget);
    expect(find.text('In use'), findsOneWidget); // the 'Sound' row

    // Selecting updates the preference synchronously; the persistence write
    // behind it is platform I/O that only the real event loop can finish, so
    // the re-render is covered by the label test below.
    await tester.tap(find.text('Vibrate'));
    await tester.pumpAndSettle();
    expect(service.callAlert, 'vibrate');
  });

  testWidgets('profile tile label reflects the saved alert mode', (
    tester,
  ) async {
    // Real-zone write: the state file persists (or falls back) here, where
    // platform calls actually complete.
    await tester.runAsync(() => service.setCallAlert('vibrate'));
    await tester.pumpWidget(
      MaterialApp(
        theme: messagingTheme,
        home: const Scaffold(body: ProfileScreen()),
      ),
    );
    final tile = find.text('Incoming call alert');
    if (tile.hitTestable().evaluate().isEmpty) {
      await tester.scrollUntilVisible(tile, 200);
    }
    expect(find.text('Vibrate only'), findsOneWidget);
  });
}
