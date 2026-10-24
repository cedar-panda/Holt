import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../screens/rp_worldbook_screen.dart';
import '../screens/rp_storyline_screen.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class RpWorldbookEntry extends StatelessWidget {
  const RpWorldbookEntry({
    super.key,
    required this.characterId,
    this.continuityId = 'main',
  });

  final String characterId;
  final String continuityId;

  @override
  Widget build(BuildContext context) {
    final label = L.pick(en: 'Worldbook', zhTW: '世界書', zhCN: '世界书');
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          key: const ValueKey('rp-worldbook-entry'),
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            final selected = continuityId == 'main'
                ? await showRpStorylinePicker(context, characterId: characterId)
                : continuityId;
            if (!context.mounted || selected == null) return;
            await Navigator.of(context).push(
              CupertinoPageRoute<void>(
                builder: (_) => RpWorldbookScreen(
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
                      label,
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
