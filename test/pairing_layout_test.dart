import 'package:calculator/screens/pairing_screen.dart';
import 'package:calculator/widgets/messaging_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Personal-ID pairing keeps the main controls reachable on compact phones;
/// the retained legacy invite flow is deliberately collapsed by default.
void main() {
  Future<void> pumpPairingAt(WidgetTester tester, Size logicalSize) async {
    tester.view.physicalSize = logicalSize * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(theme: messagingTheme, home: const PairingScreen()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expectPairingControlsReachable(WidgetTester tester) async {
    expect(tester.takeException(), isNull, reason: 'layout overflowed');
    expect(find.text('Connect by Personal ID'), findsOneWidget);
    expect(find.text('Your Personal ID'), findsOneWidget);
    expect(find.text('Add a contact'), findsOneWidget);

    final sendButton = find.text('Send request');
    await tester.ensureVisible(sendButton);
    await tester.pumpAndSettle();
    expect(sendButton.hitTestable(), findsOneWidget);
    final legacySection = find.text('Legacy secure invite');
    await tester.scrollUntilVisible(
      legacySection,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(legacySection.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'layout overflowed');
  }

  testWidgets('pairing controls are reachable on a 360x640 phone', (
    tester,
  ) async {
    await pumpPairingAt(tester, const Size(360, 640));
    await expectPairingControlsReachable(tester);
  });

  testWidgets('pairing controls are reachable on a 320x568 phone', (
    tester,
  ) async {
    await pumpPairingAt(tester, const Size(320, 568));
    await expectPairingControlsReachable(tester);
  });
}
