import 'package:calculator/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows an animated toast below the app bar, not at the bottom', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Test screen')),
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => AppToast.show(
                  context,
                  'Profile saved',
                  kind: AppToastKind.success,
                  duration: const Duration(seconds: 1),
                ),
                child: const Text('Show toast'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show toast'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final toast = find.byKey(AppToast.toastKey);
    expect(toast, findsOneWidget);
    expect(find.text('Profile saved'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    final top = tester.getTopLeft(toast).dy;
    expect(top, greaterThan(kToolbarHeight));
    expect(top, lessThan(160));

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 220));
    expect(toast, findsNothing);
  });
}
