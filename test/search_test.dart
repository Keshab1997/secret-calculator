import 'package:calculator/screens/chat_screen.dart';
import 'package:calculator/widgets/messaging_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-chat search: a count of what matched, and the match itself highlighted
/// so it can be spotted without reading.
void main() {
  ChatMessage msg(String id, String text, DateTime t) =>
      ChatMessage(id: id, text: text, isMe: true, timestamp: t);

  Finder searchField() => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == 'Search messages…',
  );

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search Messages'));
    await tester.pumpAndSettle();
  }

  Future<void> pumpChat(WidgetTester tester, List<ChatMessage> messages) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: messagingTheme,
        home: ChatScreen(contactName: 'Partner', initialMessages: messages),
      ),
    );
    await tester.pump();
  }

  testWidgets('searching shows a match count and highlights the matches', (
    tester,
  ) async {
    final day = DateTime(2026, 10, 11, 12);
    await pumpChat(tester, [
      msg('a', 'my secret plan', day),
      msg('b', 'nothing here at all', day.add(const Duration(minutes: 1))),
      msg('c', 'keep the secret safe', day.add(const Duration(minutes: 2))),
    ]);

    await openSearch(tester);
    expect(searchField(), findsOneWidget);
    await tester.enterText(searchField(), 'secret');
    await tester.pump();

    // Two messages contain the word, so the banner says so.
    expect(find.text('2 matches'), findsOneWidget);

    // The matching words are rendered as rich text with a highlighted span.
    final rich = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => t.textSpan != null)
        .toList();
    expect(rich, isNotEmpty);
    var highlighted = false;
    for (final text in rich) {
      for (final span
          in (text.textSpan! as TextSpan).children ?? const <InlineSpan>[]) {
        if (span.style?.background != null) highlighted = true;
      }
    }
    expect(highlighted, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single match reads as one', (tester) async {
    final day = DateTime(2026, 10, 11, 12);
    await pumpChat(tester, [
      msg('a', 'one secret here', day),
      msg('b', 'nothing else', day),
    ]);
    await openSearch(tester);
    await tester.enterText(searchField(), 'secret');
    await tester.pump();
    expect(find.text('1 match'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no matches shows the empty state, not a crash', (tester) async {
    final day = DateTime(2026, 10, 11, 12);
    await pumpChat(tester, [msg('a', 'hello world', day)]);
    await openSearch(tester);
    await tester.enterText(searchField(), 'zzz');
    await tester.pump();
    expect(find.text('0 matches'), findsOneWidget);
    expect(find.text('No matching messages found'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
