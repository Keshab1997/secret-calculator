import 'package:calculator/widgets/messaging_style.dart';
import 'package:calculator/widgets/privacy_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('privacy policy explains data handling and prohibited misuse', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: messagingTheme,
        home: const Scaffold(body: PrivacyPolicySheet()),
      ),
    );

    expect(find.text('Privacy, safety & acceptable use'), findsOneWidget);
    expect(find.text('Information handled'), findsOneWidget);

    final policyScroll = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.text('Encryption and its limits'),
      300,
      scrollable: policyScroll,
    );
    expect(find.text('Encryption and its limits'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Safety and acceptable use'),
      350,
      scrollable: policyScroll,
    );
    expect(find.text('Safety and acceptable use'), findsOneWidget);
    expect(find.text('Children'), findsOneWidget);
  });
}
