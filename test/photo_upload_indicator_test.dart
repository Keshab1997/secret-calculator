import 'dart:io';

import 'package:calculator/widgets/photo_upload_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('keeps an animated spinner until upload progress is reported', (
    tester,
  ) async {
    Future<void> pumpIndicator(double? progress) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PhotoUploadIndicator(
              image: File('/missing-test-photo.jpg'),
              progress: progress,
              failed: false,
            ),
          ),
        ),
      ),
    );

    await pumpIndicator(0);
    await tester.pump();

    var loader = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(loader.value, isNull);
    expect(find.text('Uploading…'), findsOneWidget);

    await pumpIndicator(0.43);
    loader = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(loader.value, 0.43);
    expect(find.text('43%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
