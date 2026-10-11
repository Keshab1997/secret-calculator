import 'package:calculator/models/sticker_data.dart';
import 'package:calculator/widgets/sticker_art.dart';
import 'package:calculator/widgets/sticker_keyboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Love & Romance pack includes searchable rose and teddy stickers', () {
    final lovePack = stickerCategories.singleWhere(
      (category) => category.id == 'love',
    );
    expect(lovePack.name, 'Love & Romance');
    expect(
      lovePack.stickers.map((sticker) => sticker.emoji),
      containsAll(['🌹', '💐', '🧸', '🤗', '🫂', '💑', '💏', '💍', '🍫']),
    );
    expect(
      searchStickers('rose').map((sticker) => sticker.emoji),
      contains('🌹'),
    );
    expect(
      searchStickers('teddy').map((sticker) => sticker.emoji),
      contains('🧸'),
    );
    expect(
      searchStickers('bouquet').map((sticker) => sticker.emoji),
      contains('💐'),
    );
  });

  testWidgets('rose and teddy artwork can be sent from the love pack', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StickerKeyboard(onStickerSelected: (emoji) => selected = emoji),
        ),
      ),
    );
    await tester.pump();

    final loveChip = find.ancestor(
      of: find.text('Love & Romance'),
      matching: find.byType(FilterChip),
    );
    expect(
      tester.widget<FilterChip>(loveChip).selectedColor,
      const Color(0xFFFFE4EC),
    );

    final rose = find.byWidgetPredicate(
      (widget) => widget is StickerArt && widget.emoji == '🌹',
    );
    expect(rose, findsOneWidget);
    await tester.tap(rose);
    expect(selected, '🌹');

    final teddy = find.byWidgetPredicate(
      (widget) => widget is StickerArt && widget.emoji == '🧸',
    );
    expect(teddy, findsOneWidget);
    await tester.tap(teddy);
    expect(selected, '🧸');
    expect(tester.takeException(), isNull);
  });
}
