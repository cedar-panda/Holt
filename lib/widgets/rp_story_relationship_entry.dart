import 'package:flutter/material.dart';

import '../screens/rp_story_relationship_screen.dart';
import '../screens/rp_storyline_screen.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class RpStoryRelationshipEntry extends StatelessWidget {
  const RpStoryRelationshipEntry({
    super.key,
    required this.characterId,
    this.continuityId = 'main',
  });

  final String characterId;
  final String continuityId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
      child: Semantics(
        button: true,
        label: L.pick(en: 'Relationships', zhTW: '人物關係', zhCN: '人物关系'),
        child: InkWell(
          key: const ValueKey('rp-story-relationship-entry'),
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            final selected = continuityId == 'main'
                ? await showRpStorylinePicker(context, characterId: characterId)
                : continuityId;
            if (!context.mounted || selected == null) return;
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RpStoryRelationshipScreen(
                  characterId: characterId,
                  continuityId: selected,
                ),
              ),
            );
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      L.pick(en: 'Relationships', zhTW: '人物關係', zhCN: '人物关系'),
                      style: TextStyle(
                        color: YanciTheme.accent.withValues(alpha: 0.78),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
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
