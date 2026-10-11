import 'package:calculator/main.dart';
import 'package:calculator/screens/calculator_screen.dart';
import 'package:calculator/screens/chat_screen.dart';
import 'package:calculator/screens/pairing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CalculatorEngine unit tests', () {
    late CalculatorEngine engine;

    setUp(() {
      engine = CalculatorEngine();
    });

    void enter(String sequence) {
      for (final ch in sequence.split('')) {
        engine.press(ch);
      }
    }

    test('performs addition, subtraction, multiplication, and division', () {
      enter('12+8=');
      expect(engine.output, '20');

      engine.press('C');
      enter('50-18=');
      expect(engine.output, '32');

      engine.press('C');
      enter('6×7=');
      expect(engine.output, '42');

      engine.press('C');
      enter('81÷9=');
      expect(engine.output, '9');
    });

    test('handles decimals and strips trailing zeros', () {
      enter('.5+1.25=');
      expect(engine.output, '1.75');

      engine.press('C');
      enter('1.2..3');
      expect(engine.output, '1.23');
    });

    test('handles percentage calculation', () {
      enter('50%');
      expect(engine.output, '0.5');

      engine.press('C');
      enter('250%');
      expect(engine.output, '2.5');
    });

    test('handles divide by zero gracefully', () {
      enter('9÷0=');
      expect(engine.output, 'Error');
    });

    test('handles backspace and clear', () {
      enter('123');
      engine.press('⌫');
      expect(engine.output, '12');
      engine.press('⌫');
      engine.press('⌫');
      expect(engine.output, '0');

      enter('99');
      engine.press('C');
      expect(engine.output, '0');
    });

    test('detects 1997 secret code in rolling 4-char buffer', () {
      expect(engine.press('5'), isFalse);
      expect(engine.press('8'), isFalse);
      expect(engine.press('1'), isFalse);
      expect(engine.press('9'), isFalse);
      expect(engine.press('9'), isFalse);
      expect(engine.press('7'), isTrue);
      // Buffer resets after triggering
      expect(engine.press('7'), isFalse);
    });

    test('detects custom secret passcode', () {
      engine.customCode = '2580';
      expect(engine.press('2'), isFalse);
      expect(engine.press('5'), isFalse);
      expect(engine.press('8'), isFalse);
      expect(engine.press('0'), isTrue);
    });
  });

  group('CalculatorApp widget tests', () {
    testWidgets('Calculator app smoke test and arithmetic UI', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const CalculatorApp());
      expect(find.text('Calculator'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, '7'));
      await tester.tap(find.widgetWithText(ElevatedButton, '+'));
      await tester.tap(find.widgetWithText(ElevatedButton, '5'));
      await tester.tap(find.widgetWithText(ElevatedButton, '='));
      await tester.pump();

      expect(find.text('12'), findsOneWidget);
    });

    testWidgets('Typing 1997 navigates to PairingScreen', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const CalculatorApp());

      await tester.tap(find.widgetWithText(ElevatedButton, '1'));
      await tester.tap(find.widgetWithText(ElevatedButton, '9'));
      await tester.tap(find.widgetWithText(ElevatedButton, '9'));
      await tester.tap(find.widgetWithText(ElevatedButton, '7'));
      await tester.pumpAndSettle();

      expect(find.byType(PairingScreen), findsOneWidget);
      expect(find.text('Pair Device'), findsOneWidget);
    });

    testWidgets(
      'ChatScreen renders themes, search, emoji and sticker buttons',
      (WidgetTester tester) async {
        await tester.pumpWidget(const MaterialApp(home: ChatScreen()));

        expect(find.text('Secret Chat'), findsOneWidget);
        expect(find.byTooltip('Quick Hide to Calculator'), findsOneWidget);

        // Check emoji and sticker buttons are present
        expect(find.byIcon(Icons.emoji_emotions_outlined), findsOneWidget);
        expect(find.byIcon(Icons.emoji_objects_outlined), findsOneWidget);

        // Toggle search bar
        await tester.tap(find.byTooltip('Search Messages'));
        await tester.pump();
        expect(find.byType(TextField), findsNWidgets(2));
      },
    );
  });

  group('Voice note hold-to-record', () {
    const nativeChannel = MethodChannel('com.keshabstudios.calculator/native');

    void mockNativeChannel(WidgetTester tester) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        nativeChannel,
        (call) async {
          switch (call.method) {
            case 'ensureMicPermission':
              return true;
            case 'startRecording':
            case 'stopRecording':
              // Path intentionally missing on disk so the send flow bails
              // out at File.existsSync before touching Firebase.
              return '/tmp/hold_to_record_fake.m4a';
            default:
              return null;
          }
        },
      );
    }

    Future<void> pumpChat(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: ChatScreen()));
      await tester.pump();
    }

    testWidgets(
      'holding the mic shows recording UI and release sends the note',
      (tester) async {
        mockNativeChannel(tester);
        await pumpChat(tester);

        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Hold to Record Voice Note')),
        );
        await tester.pump();
        await tester.pump();

        // Recording UI replaced the text field while the mic is held.
        expect(find.textContaining('release to send'), findsOneWidget);
        expect(find.byTooltip('Hold to Record Voice Note'), findsNothing);

        // Tick the fake clock past the minimum hold so release counts
        // as a deliberate send rather than an accidental brush.
        await tester.pump(const Duration(seconds: 1));
        expect(find.textContaining('Recording 1s'), findsOneWidget);

        await gesture.up();
        await tester.pump();
        await tester.pump();

        // Note released: input bar restored, no crash from the missing
        // audio file (send bails before any Firebase call).
        expect(find.textContaining('release to send'), findsNothing);
        expect(find.byTooltip('Hold to Record Voice Note'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('sliding left while holding arms the cancel', (tester) async {
      mockNativeChannel(tester);
      await pumpChat(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byTooltip('Hold to Record Voice Note')),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('release to send'), findsOneWidget);

      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(find.text('Release to cancel'), findsOneWidget);

      await gesture.up();
      await tester.pump();
      await tester.pump();

      // Cancelled: recording UI gone, input bar back.
      expect(find.text('Release to cancel'), findsNothing);
      expect(find.textContaining('release to send'), findsNothing);
      expect(find.byTooltip('Hold to Record Voice Note'), findsOneWidget);
    });

    testWidgets('releasing too quickly cancels and shows hold hint', (
      tester,
    ) async {
      mockNativeChannel(tester);
      await pumpChat(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byTooltip('Hold to Record Voice Note')),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('release to send'), findsOneWidget);

      // Release without ticking any fake time: under the 600 ms threshold
      // (real elapsed wall time in the test is milliseconds).
      await gesture.up();
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('release to send'), findsNothing);
      expect(find.text('Hold to record a voice note'), findsOneWidget);
    });
  });
}
