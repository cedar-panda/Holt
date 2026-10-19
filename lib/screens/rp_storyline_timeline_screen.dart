import 'package:flutter/material.dart';

import '../models/context_mode.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/character_timeline_panel.dart';
import '../widgets/gradient_background.dart';

class RpStorylineTimelineScreen extends StatelessWidget {
  const RpStorylineTimelineScreen({
    super.key,
    required this.characterId,
    required this.continuityId,
    required this.storylineLabel,
  });

  final String characterId;
  final String continuityId;
  final String storylineLabel;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 52,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          size: 19,
                        ),
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          L.pick(en: 'Timeline', zhTW: '時間線', zhCN: '时间线'),
                          style: YanciTheme.headingMedium,
                        ),
                        Text(
                          storylineLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: YanciTheme.bodySmall.copyWith(
                            fontSize: 10.5,
                            color: YanciTheme.accent.withValues(alpha: 0.68),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(0, 24, 0, 40),
                  child: CharacterTimelinePanel(
                    characterId: characterId,
                    modeOverride: ContextMode.rp,
                    rpContinuityId: continuityId,
                    rpStorylineLabel: storylineLabel,
                    showContextModeControl: false,
                    showEconomyActions: false,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
