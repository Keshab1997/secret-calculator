import 'package:flutter_test/flutter_test.dart';
import 'package:calculator/main.dart';

void main() {
  testWidgets('Calculator app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const CalculatorApp());
    expect(find.text('Calculator'), findsOneWidget);
  });
}