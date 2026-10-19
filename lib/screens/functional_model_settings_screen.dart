import 'package:flutter/material.dart';

import '../services/locale_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/gradient_background.dart';
import '../widgets/sidebar/sidebar_accordion.dart';
import '../widgets/sidebar/sidebar_model_settings.dart';

/// Focused model settings surface reached from the sidebar.
///
/// UI_SLOT: functional_model_settings_screen
class FunctionalModelSettingsScreen extends StatefulWidget {
  const FunctionalModelSettingsScreen({super.key});

  @override
  State<FunctionalModelSettingsScreen> createState() =>
      _FunctionalModelSettingsScreenState();
}

class _FunctionalModelSettingsScreenState
    extends State<FunctionalModelSettingsScreen> {
  late final SidebarAccordionCoordinator _coordinator;

  @override
  void initState() {
    super.initState();
    _coordinator = SidebarAccordionCoordinator();
  }

  @override
  void dispose() {
    _coordinator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 52,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 20,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        L.pick(
                          en: 'Other functional models',
                          zhTW: '其他功能模型設定',
                          zhCN: '其他功能模型设置',
                        ),
                        textAlign: TextAlign.center,
                        style: YanciTheme.headingMedium,
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              Expanded(
                child: SidebarAccordionScope(
                  coordinator: _coordinator,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                    physics: const BouncingScrollPhysics(),
                    children: const [SidebarModelSettings(pageMode: true)],
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
