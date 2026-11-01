import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../memory/database.dart';
import '../screens/rp_story_relationship_screen.dart';
import '../screens/rp_storyline_screen.dart';
import '../screens/rp_storyline_timeline_screen.dart';
import '../screens/rp_worldbook_screen.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

enum _StoryResource { worldbook, relationships, timeline }

class RpStorylineEntry extends StatelessWidget {
  const RpStorylineEntry({super.key, required this.characterId});

  final String characterId;

  Route<void> _softRoute(BuildContext context, Widget page) {
    return CupertinoPageRoute<void>(builder: (_) => page);
  }

  Future<void> _openArchive(BuildContext context) async {
    await Navigator.of(
      context,
    ).push(_softRoute(context, RpStorylineScreen(characterId: characterId)));
  }

  Future<void> _openResource(
    BuildContext context,
    _StoryResource resource,
  ) async {
    final continuityId = await showRpStorylinePicker(
      context,
      characterId: characterId,
    );
    if (!context.mounted || continuityId == null) return;

    final rows = await DatabaseHelper.getRpStorylines(characterId);
    if (!context.mounted) return;
    final index = rows.indexWhere(
      (row) => row['id']?.toString() == continuityId,
    );
    final label = index < 0
        ? L.pick(en: 'Current storyline', zhTW: '當前故事線', zhCN: '当前故事线')
        : rpStorylineDisplayName(rows[index], index + 1);
    final page = switch (resource) {
      _StoryResource.worldbook => RpWorldbookScreen(
        characterId: characterId,
        continuityId: continuityId,
      ),
      _StoryResource.relationships => RpStoryRelationshipScreen(
        characterId: characterId,
        continuityId: continuityId,
      ),
      _StoryResource.timeline => RpStorylineTimelineScreen(
        characterId: characterId,
        continuityId: continuityId,
        storylineLabel: label,
      ),
    };
    await Navigator.of(context).push(_softRoute(context, page));
  }

  Widget _resourceLabel({required String label, required VoidCallback onTap}) {
    // This compact navigation row intentionally stops following the app font
    // slider after two steps so all three destinations remain equal-width.
    final fontSize = (12 * YanciTheme.fontScale).clamp(9.6, 14.4);
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          color: YanciTheme.accent.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            splashColor: YanciTheme.accent.withValues(alpha: 0.08),
            highlightColor: YanciTheme.accent.withValues(alpha: 0.04),
            onTap: onTap,
            child: SizedBox(
              height: 42,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      textScaler: const TextScaler.linear(1),
                      maxLines: 1,
                      style: TextStyle(
                        color: YanciTheme.textSecondary.withValues(alpha: 0.82),
                        fontSize: fontSize,
                        fontWeight: FontWeight.w500,
                        fontFamily: YanciTheme.fontFamily,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = L.pick(en: 'Story archive', zhTW: '劇情檔案', zhCN: '剧情档案');
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(YanciTheme.radiusCard),
          border: Border.all(color: YanciTheme.themedCardBorder(), width: 0.65),
        ),
        child: Column(
          children: [
            Semantics(
              button: true,
              label: label,
              child: GestureDetector(
                key: const ValueKey('rp-storyline-entry'),
                behavior: HitTestBehavior.opaque,
                onTap: () => _openArchive(context),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            style: TextStyle(
                              color: YanciTheme.accent.withValues(alpha: 0.82),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              fontFamily: YanciTheme.fontFamily,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.34,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _resourceLabel(
                  label: L.pick(en: 'Worldbook', zhTW: '世界書', zhCN: '世界书'),
                  onTap: () => _openResource(context, _StoryResource.worldbook),
                ),
                const SizedBox(width: 6),
                _resourceLabel(
                  label: L.pick(
                    en: 'Relationships',
                    zhTW: '人物關係',
                    zhCN: '人物关系',
                  ),
                  onTap: () =>
                      _openResource(context, _StoryResource.relationships),
                ),
                const SizedBox(width: 6),
                _resourceLabel(
                  label: L.pick(en: 'Timeline', zhTW: '時間線', zhCN: '时间线'),
                  onTap: () => _openResource(context, _StoryResource.timeline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
