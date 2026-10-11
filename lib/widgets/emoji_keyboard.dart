import 'package:flutter/material.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

class EmojiKeyboard extends StatelessWidget {
  final void Function(Emoji emoji) onEmojiSelected;
  final Color? backgroundColor;

  const EmojiKeyboard({
    super.key,
    required this.onEmojiSelected,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 250,
      color: backgroundColor ?? Theme.of(context).colorScheme.surface,
      child: EmojiPicker(
        onEmojiSelected: (Category? category, Emoji emoji) {
          onEmojiSelected(emoji);
        },
        config: Config(
          height: 250,
          emojiTextStyle: const TextStyle(fontSize: 20),
          viewOrderConfig: const ViewOrderConfig(
            top: EmojiPickerItem.categoryBar,
            middle: EmojiPickerItem.emojiView,
            bottom: EmojiPickerItem.searchBar,
          ),
          emojiViewConfig: EmojiViewConfig(
            columns: 8,
            emojiSizeMax: 32,
            verticalSpacing: 0,
            horizontalSpacing: 0,
            gridPadding: EdgeInsets.zero,
            buttonMode: ButtonMode.MATERIAL,
          ),
          categoryViewConfig: CategoryViewConfig(
            initCategory: Category.SMILEYS,
            categoryIcons: const CategoryIcons(),
            iconColor: Colors.grey,
            iconColorSelected: Colors.blue,
            indicatorColor: Colors.blue,
            backspaceColor: Colors.blue,
          ),
          bottomActionBarConfig: const BottomActionBarConfig(
            enabled: true,
            showBackspaceButton: true,
            showSearchViewButton: true,
            buttonColor: Colors.blue,
            buttonIconColor: Colors.white,
          ),
          searchViewConfig: const SearchViewConfig(
            backgroundColor: Color(0xFFEBEFF2),
            buttonIconColor: Colors.black26,
          ),
          skinToneConfig: const SkinToneConfig(enabled: true),
        ),
      ),
    );
  }
}
