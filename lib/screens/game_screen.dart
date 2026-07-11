import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import '../game/holt_game.dart';
import '../game/npc/game_npc_settings.dart';
import '../services/local_model_service.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

/// 像素小屋頁 —— GameWidget 宿主。
/// 生命週期紅線（審核表 A-6）：離開頁面 / app 進後台必須 pauseEngine，
/// 遊戲不跟聊天流式輸出搶幀。
class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> with WidgetsBindingObserver {
  // game 實例必須在 State 上（審核表 D：build 裡 new 會導致切頁重置）
  late final HoltGame _game = HoltGame();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _game.resumeEngine();
      // M2 TODO：resume 時重拉 ScheduleBridge 快照——時間可能跳了幾小時，
      // 角色要瞬移到正確位置，不是慢慢走過去。
    } else {
      _game.pauseEngine();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1721),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Color(0xFFEFEAF2),
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          L.pick(en: 'Pixel Home', zhTW: '像素小屋'),
          style: TextStyle(
            color: const Color(0xFFEFEAF2),
            fontSize: 16,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.settings_outlined,
              color: Color(0xFFEFEAF2),
              size: 20,
            ),
            onPressed: _openNpcSettings,
          ),
        ],
      ),
      body: GameWidget(game: _game),
    );
  }

  // ═══ 右上角齒輪：NPC AI 設定 ═══
  Future<void> _openNpcSettings() async {
    _game.pauseEngine();
    final entries = await LocalModelService.downloadedModelEntries();
    if (!mounted) return;
    var selected = await GameNpcSettings.getNpcModelId();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF2B2633),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget option({
            required String id,
            required String label,
            String? subtitle,
          }) {
            final isSelected = selected == id;
            return ListTile(
              dense: true,
              title: Text(
                label,
                style: TextStyle(
                  color: const Color(0xFFEFEAF2),
                  fontSize: 14,
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
              subtitle: subtitle == null
                  ? null
                  : Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFF948DA1),
                        fontSize: 11,
                      ),
                    ),
              trailing: isSelected
                  ? const Icon(
                      Icons.check_rounded,
                      color: Color(0xFFF2C96D),
                      size: 20,
                    )
                  : null,
              onTap: () {
                setSheet(() => selected = id);
                GameNpcSettings.setNpcModelId(id);
              },
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      L.pick(en: 'NPC settings', zhTW: 'NPC 設定'),
                      style: TextStyle(
                        color: const Color(0xFFEFEAF2),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        fontFamily: YanciTheme.fontFamily,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Text(
                      L.pick(
                        en: 'Follow your chat model, or pin a local one',
                        zhTW: '可跟隨聊天模型，或固定用某個本地小模型',
                      ),
                      style: const TextStyle(
                        color: Color(0xFF948DA1),
                        fontSize: 12,
                      ),
                    ),
                  ),
                  option(
                    id: '',
                    label: L.pick(en: 'Off', zhTW: '不啟用'),
                    subtitle: L.pick(
                      en: 'NPCs stay scripted',
                      zhTW: 'NPC 只按腳本行動',
                    ),
                  ),
                  option(
                    id: GameNpcSettings.followChat,
                    label: L.pick(
                      en: 'Follow chat model (recommended)',
                      zhTW: '跟隨聊天模型（推薦）',
                    ),
                    subtitle: L.pick(
                      en: 'Always in sync with your API settings',
                      zhTW: '與 API 設定同步，雲端/本地都行，永不搶內存',
                    ),
                  ),
                  if (entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text(
                        L.pick(
                          en: 'No local models downloaded yet',
                          zhTW: '還沒有已下載的本地模型',
                        ),
                        style: const TextStyle(
                          color: Color(0xFF948DA1),
                          fontSize: 12,
                        ),
                      ),
                    )
                  else
                    ...entries.map(
                      (e) => option(id: e['id'] ?? '', label: e['name'] ?? ''),
                    ),
                  const SizedBox(height: 4),
                  Center(
                    child: TextButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        Navigator.of(context).pushNamed('/local_models');
                      },
                      icon: const Icon(
                        Icons.download_rounded,
                        size: 16,
                        color: Color(0xFFF2C96D),
                      ),
                      label: Text(
                        L.pick(en: 'Download local models', zhTW: '去下載本地模型'),
                        style: const TextStyle(
                          color: Color(0xFFF2C96D),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    _game.resumeEngine();
  }
}
