import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

/// Visual placeholder for the future diary reader.
///
/// Keep this widget deliberately small: Claude can replace or wrap it with the
/// final hand-drawn underline and swipe reader without touching diary storage.
class CharacterDiaryEntryPlaceholder extends StatelessWidget {
  const CharacterDiaryEntryPlaceholder({
    super.key,
    required this.characterId,
    this.onTap,
  });

  final String characterId;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      L.pick(en: 'Diary', zhTW: '日記', zhCN: '日记'),
      style: YanciTheme.bodyText.copyWith(
        fontSize: 14,
        decoration: TextDecoration.underline,
        decorationColor: YanciTheme.textSecondary.withValues(alpha: 0.45),
        decorationThickness: 1,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 12),
      child: Align(
        alignment: Alignment.center,
        child: onTap == null
            ? Semantics(label: label.data, child: label)
            : InkWell(
                key: ValueKey('daily-diary-$characterId'),
                onTap: onTap,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: label,
                ),
              ),
      ),
    );
  }
}
