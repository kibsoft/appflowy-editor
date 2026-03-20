import 'package:appflowy_editor/src/editor_state.dart';
import 'package:flutter/material.dart';

typedef ContextMenuWidgetBuilder = Widget Function(
  BuildContext context,
  Offset position,
  EditorState editorState,
  VoidCallback onPressed,
);

class ContextMenuItem {
  ContextMenuItem({
    required String Function() getName,
    required this.onPressed,
    this.isApplicable,
  }) : _getName = getName;

  final String Function() _getName;
  final void Function(EditorState editorState) onPressed;
  final bool Function(EditorState editorState)? isApplicable;

  String get name => _getName();
}

class ContextMenu extends StatelessWidget {
  const ContextMenu({
    super.key,
    required this.position,
    required this.editorState,
    required this.items,
    required this.onPressed,
    this.borderRadius = 12.0,
    this.padding = const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
    this.itemPadding = const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
  });

  final Offset position;
  final EditorState editorState;
  final List<List<ContextMenuItem>> items;
  final VoidCallback onPressed;

  /// Corner radius for the menu panel and each menu row ripple.
  final double borderRadius;

  /// Insets between the panel edge and the menu rows (affects shadow bounds).
  final EdgeInsetsGeometry padding;

  /// Insets around each row's label (horizontal inset changes text-to-edge gap
  /// without changing how the outer shadow panel is sized).
  final EdgeInsetsGeometry itemPadding;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      for (var j = 0; j < items[i].length; j++) {
        if (items[i][j].isApplicable != null &&
            !items[i][j].isApplicable!(editorState)) {
          continue;
        }

        if (j == 0 && i != 0) {
          children.add(const Divider());
        }

        children.add(
          StatefulBuilder(
            builder: (BuildContext context, setState) {
              return Material(
                child: InkWell(
                  customBorder: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(borderRadius),
                  ),
                  onTap: () {
                    items[i][j].onPressed(editorState);
                    onPressed();
                  },
                  onHover: (value) => setState(() {}),
                  child: Padding(
                    padding: itemPadding,
                    child: Text(
                      items[i][j].name,
                      textAlign: TextAlign.start,
                      style: const TextStyle(
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      }
    }

    return Positioned(
      top: position.dy,
      left: position.dx,
      child: Container(
        padding: padding,
        constraints: const BoxConstraints(
          minWidth: 140,
        ),
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              blurRadius: 5,
              spreadRadius: 1,
              color: Colors.black.withValues(alpha: 0.1),
            ),
          ],
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}
