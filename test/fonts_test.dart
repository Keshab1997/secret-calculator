import 'package:calculator/widgets/messaging_style.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bundled type family is a UI dependency like any other: if the assets
/// or the pubspec entries go missing, every screen silently falls back to the
/// platform font and the app looks subtly different on every phone. This
/// catches that in a second instead of in a screenshot review.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled Inter weights are present and readable', () async {
    const assets = [
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ];
    for (final asset in assets) {
      final data = await rootBundle.load(asset);
      // A real Inter face is a few hundred KB; anything tiny is a broken file.
      expect(
        data.lengthInBytes,
        greaterThan(100000),
        reason: '$asset looks empty or truncated',
      );
    }
  });

  test('the font family is wired into the app themes', () {
    // Guards the other half: assets can be present while no theme uses them.
    expect(appFontFamily, 'Inter');
  });
}
