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

  testWidgets(
    'expanding the legacy invite does not misread the ExpansionTile bool as a scroll offset',
    (tester) async {
      await pumpPairingAt(tester, const Size(360, 640));

      final tile = find.text('Legacy secure invite');
      await tester.scrollUntilVisible(
        tile,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      await tester.tap(tile);
      await tester.pumpAndSettle();

      // The field inside the section must mount without the
      // "type 'bool' is not a subtype of type 'double?'" PageStorage cast crash.
      expect(tester.takeException(), isNull, reason: 'legacy field crashed');
      expect(
        find.byKey(const PageStorageKey<String>('legacy-invite-field')),
        findsOneWidget,
      );
    },
  );

  // The invite *display* (a SelectableText) mounts only once an invite has
  // been generated, so the screen-level test above can never reach it — it
  // needs working Firebase. This harness reproduces the exact arrangement
  // the screen uses: a keyless scrollable inside the keyed ExpansionTile
  // reads the tile's saved expansion bool back as a double scroll offset.
  // It fails the moment that pattern is reintroduced without its own key.
  testWidgets('a selectable inside the keyed legacy tile needs its own slot', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              ExpansionTile(
                key: const PageStorageKey<String>('legacy-pairing'),
                title: const Text('Legacy secure invite'),
                children: [
                  SelectableText(
                    'ABCD23.EFGH45.KLMN67',
                    key: const PageStorageKey<String>('legacy-invite-code'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('Legacy secure invite'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: 'selectable crashed');
    expect(find.text('ABCD23.EFGH45.KLMN67'), findsOneWidget);
  });
}
