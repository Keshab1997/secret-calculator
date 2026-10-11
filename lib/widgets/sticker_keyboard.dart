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
    final isSearching = _searchQuery.isNotEmpty;

    // Filter stickers based on search
    final allStickers = isSearching
        ? searchStickers(_searchQuery)
        : _categories[_selectedCategoryIndex].stickers;

    return Container(
      height: 300,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
        boxShadow: [
          BoxShadow(color: Colors.black12, blurRadius: 10, spreadRadius: 2),
        ],
      ),
      child: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search stickers...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          setState(() {
                            _searchQuery = '';
                            _searchController.clear();
                          });
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Colors.grey.shade200,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              onChanged: (value) => setState(() => _searchQuery = value),
            ),
          ),

          // Category tabs (hidden during search)
          if (!isSearching)
            SizedBox(
              height: 40,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: _categories.length,
                itemBuilder: (context, index) {
                  final category = _categories[index];
                  final isSelected = index == _selectedCategoryIndex;

                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                    child: FilterChip(
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(category.icon),
                          const SizedBox(width: 4),
                          Text(category.name),
                        ],
                      ),
                      selected: isSelected,
                      onSelected: (_) =>
                          setState(() => _selectedCategoryIndex = index),
                      backgroundColor: Colors.grey.shade200,
                      selectedColor: category.id == 'love'
                          ? const Color(0xFFFFE4EC)
                          : const Color(0xFFD9FDD3),
                      checkmarkColor: category.id == 'love'
                          ? const Color(0xFFC04868)
                          : const Color(0xFF168B53),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  );
                },
              ),
            ),

          // Sticker grid
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: allStickers.isEmpty
                  ? const Center(
                      child: Text(
                        'No stickers found. Try love, happy or heart.',
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.only(top: 4),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            mainAxisSpacing: 6,
                            crossAxisSpacing: 6,
                            childAspectRatio: 1,
                          ),
                      itemCount: allStickers.length,
                      itemBuilder: (context, index) {
                        final sticker = allStickers[index];

                        return Semantics(
                          label: sticker.name,
                          button: true,
                          child: GestureDetector(
                            onTap: () =>
                                widget.onStickerSelected(sticker.emoji),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Center(
                                child: StickerArt(emoji: sticker.emoji),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
