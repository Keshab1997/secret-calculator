import 'dart:convert';
import 'dart:io';

import 'package:calculator/screens/calculator_screen.dart';
import 'package:calculator/services/calculator_history_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryHistory extends CalculatorHistoryStore {
  List<CalculationEntry> entries = [];
  bool failSave = false;
  bool failLoad = false;
  @override
  Future<List<CalculationEntry>> load() async {
    if (failLoad) throw const FormatException('Invalid history');
    return List.of(entries);
  }

  @override
  Future<void> save(List<CalculationEntry> values) async {
    if (failSave) throw const FileSystemException('Read only');
    entries = List.of(values);
  }
}

void main() {
  void enter(CalculatorEngine engine, String keys) {
    for (final key in keys.split('')) {
      engine.press(key);
    }
  }

  group('Calculator expressions', () {
    test(
      'retains every term, previews and completes the requested example',
      () {
        final engine = CalculatorEngine();
        enter(engine, '12+12+13+78-60');
        expect(engine.expression, '12+12+13+78-60');
        expect(engine.output, '55');
        expect(engine.completedCalculation, isNull);
        engine.press('=');
        expect(engine.output, '55');
        expect(engine.completedCalculation?.expression, '12+12+13+78-60');
        expect(engine.completedCalculation?.result, '55');
        engine.press('=');
        expect(engine.completedCalculation, isNull);
      },
    );
    test(
      'standard precedence, chained divisions and rounded decimal artifacts',
      () {
        for (final entry in {
          '2+3×4': '14',
          '100÷5÷2': '10',
          '20-2×3+4': '18',
          '0.1+0.2': '0.3',
          '12.5×2-0.5': '24.5',
          '1÷3': '0.333333333333333',
        }.entries) {
          final engine = CalculatorEngine();
          enter(engine, '${entry.key}=');
          expect(engine.output, entry.value, reason: entry.key);
        }
      },
    );
    test(
      'operator replacement and pending operators do not invent operands',
      () {
        final engine = CalculatorEngine();
        enter(engine, '12+-3=');
        expect(engine.output, '9');
        engine.press('C');
        enter(engine, '12+=');
        expect(engine.completedCalculation, isNull);
        expect(engine.output, '12');
      },
    );
    test('negative operands, percentage and repeat operations', () {
      final engine = CalculatorEngine();
      enter(engine, '12+3');
      engine.press('±');
      engine.press('=');
      expect(engine.output, '9');
      enter(engine, '×2=');
      expect(engine.output, '18');
      engine.press('C');
      enter(engine, '200×10%=');
      expect(engine.output, '20');
      engine.press('C');
      enter(engine, '50%');
      expect(engine.output, '0.5');
    });
    test(
      'new digit resets completed result, backspace edits original expression',
      () {
        final engine = CalculatorEngine();
        enter(engine, '12+3=');
        engine.press('⌫');
        expect(engine.expression, '12+');
        enter(engine, '8=');
        expect(engine.output, '20');
        engine.press('6');
        expect(engine.output, '6');
        expect(engine.expression, '6');
        engine.press('C');
        engine.press('±');
        engine.press('⌫');
        expect(engine.output, '0');
      },
    );
    test('divide by zero is recoverable and never becomes history', () {
      final engine = CalculatorEngine();
      enter(engine, '9÷0=');
      expect(engine.output, 'Error');
      expect(engine.completedCalculation, isNull);
      engine.press('⌫');
      enter(engine, '3=');
      expect(engine.output, '3');
    });
    test('history restoration never runs code detection or creates a completion event', () {
      final engine = CalculatorEngine();
      engine.restoreExpression('2000-3');
      expect(engine.output, '1997');
      expect(engine.completedCalculation, isNull);
      engine.useResult('1997');
      expect(engine.output, '1997');
      expect(engine.completedCalculation, isNull);
      enter(engine, '+3=');
      expect(engine.output, '2000');
      expect(
        () => engine.restoreExpression('1; do something'),
        throwsFormatException,
      );
    });
    test('unlock input wipes display and never creates a history event', () {
      final engine = CalculatorEngine(customCode: '2580');
      enter(engine, '12+3=');
      enter(engine, '258');
      expect(engine.press('0'), isTrue);
      expect(engine.expression, isEmpty);
      expect(engine.output, '0');
      expect(engine.completedCalculation, isNull);
      enter(engine, '199');
      expect(engine.press('7'), isTrue);
      expect(engine.output, '0');
    });
    test('bounds input length and supports scientific results without nonfinite output', () {
      final engine = CalculatorEngine();
      enter(engine, '1234567890123456789');
      expect(engine.expression.length, 15);
      engine.press('C');
      enter(engine, '999999999999999×999999999999999=');
      expect(engine.output, contains('e'));
      enter(engine, '÷999999999999999=');
      expect(double.parse(engine.output).isFinite, isTrue);
      expect(() => engine.useResult('Infinity'), throwsFormatException);
    });
  });

  group('Local history files', () {
    late Directory directory;
    late File file;
    setUp(() {
      directory = Directory.systemTemp.createTempSync('calc-history-');
      file = File('${directory.path}/history.json');
    });
    tearDown(() => directory.deleteSync(recursive: true));
    CalculationEntry entry(int index) => CalculationEntry(
      id: '$index',
      expression: '$index+2',
      result: '${index + 2}',
      createdAt: DateTime(2026, 10, 11, 10, 0, index),
    );
    test(
      'persists across store recreation and keeps only the last 200 entries',
      () async {
        final store = CalculatorHistoryStore(fileOverride: file);
        expect(await store.load(), isEmpty);
        await store.save(List.generate(205, entry));
        final restored = await CalculatorHistoryStore(fileOverride: file)
            .load();
        expect(restored.length, 200);
        expect(restored.first.expression, '0+2');
        expect(restored.last.id, '199');
      },
    );
    test('serializes rapid writes, and an explicit clear persists', () async {
      final store = CalculatorHistoryStore(fileOverride: file);
      await Future.wait([
        store.save([entry(1)]),
        store.save([entry(2), entry(1)]),
        store.save([]),
      ]);
      expect(await store.load(), isEmpty);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });
    test(
      'invalid records are skipped; corrupt files are reported, not rewritten',
      () async {
        file.writeAsStringSync(
          jsonEncode({
            'version': 1,
            'entries': [
              {'expression': 'bad'},
              entry(4).toJson(),
            ],
          }),
        );
        final store = CalculatorHistoryStore(fileOverride: file);
        expect((await store.load()).single.id, '4');
        file.writeAsStringSync('{broken');
        await expectLater(store.load(), throwsFormatException);
        expect(file.readAsStringSync(), '{broken');
      },
    );
    test('write failures propagate and a later write may recover', () async {
      final path = File('${directory.path}/missing/history.json');
      final store = CalculatorHistoryStore(fileOverride: path);
      await expectLater(
        store.save([entry(1)]),
        throwsA(isA<FileSystemException>()),
      );
      path.parent.createSync();
      await store.save([entry(2)]);
      expect((await store.load()).single.id, '2');
    });
  });

  Future<void> tapKeys(WidgetTester tester, String sequence) async {
    for (final key in sequence.split('')) {
      await tester.tap(find.byKey(ValueKey('calculator-key-$key')));
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'visible full expression, live result, save, restore and clear history',
    (tester) async {
      final store = MemoryHistory();
      await tester.pumpWidget(
        MaterialApp(home: CalculatorScreen(historyStore: store)),
      );
      await tapKeys(tester, '12+12+13+78-60');
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('calculator-expression')))
            .data,
        '12 + 12 + 13 + 78 − 60',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('calculator-result')))
            .data,
        '55',
      );
      expect(store.entries, isEmpty);
      await tapKeys(tester, '=');
      expect(store.entries.single.result, '55');
      await tester.tap(find.byTooltip('History'));
      await tester.pumpAndSettle();
      expect(find.text('= 55'), findsOneWidget);
      await tester.tap(find.text('12 + 12 + 13 + 78 − 60').last);
      await tester.pumpAndSettle();
      expect(store.entries.length, 1);
      await tester.tap(find.byTooltip('History'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Clear history'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.entries.length, 1);
      await tester.tap(find.byTooltip('Clear history'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear history'));
      await tester.pumpAndSettle();
      expect(store.entries, isEmpty);
    },
  );
  testWidgets(
    'history saving failure is visible instead of silently reporting success',
    (tester) async {
      final store = MemoryHistory()..failSave = true;
      await tester.pumpWidget(
        MaterialApp(home: CalculatorScreen(historyStore: store)),
      );
      await tapKeys(tester, '2+3=');
      expect(
        find.text('Could not save history on this device.'),
        findsOneWidget,
      );
      expect(store.entries, isEmpty);
    },
  );

  testWidgets('unreadable history is not overwritten by a new calculation', (
    tester,
  ) async {
    final store = MemoryHistory()..failLoad = true;
    await tester.pumpWidget(
      MaterialApp(home: CalculatorScreen(historyStore: store)),
    );
    await tapKeys(tester, '2+3=');
    expect(
      find.text('History unavailable. This result was not saved.'),
      findsOneWidget,
    );
    expect(store.entries, isEmpty);
  });
  testWidgets(
    'unlock leaves no entry and returning shows an ordinary cleared calculator',
    (tester) async {
      final store = MemoryHistory();
      await tester.pumpWidget(
        MaterialApp(home: CalculatorScreen(historyStore: store)),
      );
      await tapKeys(tester, '2+3=1997');
      expect(store.entries.length, 1);
      expect(store.entries.single.expression, '2+3');
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('calculator-result')))
            .data,
        '0',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('calculator-expression')))
            .data,
        '0',
      );
    },
  );
  testWidgets('classic black grey orange theme keeps the smart display', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: CalculatorScreen(historyStore: MemoryHistory())),
    );
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      Colors.black,
    );
    final digit = tester.widget<ElevatedButton>(
      find.byKey(const ValueKey('calculator-key-7')),
    );
    final operator = tester.widget<ElevatedButton>(
      find.byKey(const ValueKey('calculator-key-+')),
    );
    final equals = tester.widget<ElevatedButton>(
      find.byKey(const ValueKey('calculator-key-=')),
    );
    expect(digit.style!.backgroundColor!.resolve({}), const Color(0xFF303030));
    expect(operator.style!.backgroundColor!.resolve({}), Colors.orange);
    expect(equals.style!.backgroundColor!.resolve({}), Colors.orange);
    await tapKeys(tester, '12+12+13+78-60');
    final result = tester.widget<Text>(
      find.byKey(const ValueKey('calculator-result')),
    );
    expect(result.data, '55');
    expect(result.style!.color, Colors.white);
  });
  testWidgets(
    'short result aligns with keypad edge instead of shrinking the display',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: CalculatorScreen(historyStore: MemoryHistory())),
      );
      await tapKeys(tester, '7+5=');
      final result = tester.getRect(
        find.byKey(const ValueKey('calculator-result')),
      );
      final equals = tester.getRect(
        find.byKey(const ValueKey('calculator-key-=')),
      );
      expect(result.right, closeTo(374, 0.1));
      expect(result.right, closeTo(equals.right, 0.1));
      expect(tester.takeException(), isNull);
    },
  );
  for (final size in [const Size(320, 568), const Size(844, 390)]) {
    testWidgets('long expression is scrollable without overflow at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: CalculatorScreen(historyStore: MemoryHistory())),
      );
      await tapKeys(tester, '123456+789012+345678+901234-12345');
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('calculator-result')))
            .data,
        '2,147,035',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
