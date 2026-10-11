import 'package:flutter/material.dart';

import '../models/sticker_data.dart';
import 'sticker_art.dart';

class StickerKeyboard extends StatefulWidget {
  final void Function(String emoji) onStickerSelected;

  const StickerKeyboard({super.key, required this.onStickerSelected});

  @override
  State<StickerKeyboard> createState() => _StickerKeyboardState();
}

class _StickerKeyboardState extends State<StickerKeyboard> {
  final TextEditingController _searchController = TextEditingController();
  int _selectedCategoryIndex = 0;
  String _searchQuery = '';

  final List<StickerCategory> _categories = getAllStickerCategories();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final width = MediaQuery.sizeOf(context).width;
    final panelHeight = (MediaQuery.sizeOf(context).height * 0.48)
        .clamp(310.0, 360.0)
        .toDouble();
    final columnCount = width >= 600 ? 4 : 3;
    final isSearching = _searchQuery.isNotEmpty;
    final outline = isDark ? const Color(0xFF2A3942) : const Color(0xFFE7E9EE);
    final searchFill = isDark
        ? const Color(0xFF111B21)
        : const Color(0xFFF4F6F7);
    final tileColor = isDark
        ? const Color(0xFF1A252B)
        : const Color(0xFFFAFBFC);

    final allStickers = isSearching
        ? searchStickers(_searchQuery)
        : _categories[_selectedCategoryIndex].stickers;

    return Material(
      color: theme.colorScheme.surface,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.14),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        side: BorderSide(color: outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: panelHeight,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 10, 0, 4),
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.black12,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
              child: SizedBox(
                height: 46,
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search stickers',
                    hintStyle: TextStyle(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.52,
                      ),
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.58,
                      ),
                    ),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.clear_rounded, size: 18),
                            onPressed: () {
                              setState(() {
                                _searchQuery = '';
                                _searchController.clear();
                              });
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: searchFill,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide(
                        color: isDark
                            ? const Color(0xFFFF9EB8).withValues(alpha: 0.55)
                            : const Color(0xFFC04868).withValues(alpha: 0.42),
                      ),
                    ),
                  ),
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
              ),
            ),
            if (!isSearching)
              SizedBox(
                height: 52,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: _categories.length,
                  itemBuilder: (context, index) {
                    final category = _categories[index];
                    final isSelected = index == _selectedCategoryIndex;
                    final isLovePack = category.id == 'love';
                    final selectedFill = isLovePack
                        ? (isDark
                              ? const Color(0xFF4A2938)
                              : const Color(0xFFFFE4EC))
                        : (isDark
                              ? const Color(0xFF1C4238)
                              : const Color(0xFFD9FDD3));
                    final selectedAccent = isLovePack
                        ? (isDark
                              ? const Color(0xFFFF9EB8)
                              : const Color(0xFFC04868))
                        : (isDark
                              ? const Color(0xFF7FE0AF)
                              : const Color(0xFF168B53));

                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: FilterChip(
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(category.icon),
                            const SizedBox(width: 6),
                            Text(category.name),
                          ],
                        ),
                        labelStyle: TextStyle(
                          color: isSelected
                              ? selectedAccent
                              : theme.colorScheme.onSurface.withValues(
                                  alpha: 0.75,
                                ),
                          fontSize: 12.5,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                        selected: isSelected,
                        showCheckmark: false,
                        onSelected: (_) =>
                            setState(() => _selectedCategoryIndex = index),
                        backgroundColor: isDark
                            ? const Color(0xFF202C33)
                            : const Color(0xFFF2F4F5),
                        selectedColor: selectedFill,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        side: BorderSide(
                          color: isSelected
                              ? selectedAccent.withValues(alpha: 0.28)
                              : outline,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    );
                  },
                ),
              ),
            Expanded(
              child: allStickers.isEmpty
                  ? Center(
                      child: Text(
                        'No stickers found. Try love, happy or heart.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.64,
                          ),
                        ),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 14),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columnCount,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 1,
                      ),
                      itemCount: allStickers.length,
                      itemBuilder: (context, index) {
                        final sticker = allStickers[index];
                        final shape = RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                          side: BorderSide(color: outline),
                        );

                        return Semantics(
                          label: sticker.name,
                          button: true,
                          child: Material(
                            color: tileColor,
                            shape: shape,
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () =>
                                  widget.onStickerSelected(sticker.emoji),
                              customBorder: shape,
                              child: Center(
                                child: StickerArt(
                                  emoji: sticker.emoji,
                                  size: 84,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
