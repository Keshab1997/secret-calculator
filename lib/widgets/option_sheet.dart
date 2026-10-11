import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'messaging_style.dart';

/// One row of a [showOptionSheet] sheet.
class OptionSheetItem {
  final String value;
  final IconData icon;
  final String label;
  final String? subtitle;

  /// Destructive rows (clear, unpair) wear the warning colour.
  final bool destructive;

  const OptionSheetItem({
    required this.value,
    required this.icon,
    required this.label,
    this.subtitle,
    this.destructive = false,
  });
}

/// A bottom sheet of labelled options — the app's replacement for the plain
/// `PopupMenuButton` list. Returns the tapped item's value, or null when the
/// sheet is dismissed.
Future<String?> showOptionSheet(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<OptionSheetItem> items,
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => SafeArea(
      // Scrollable: a short screen (or a long option list) scrolls instead of
      // overflowing the sheet.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(0, 10, 0, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: Theme.of(sheetContext).textTheme.bodySmall
                          ?.copyWith(color: Colors.grey[600]),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 4),
            for (final item in items)
              _OptionTile(
                item: item,
                onTap: () => Navigator.pop(sheetContext, item.value),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    ),
  );
}

class _OptionTile extends StatelessWidget {
  final OptionSheetItem item;
  final VoidCallback onTap;

  const _OptionTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tint = item.destructive ? const Color(0xFFD64541) : chatGreen;
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tint.withValues(alpha: 0.10),
              ),
              child: Icon(item.icon, size: 20, color: tint),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.label,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(color: item.destructive ? tint : chatInk),
                  ),
                  if (item.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      item.subtitle!,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: Colors.grey[600]),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: Colors.grey[400]),
          ],
        ),
      ),
    );
  }
}
