import 'package:flutter/material.dart';
import '../memory/database.dart';
import '../services/locale_strings.dart';

/// UI_SLOT: chat_reply_variants — latest reply only, no surrounding card.
class ReplyVariantControls extends StatefulWidget {
  const ReplyVariantControls({
    super.key,
    required this.messageId,
    required this.revision,
    required this.color,
    required this.onSelect,
  });
  final int messageId;
  final int revision;
  final Color color;
  final ValueChanged<int> onSelect;

  @override
  State<ReplyVariantControls> createState() => _ReplyVariantControlsState();
}

class _ReplyVariantControlsState extends State<ReplyVariantControls> {
  late Future<ReplyVariantIndex> _index;
  @override
  void initState() {
    super.initState();
    _index = ReplyVariants.index(widget.messageId);
  }

  @override
  void didUpdateWidget(covariant ReplyVariantControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageId != widget.messageId ||
        oldWidget.revision != widget.revision) {
      _index = ReplyVariants.index(widget.messageId);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ReplyVariantIndex>(
    future: _index,
    builder: (context, snapshot) {
      if (snapshot.hasError || !snapshot.hasData) {
        return const SizedBox.shrink();
      }
      final variants = snapshot.data!;
      if (variants.archiveIds.length < 2) return const SizedBox.shrink();
      Widget arrow(IconData icon, int next, String label) => IconButton(
        tooltip: label,
        iconSize: 18,
        color: widget.color,
        onPressed:
            next < 0 ||
                next >= variants.archiveIds.length ||
                variants.archiveIds[next] == null
            ? null
            : () => widget.onSelect(variants.archiveIds[next]!),
        icon: Icon(icon),
      );
      return Align(
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            arrow(
              Icons.chevron_left,
              variants.selected - 1,
              L.pick(en: 'Previous reply', zhTW: '上一版回覆', zhCN: '上一版回复'),
            ),
            Text(
              '${variants.selected + 1}/${variants.archiveIds.length}',
              style: TextStyle(fontSize: 12, color: widget.color),
            ),
            arrow(
              Icons.chevron_right,
              variants.selected + 1,
              L.pick(en: 'Next reply', zhTW: '下一版回覆', zhCN: '下一版回复'),
            ),
          ],
        ),
      );
    },
  );
}
