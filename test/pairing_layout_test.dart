import 'package:calculator/screens/pairing_screen.dart';
import 'package:calculator/widgets/messaging_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pairing screen is the first thing a new user sees. It must fit a phone
/// screen whole — a JOIN button that hides below the fold reads as a broken
/// screen. These tests pin that down on the two smallest common phone sizes.
void main() {
  Future<void> pumpPairingAt(WidgetTester tester, Size logicalSize) async {
    tester.view.physicalSize = logicalSize * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(theme: messagingTheme, home: const PairingScreen()),
    );
    await tester.pump();
  }

  void expectFitsWithoutScrolling(WidgetTester tester, Size size) {
    expect(tester.takeException(), isNull, reason: 'layout overflowed');

    // Both ends of the screen must be on-screen at once: the heading at the
    // top and the JOIN button at the bottom.
    for (final label in ['Your Pair Code', 'Join Partner', 'JOIN']) {
      final finder = find.text(label);
      expect(finder, findsOneWidget, reason: '$label is missing');
      final rect = tester.getRect(finder);
      expect(
        rect.top,
        greaterThanOrEqualTo(0),
        reason: '$label starts above the screen',
      );
      expect(
        rect.bottom,
        lessThanOrEqualTo(size.height),
        reason: '$label sits below the fold — the user must scroll to reach it',
      );
      expect(
        finder.hitTestable(),
        findsOneWidget,
        reason: '$label is not reachable by touch',
      );
    }
  }

  testWidgets('fits a 360x640 phone without scrolling', (tester) async {
    await pumpPairingAt(tester, const Size(360, 640));
    expectFitsWithoutScrolling(tester, const Size(360, 640));
  });

  testWidgets('fits a 320x568 small phone without scrolling', (tester) async {
    await pumpPairingAt(tester, const Size(320, 568));
    expectFitsWithoutScrolling(tester, const Size(360, 640));
  });
}
