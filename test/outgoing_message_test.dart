import 'package:calculator/screens/chat_screen.dart';
import 'package:calculator/services/firebase_service.dart';
import 'package:calculator/widgets/messaging_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sending side of the chat: a message shows up in the conversation the
/// moment it is sent, carries its own progress, and — when it fails — stays
/// there with the reason and a retry instead of vanishing into a snackbar.
void main() {
  Future<void> pumpChat(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: messagingTheme, home: const ChatScreen()),
    );
    await tester.pump();
  }

  /// Run a send to completion (a few pumps for the async failure to land).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets(
    'a failed text send keeps the message with a reason and a retry',
    (tester) async {
      final service = FirebaseService();
      service.setRoomIdForTesting('K7M9P2');
      service.nextSendError = const FirebaseSendFailureForTest();
      addTearDown(() {
        service.nextSendError = null;
        service.setRoomIdForTesting(null);
      });

      await pumpChat(tester);

      await tester.enterText(find.byType(TextField).first, 'hello there');
      await tester.pump();
      await tester.tap(find.byTooltip('Send Message'));
      await tester.pump();

      // The bubble is in the conversation before the network is touched.
      expect(find.text('hello there'), findsOneWidget);
      await settle(tester);

      // The message did not disappear: still there, marked as failed, with a
      // retry to try again.
      expect(find.text('hello there'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Retry re-runs the send; with the failure still armed it fails again
      // and is offered again — the user is never stuck without a path out.
      service.nextSendError = const FirebaseSendFailureForTest();
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(find.text('hello there'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Discarding clears the bubble.
      await tester.tap(find.byTooltip('Discard'));
      await tester.pump();
      expect(find.text('hello there'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed photo upload keeps the photo with its own reason', (
    tester,
  ) async {
    final service = FirebaseService();
    service.setRoomIdForTesting('K7M9P2');
    addTearDown(() => service.setRoomIdForTesting(null));

    // The gallery hands back a path; the upload itself fails, because a
    // test surface has no Firebase app — the same shape as a Storage
    // rejection on a phone.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      (call) async {
        if (call.method == 'pickImage') return '/tmp/never_uploaded.jpg';
        return null;
      },
    );

    await pumpChat(tester);

    await tester.tap(find.byTooltip('Attach photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gallery'));
    await tester.pump();
    await settle(tester);

    // The photo is in the conversation as a failed bubble with its reason
    // and a retry — not a bare snackbar, not a silent vanish.
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('could not be uploaded'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('discard removes a failed photo bubble', (tester) async {
    FirebaseService().setRoomIdForTesting('K7M9P2');
    addTearDown(() => FirebaseService().setRoomIdForTesting(null));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      (call) async =>
          call.method == 'pickImage' ? '/tmp/never_uploaded.jpg' : null,
    );

    await pumpChat(tester);

    await tester.tap(find.byTooltip('Attach photo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gallery'));
    await tester.pump();
    await settle(tester);
    expect(find.byTooltip('Discard'), findsOneWidget);

    await tester.tap(find.byTooltip('Discard'));
    await tester.pump();
    expect(find.byTooltip('Discard'), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// A send failure with no Firebase error code behind it — the generic
/// "could not be sent" reason should surface, which is what a plain network
/// error looks like to the UI.
class FirebaseSendFailureForTest implements Exception {
  const FirebaseSendFailureForTest();

  @override
  String toString() => 'test send failure';
}
