import 'package:calculator/main.dart';
import 'package:calculator/screens/calculator_screen.dart';
import 'package:calculator/screens/chat_screen.dart';
import 'package:calculator/screens/pairing_screen.dart';
import 'package:flutter/material.dart';
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

    testWidgets('ChatScreen renders themes, search, and emoji categories', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: ChatScreen()));

      expect(find.text('Secret Chat'), findsOneWidget);
      expect(find.byTooltip('Quick Hide to Calculator'), findsOneWidget);

      // Open categorized emoji picker
      await tester.tap(find.byIcon(Icons.emoji_emotions_outlined));
      await tester.pump();
      expect(find.text('Smileys'), findsOneWidget);
      expect(find.text('Love'), findsOneWidget);
      expect(find.text('Secret'), findsOneWidget);

      // Toggle search bar
      await tester.tap(find.byTooltip('Search Messages'));
      await tester.pump();
      expect(find.byType(TextField), findsNWidgets(2));
    });
  });
}
