import 'package:flutter/material.dart';

import '../screens/rp_storyline_screen.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class RpStorylineEntry extends StatelessWidget {
  const RpStorylineEntry({super.key, required this.characterId});

  final String characterId;

  @override
  Widget build(BuildContext context) {
    final label = L.pick(en: 'Story archive', zhTW: '劇情檔案', zhCN: '剧情档案');
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          key: const ValueKey('rp-storyline-entry'),
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RpStorylineScreen(characterId: characterId),
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: YanciTheme.accent.withValues(alpha: 0.82),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: YanciTheme.textSecondary.withValues(alpha: 0.34),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
