import 'dart:async';
import 'dart:ui';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../widgets/shop_backpack_sheets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../main.dart' show themeNotifier;
import '../widgets/coin_amount_text.dart';
import '../widgets/gradient_background.dart';
import '../widgets/ambient_particles.dart';
import '../memory/database.dart';
import '../models/message.dart';
import '../models/context_mode.dart';
import '../models/background_preset.dart';
import '../services/settings_manager.dart';
import '../services/backup_service.dart';
import '../services/device_file_saver.dart';
import '../services/keep_alive_service.dart';
import '../services/manual_summary_service.dart';
import '../services/token_estimator.dart';
import '../services/character_signature_service.dart';
import '../services/anniversary_service.dart';
import '../services/background_preset_service.dart';
import '../services/background_foreground_service.dart';
import '../services/user_persona_service.dart';
import '../services/scratch_service.dart';
import '../services/sticker_service.dart';
import '../services/tool_feature_settings.dart';
import '../services/guide_service.dart';
import '../services/app_error_log_service.dart';
import '../services/settings/guide_settings.dart';
import '../widgets/orbit_loading_indicator.dart';
import '../widgets/yanci_bottom_nav_bar.dart';
import '../widgets/widow_safe_text.dart';
import '../widgets/character_signature_panel.dart';
import '../widgets/character_signature_history_sheet.dart';
import '../widgets/context_mode_pill.dart';
import '../widgets/user_persona_avatar_pair.dart';
import '../widgets/user_persona_switcher.dart';
import '../widgets/anniversary_panel.dart';
import '../services/settings/context_mode_settings.dart';
import '../utils/latest_request_gate.dart';
import 'manual_summary_clean_screen.dart';
import 'profile_screen.dart';
import 'character_list_screen.dart';
import 'sticker_library_screen.dart';
import 'user_profile_screen.dart';
import 'local_device_sync_screen.dart';
import 'external_chat_import_screen.dart';
import '../widgets/sidebar/holt_sidebar_shell.dart';
import '../widgets/sidebar/holt_control_sidebar.dart';

part 'home_screen_profile.dart';

enum _BackupExportMode { save, share }

enum _BackupSheetAction { sync, save, share, importExternal, import, cleanup }

/// 主頁 — 角色輪盤 + 水晶球 + 底部導航
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const double _homeCarouselOffsetY = 20.0;
  final GlobalKey<HoltSidebarShellState> _sidebarKey =
      GlobalKey<HoltSidebarShellState>();
  int _currentTab = 1; // 首頁居中
  List<Map<String, dynamic>> _characters = [];
  String _activeCharacterId = 'default';
  BackgroundPreset? _boundBackgroundPreset;
  BackgroundForegroundPalette? _homeForegroundPalette;
  Map<String, BackgroundPreset?> _boundBackgroundPresets =
      <String, BackgroundPreset?>{};
  BackgroundTransitionDirection _backgroundTransitionDirection =
      BackgroundTransitionDirection.rightToLeft;
  int _backgroundTransitionRevision = 0;
  int _backgroundForegroundGeneration = 0;
  Timer? _backgroundPresetRefreshTimer;
  final ValueNotifier<BackgroundSwipeTransition> _backgroundSwipeTransition =
      ValueNotifier<BackgroundSwipeTransition>(
        const BackgroundSwipeTransition(),
      );
  static const Duration _characterArrivalDuration = Duration(seconds: 1);
  static const Duration _tabBackgroundTransitionDuration = Duration(
    milliseconds: 360,
  );
  BackgroundTransitionDirection _tabBackgroundTransitionDirection =
      BackgroundTransitionDirection.rightToLeft;
  String? _latestNote;
  List<String> _randomNotes = [];
  int _randomNoteIndex = 0;

  // 角色輪盤
  PageController? _carouselController;
  int _currentCarouselPage = 0;
  int _characterCarouselRevision = 0;
  bool _suspendCharacterCarouselSelection = false;
  Timer? _onlineDwellTimer;
  bool _onlineDwellReady = false;
  bool _onlineDwellElapsed = false;

  // 心電圖動畫
  late AnimationController _ecgController;

  // 保活心跳
  int? _heartbeat;
  String? _keepAliveConvId;
  String? _keepAliveConvTitle;
  StreamSubscription<KeepAliveHeartbeat>? _heartbeatSub;

  // 用戶貝殼餘額
  int _userCoins = 0;
  bool _shellEconomyEnabled = true;
  StreamSubscription<int>? _userCoinsSub;

  static const Duration _autoBackupInterval = Duration(hours: 1);
  Timer? _autoBackupTimer;
  DateTime? _lastLocalBackupAt;
  bool _autoBackupRunning = false;
  bool _backupExportRunning = false;
  bool _namePromptOpen = false;
  bool _isStartingChat = false;
  bool _reduceMotion = false;
  bool _globalRpEnabled = false;
  bool _guideAvailable = false;
  bool _showGuideIntro = false;
  final LatestRequestGate _charactersGate = LatestRequestGate();
  final LatestRequestGate _noteGate = LatestRequestGate();
  final LatestRequestGate _coinsGate = LatestRequestGate();
  final LatestRequestGate _keepAliveGate = LatestRequestGate();
  int _characterSelectionGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ContextModeSettings.revision.addListener(_handleContextModeChanged);
    ToolFeatureSettings.state.addListener(_handleToolFeaturesChanged);
    BackgroundPresetService.revision.addListener(
      _handleBackgroundPresetsChanged,
    );
    GuideSettings.revision.addListener(_handleGuideSettingsChanged);
    _ecgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
    // 順序化啟動：先解析＋校正＋持久化 active character，再載入
    // 便箋/貝殼/保活等附屬資料——並行啟動時附屬項可能先用 default
    // 跑完把正確資料蓋掉，或失效 activeId 一直殘留在內部。
    unawaited(_reloadHomeAfterRestore());
    unawaited(_refreshGuideAvailability());
    _checkFirstTimeUser();

    // 監聽心跳流
    _heartbeatSub = KeepAliveService.instance.heartbeatStream.listen((event) {
      if (!mounted || event.characterId != _activeCharacterId) return;
      setState(() => _heartbeat = event.value);
    });

    // 用戶貝殼變更即時同步。聊天頁轉帳 / 刮刮卡結算時會推送這裡。
    _userCoinsSub = ScratchService.userCoinsChanged.listen((coins) {
      if (!mounted || !_shellEconomyEnabled) return;
      setState(() => _userCoins = coins);
    });

    _refreshLastBackupTime();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _runAutoLocalBackup(force: true);
    });
    _autoBackupTimer = Timer.periodic(
      _autoBackupInterval,
      (_) => _runAutoLocalBackup(),
    );
  }

  Future<void> _checkFirstTimeUser() async {
    final name = await UserSettings.getUserName();
    final promptCompleted = await UserSettings.getNamePromptCompleted();
    if (name.isNotEmpty && !promptCompleted) {
      await UserSettings.saveNamePromptCompleted(true);
      return;
    }
    if (name.isEmpty && !promptCompleted && mounted && !_namePromptOpen) {
      // 延遲一幀讓畫面先渲染
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_namePromptOpen) _showNamePrompt();
      });
    }
  }

  void _showNamePrompt() {
    if (_namePromptOpen) return;
    _namePromptOpen = true;
    var enteredName = '';
    showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: YanciTheme.isDark
                ? const Color(0xFF252228)
                : Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(
              L.get('first_time_title'),
              style: YanciTheme.headingMedium,
            ),
            content: TextField(
              autofocus: true,
              onChanged: (value) => enteredName = value,
              style: YanciTheme.bodyText,
              decoration: InputDecoration(
                hintText: L.get('first_time_hint'),
                hintStyle: YanciTheme.bodySmall.copyWith(
                  color: YanciTheme.textSecondary.withValues(alpha: 0.4),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, ''),
                child: Text(
                  L.get('first_time_skip'),
                  style: TextStyle(color: YanciTheme.textSecondary),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, enteredName.trim()),
                child: Text(
                  L.get('confirm_ok'),
                  style: TextStyle(color: YanciTheme.accent),
                ),
              ),
            ],
          ),
        )
        .then((name) async {
          if (name == null) return;
          if (name.isNotEmpty) {
            await UserSettings.saveUserName(name);
          }
          await UserSettings.saveNamePromptCompleted(true);
          if (mounted && name.isNotEmpty) {
            unawaited(_loadLatestNote());
          }
        })
        .whenComplete(() => _namePromptOpen = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ContextModeSettings.revision.removeListener(_handleContextModeChanged);
    ToolFeatureSettings.state.removeListener(_handleToolFeaturesChanged);
    BackgroundPresetService.revision.removeListener(
      _handleBackgroundPresetsChanged,
    );
    GuideSettings.revision.removeListener(_handleGuideSettingsChanged);
    _charactersGate.invalidate();
    _noteGate.invalidate();
    _coinsGate.invalidate();
    _keepAliveGate.invalidate();
    _autoBackupTimer?.cancel();
    _backgroundPresetRefreshTimer?.cancel();
    _heartbeatSub?.cancel();
    _userCoinsSub?.cancel();
    _onlineDwellTimer?.cancel();
    _carouselController?.removeListener(_handleCharacterCarouselMotion);
    _carouselController?.dispose();
    _backgroundSwipeTransition.dispose();
    _ecgController.dispose();
    super.dispose();
  }

  void _handleContextModeChanged() {
    if (!mounted) return;
    unawaited(_loadCharacters(selectId: _activeCharacterId));
    unawaited(_loadLatestNote(characterId: _activeCharacterId));
    unawaited(_loadPersonaShelf(syncFromActiveCharacter: true));
  }

  void _handleBackgroundPresetsChanged() {
    if (!mounted || _characters.isEmpty) return;
    _backgroundPresetRefreshTimer?.cancel();
    _backgroundPresetRefreshTimer = Timer(
      const Duration(milliseconds: 90),
      () => unawaited(_reloadBoundBackgroundPresets()),
    );
  }

  void _handleGuideSettingsChanged() {
    if (mounted) unawaited(_refreshGuideAvailability());
  }

  Future<void> _reloadBoundBackgroundPresets() async {
    final ids = _characters
        .map((character) => character['id'] as String)
        .toList(growable: false);
    final entries = await Future.wait<MapEntry<String, BackgroundPreset?>>(
      ids.map((id) async {
        return MapEntry(
          id,
          await BackgroundPresetService.boundPresetForCharacter(id),
        );
      }),
    );
    if (!mounted) return;
    final presets = Map<String, BackgroundPreset?>.fromEntries(entries);
    final current = presets[_activeCharacterId];
    setState(() {
      _boundBackgroundPresets = presets;
      _boundBackgroundPreset = current;
      _homeForegroundPalette = BackgroundForegroundService.cached(
        current?.homePath ?? '',
      );
    });
    _publishBackgroundSwipeTransition(page: _currentCarouselPage.toDouble());
    unawaited(_loadHomeForegroundPalette(current));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion == reduceMotion) return;
    _reduceMotion = reduceMotion;
    _syncHomeAnimations();
  }

  void _syncHomeAnimations() {
    // The ECG only exists on the home tab. IndexedStack keeps sibling tabs
    // alive, so checking merely "not profile" left this ticker running behind
    // the character page.
    final shouldAnimate = mounted && !_reduceMotion && _currentTab == 1;
    if (shouldAnimate) {
      if (!_ecgController.isAnimating) _ecgController.repeat();
    } else {
      _ecgController.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _ecgController.stop();
      _runAutoLocalBackup(force: true);
    } else if (state == AppLifecycleState.resumed) {
      _syncHomeAnimations();
      _refreshLastBackupTime();
      unawaited(_refreshGuideAvailability());
    }
  }

  Future<void> _refreshGuideAvailability() async {
    final enabled = await GuideSettings.isEnabled();
    final hasApi = enabled && await GuideService.hasAnyApiConfiguration();
    final introSeen = hasApi && await GuideSettings.hasSeenIntro();
    if (!mounted) return;
    setState(() {
      _guideAvailable = hasApi;
      _showGuideIntro = hasApi && !introSeen;
    });
  }

  Future<void> _openGuide() async {
    await Navigator.of(context).pushNamed('/guide');
    if (mounted) unawaited(_refreshGuideAvailability());
  }

  Future<void> _refreshLastBackupTime() async {
    final last = await BackupService.getLastBackupTime();
    if (!mounted) return;
    setState(() => _lastLocalBackupAt = last);
  }

  Future<void> _runAutoLocalBackup({bool force = false}) async {
    if (_autoBackupRunning) return;
    _autoBackupRunning = true;
    try {
      final last = await BackupService.getLastBackupTime();
      if (!force &&
          last != null &&
          DateTime.now().difference(last) < _autoBackupInterval) {
        if (mounted) setState(() => _lastLocalBackupAt = last);
        return;
      }

      await BackupService.saveLocalBackup();
      final savedAt = await BackupService.getLastBackupTime();
      if (!mounted) return;
      setState(() => _lastLocalBackupAt = savedAt ?? DateTime.now());
    } catch (e) {
      debugPrint('Auto local backup failed: $e');
    } finally {
      _autoBackupRunning = false;
    }
  }

  Future<void> _loadKeepAliveInfo({String? characterId}) async {
    final charId = characterId ?? _activeCharacterId;
    final generation = _keepAliveGate.begin();
    var convId = await KeepAliveService.getActiveConvId(characterId: charId);
    var title = await KeepAliveService.getActiveConvTitle(characterId: charId);
    // Exiting a newly-created empty window disposes the chat before its async
    // database cleanup has necessarily finished. Never surface that transient
    // window as the home-screen quick entry.
    if (convId != null && await DatabaseHelper.getMessageCount(convId) == 0) {
      convId = null;
      title = null;
    }
    final hb = await KeepAliveService.getLastHeartbeat(characterId: charId);
    if (mounted &&
        charId == _activeCharacterId &&
        _keepAliveGate.isCurrent(generation)) {
      setState(() {
        _keepAliveConvId = convId;
        _keepAliveConvTitle = title;
        _heartbeat = hb;
      });
    }
  }

  Future<void> _loadUserCoins() async {
    final generation = _coinsGate.begin();
    final features = await ToolFeatureSettings.load();
    if (!features.shellEconomyEnabled) {
      if (mounted && _coinsGate.isCurrent(generation)) {
        setState(() {
          _shellEconomyEnabled = false;
          _userCoins = 0;
        });
      }
      return;
    }
    final coins = await ScratchService.getUserCoins();
    if (mounted && _coinsGate.isCurrent(generation)) {
      setState(() {
        _shellEconomyEnabled = true;
        _userCoins = coins;
      });
    }
  }

  void _handleToolFeaturesChanged() {
    final features = ToolFeatureSettings.state.value;
    final enabled = features.shellEconomyEnabled;
    if (!mounted) return;
    setState(() {
      _shellEconomyEnabled = enabled;
    });
    if (enabled) unawaited(_loadUserCoins());
  }

  Future<void> _refreshAfterChatReturn() async {
    await _loadKeepAliveInfo(characterId: _activeCharacterId);
    await _loadUserCoins();
    await CharacterSignatureService.waitForPending(_activeCharacterId);
    final refreshed = await DatabaseHelper.getCharacter(_activeCharacterId);
    if (!mounted || refreshed == null) return;
    final index = _characters.indexWhere(
      (character) => character['id'] == _activeCharacterId,
    );
    if (index < 0) return;
    setState(() {
      final next = List<Map<String, dynamic>>.from(_characters);
      next[index] = refreshed;
      _characters = next;
    });
  }

  Future<T?> _pushChatRoute<T>({
    required Object arguments,
    String? restoreCharacterId,
  }) async {
    final expectedCharacterId = restoreCharacterId ?? _activeCharacterId;
    _suspendCharacterCarouselSelection = true;
    try {
      return await Navigator.of(
        context,
      ).pushNamed<T>('/chat', arguments: arguments);
    } finally {
      _suspendCharacterCarouselSelection = false;
      if (mounted) {
        await _restoreCharacterAfterChat(expectedCharacterId);
      }
    }
  }

  Future<void> _restoreCharacterAfterChat(String characterId) async {
    final targetIndex = _characters.indexWhere(
      (character) => character['id'] == characterId,
    );
    if (targetIndex < 0) return;

    if (_activeCharacterId != characterId) {
      await _selectCharacter(characterId);
    }
    if (!mounted) return;

    _currentCarouselPage = targetIndex;
    final controller = _carouselController;
    if (controller != null && controller.hasClients) {
      controller.jumpToPage(targetIndex);
    }
  }

  String _userName = '';
  List<UserPersona> _userPersonas = const <UserPersona>[];
  UserPersona? _selectedUserPersona;
  Map<String, dynamic>? _selectedPersonaCompanion;
  String? _anniversaryCharacterId;
  int _personaShelfGeneration = 0;
  int _personaSelectionGeneration = 0;
  String? _requestedPersonaId;
  bool _userPersonaCreateSlotSelected = false;
  List<AnniversaryEntry> _anniversaries = const <AnniversaryEntry>[];
  AnniversaryDisplaySettings _anniversaryDisplaySettings =
      const AnniversaryDisplaySettings();

  List<AnniversaryEntry> _anniversariesAt(AnniversaryPlacement placement) {
    return _anniversaries
        .where((entry) => entry.placement == placement)
        .toList(growable: false);
  }

  void _setUserPersonaCreateSlot(bool selected) {
    if (!mounted || _userPersonaCreateSlotSelected == selected) return;
    setState(() => _userPersonaCreateSlotSelected = selected);
  }

  Future<void> _loadPersonaShelf({bool syncFromActiveCharacter = false}) async {
    final generation = ++_personaShelfGeneration;
    final charId = _activeCharacterId;
    final mode = await ContextModeSettings.effectiveMode(charId);
    if (syncFromActiveCharacter) {
      final boundId = await UserPersonaService.boundPersonaId(
        characterId: charId,
        contextMode: mode,
      );
      if (boundId != null) await UserPersonaService.selectPersona(boundId);
    }
    final basePersonas = await UserPersonaService.listPersonas();
    final personas = await Future.wait(
      basePersonas.map(
        (persona) async =>
            await UserPersonaService.personaForMode(persona.id, mode) ??
            persona,
      ),
    );
    final selectedBase = await UserPersonaService.selectedPersona();
    final selected =
        await UserPersonaService.personaForMode(selectedBase.id, mode) ??
        selectedBase;
    final companionId = await UserPersonaService.companionIdForPersona(
      personaId: selected.id,
      contextMode: mode,
    );
    final companion = companionId == null
        ? null
        : await DatabaseHelper.getCharacter(companionId);
    // Anniversary controls describe the two avatars currently shown on the
    // profile page. When the selected persona is bound to another character,
    // keep using that visible pair even if the user just chatted with an
    // unbound character.
    final anniversaryCharacterId = companionId ?? charId;
    final anniversaryResults = await Future.wait<Object>([
      AnniversaryService.list(
        userPersonaId: selected.id,
        characterId: anniversaryCharacterId,
      ),
      AnniversaryService.settings(
        userPersonaId: selected.id,
        characterId: anniversaryCharacterId,
      ),
    ]);
    if (!mounted ||
        charId != _activeCharacterId ||
        generation != _personaShelfGeneration) {
      return;
    }
    setState(() {
      _userPersonas = personas;
      _selectedUserPersona = selected;
      _selectedPersonaCompanion = companion;
      _anniversaryCharacterId = anniversaryCharacterId;
      _userPersonaCreateSlotSelected = false;
      _anniversaries = anniversaryResults[0] as List<AnniversaryEntry>;
      _anniversaryDisplaySettings =
          anniversaryResults[1] as AnniversaryDisplaySettings;
    });
  }

  Future<void> _selectUserPersona(UserPersona persona) async {
    final generation = ++_personaSelectionGeneration;
    _requestedPersonaId = persona.id;
    await UserPersonaService.selectPersona(persona.id);
    if (generation != _personaSelectionGeneration) {
      final latestId = _requestedPersonaId;
      if (latestId != null) await UserPersonaService.selectPersona(latestId);
      return;
    }
    final mode = await ContextModeSettings.effectiveMode(_activeCharacterId);
    if (generation != _personaSelectionGeneration) return;
    final companionId = await UserPersonaService.companionIdForPersona(
      personaId: persona.id,
      contextMode: mode,
    );
    if (generation != _personaSelectionGeneration) return;
    if (companionId != null && companionId != _activeCharacterId) {
      await _selectCharacter(companionId, syncPersonaFromCharacter: false);
    }
    if (generation != _personaSelectionGeneration) return;
    await _loadPersonaShelf();
  }

  Future<void> _loadLatestNote({String? characterId}) async {
    final charId = characterId ?? _activeCharacterId;
    final generation = _noteGate.begin();
    final note = await DatabaseHelper.getLatestNote(characterId: charId);
    final randoms = await DatabaseHelper.getRandomNotes(charId, count: 10);
    final mode = await ContextModeSettings.effectiveMode(charId);
    final resolvedPersona = await UserPersonaService.resolveForNewWindow(
      characterId: charId,
      contextMode: mode,
    );
    final name = resolvedPersona.persona.displayName;
    if (!mounted ||
        charId != _activeCharacterId ||
        !_noteGate.isCurrent(generation)) {
      return;
    }
    setState(() {
      _latestNote = note?['content'] as String?;
      _randomNotes = randoms.map((r) => r['content'] as String).toList();
      _randomNoteIndex = 0;
      _userName = name;
    });
  }

  Future<void> _loadCharacters({String? selectId}) async {
    final generation = _charactersGate.begin();
    final results = await Future.wait<Object>([
      DatabaseHelper.getCharacters(),
      ContextModeSettings.getGlobalRpEnabled(),
      ToolFeatureSettings.load(),
    ]);
    final chars = results[0] as List<Map<String, dynamic>>;
    final globalRp = results[1] as bool;
    final toolFeatures = results[2] as ToolFeatureState;
    final requestedActiveId =
        selectId ?? await UserSettings.getActiveCharacterId();
    final backgroundEntries =
        await Future.wait<MapEntry<String, BackgroundPreset?>>(
          chars.map((character) async {
            final id = character['id'] as String;
            return MapEntry(
              id,
              await BackgroundPresetService.boundPresetForCharacter(id),
            );
          }),
        );
    final boundBackgrounds = Map<String, BackgroundPreset?>.fromEntries(
      backgroundEntries,
    );
    final requestedIndex = chars.indexWhere(
      (character) => character['id'] == requestedActiveId,
    );
    final activeIndex = requestedIndex >= 0 ? requestedIndex : 0;
    final activeId = chars.isEmpty
        ? 'default'
        : chars[activeIndex]['id'] as String;
    final boundBackground = boundBackgrounds[activeId];

    if (!mounted || !_charactersGate.isCurrent(generation)) return;
    // Invalidate callbacks from the outgoing PageView before replacing the
    // list. A newly-created character sorts to index 0; without this guard an
    // old page index can be interpreted against the new list and select it.
    _characterCarouselRevision++;
    _carouselController?.removeListener(_handleCharacterCarouselMotion);
    _carouselController?.dispose();
    _carouselController = PageController(
      viewportFraction: 0.72,
      initialPage: activeIndex,
    )..addListener(_handleCharacterCarouselMotion);
    _currentCarouselPage = activeIndex;

    setState(() {
      _characters = chars;
      _activeCharacterId = activeId;
      _boundBackgroundPreset = boundBackground;
      _homeForegroundPalette = BackgroundForegroundService.cached(
        boundBackground?.homePath ?? '',
      );
      _boundBackgroundPresets = boundBackgrounds;
      _globalRpEnabled = globalRp;
      _shellEconomyEnabled = toolFeatures.shellEconomyEnabled;
    });
    if (activeId != requestedActiveId) {
      unawaited(UserSettings.saveActiveCharacterId(activeId));
    }
    _publishBackgroundSwipeTransition(page: activeIndex.toDouble());
    unawaited(_loadHomeForegroundPalette(boundBackground));
    _beginOnlineDwell(activeId);
    unawaited(_loadKeepAliveInfo(characterId: activeId));

    // TODO: 每日自動發放貝殼 — 遊戲上線後刪除
    if (toolFeatures.shellEconomyEnabled) {
      final charIds = chars.map((c) => c['id'] as String).toList();
      ScratchService.checkDailyGrant(characterIds: charIds).then((_) {
        if (mounted && _charactersGate.isCurrent(generation)) {
          _loadUserCoins();
        }
      });
    }
  }

  Future<void> _showSignatureHistoryFor(String characterId) async {
    final selected = await showCharacterSignatureHistory(context, characterId);
    if (!mounted || selected == null) return;
    final index = _characters.indexWhere((row) => row['id'] == characterId);
    if (index < 0) return;
    setState(() {
      _characters[index] = <String, dynamic>{
        ..._characters[index],
        'signature': selected,
      };
    });
  }

  /// 首頁完整（重）載：先校正 active character（失效→退第一個並持久化），
  /// 再依資料庫／偏好順序載入所有附屬狀態。
  /// 兩個入口共用：initState 啟動、備份覆蓋還原後。
  Future<void> _reloadHomeAfterRestore() async {
    final chars = await DatabaseHelper.getCharacters();
    var activeId = await UserSettings.getActiveCharacterId();
    final activeStillExists = chars.any((row) => row['id'] == activeId);
    if (!activeStillExists) {
      activeId = chars.isEmpty ? 'default' : chars.first['id'].toString();
      await UserSettings.saveActiveCharacterId(activeId);
    }

    await _loadCharacters(selectId: activeId);
    await Future.wait([
      _loadLatestNote(),
      _loadPersonaShelf(syncFromActiveCharacter: true),
      _loadUserCoins(),
      _loadKeepAliveInfo(characterId: activeId),
      _refreshLastBackupTime(),
    ]);
  }

  Future<void> _selectCharacter(
    String id, {
    bool syncPersonaFromCharacter = true,
  }) async {
    if (id == _activeCharacterId && _characters.isNotEmpty) return;
    final generation = ++_characterSelectionGeneration;
    _charactersGate.invalidate();
    final previousIndex = _characters.indexWhere(
      (character) => character['id'] == _activeCharacterId,
    );
    final nextIndex = _characters.indexWhere(
      (character) => character['id'] == id,
    );
    final transitionDirection = previousIndex >= 0 && nextIndex < previousIndex
        ? BackgroundTransitionDirection.leftToRight
        : BackgroundTransitionDirection.rightToLeft;

    // UI selection must change before any persistence or database await.
    if (mounted) {
      setState(() {
        _activeCharacterId = id;
        _boundBackgroundPreset = _boundBackgroundPresets[id];
        _homeForegroundPalette = BackgroundForegroundService.cached(
          _boundBackgroundPreset?.homePath ?? '',
        );
        _backgroundTransitionDirection = transitionDirection;
        _backgroundTransitionRevision++;
        _onlineDwellReady = false;
        _latestNote = null;
        _randomNotes = const [];
        _heartbeat = null;
        _keepAliveConvId = null;
        _keepAliveConvTitle = null;
      });
    }
    unawaited(_loadHomeForegroundPalette(_boundBackgroundPresets[id]));
    _beginOnlineDwell(id);
    _noteGate.invalidate();
    _keepAliveGate.invalidate();

    unawaited(_loadLatestNote(characterId: id));
    unawaited(
      _loadPersonaShelf(syncFromActiveCharacter: syncPersonaFromCharacter),
    );
    unawaited(_loadKeepAliveInfo(characterId: id));
    await UserSettings.saveActiveCharacterId(id);
    if (generation != _characterSelectionGeneration) {
      // A slower, older write may have landed last. Reassert the current choice.
      await UserSettings.saveActiveCharacterId(_activeCharacterId);
      return;
    }

    final char = await DatabaseHelper.getCharacter(id);
    if (generation != _characterSelectionGeneration) return;
    if (char != null && id == _activeCharacterId) {
      await UserSettings.saveCharacterName(char['name'] ?? '');
    }

    if (!mounted ||
        generation != _characterSelectionGeneration ||
        id != _activeCharacterId) {
      return;
    }

    // 讓輪盤滾到選中的角色
    final targetIndex = _characters.indexWhere((c) => c['id'] == id);
    if (targetIndex >= 0 &&
        _carouselController != null &&
        _carouselController!.hasClients &&
        _currentCarouselPage != targetIndex) {
      _carouselController!.animateToPage(
        targetIndex,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _beginOnlineDwell(String characterId) {
    _onlineDwellTimer?.cancel();
    if (!mounted) return;
    _onlineDwellElapsed = false;
    if (_onlineDwellReady) setState(() => _onlineDwellReady = false);
    _publishBackgroundSwipeTransition();
    _onlineDwellTimer = Timer(_characterArrivalDuration, () {
      if (!mounted || _activeCharacterId != characterId) return;
      _onlineDwellElapsed = true;
      _refreshOnlineDwellReady();
    });
  }

  void _handleCharacterCarouselMotion() {
    _publishBackgroundSwipeTransition();
    _refreshOnlineDwellReady();
  }

  void _refreshOnlineDwellReady() {
    if (!mounted) return;
    final controller = _carouselController;
    final activeIndex = _characters.indexWhere(
      (character) => character['id'] == _activeCharacterId,
    );
    final page = controller != null && controller.hasClients
        ? controller.page
        : activeIndex.toDouble();
    final settled =
        activeIndex >= 0 && page != null && (page - activeIndex).abs() < 0.002;
    final nextReady = _onlineDwellElapsed && settled;
    if (nextReady == _onlineDwellReady) return;
    setState(() => _onlineDwellReady = nextReady);
    _publishBackgroundSwipeTransition(page: page);
  }

  void _publishBackgroundSwipeTransition({double? page}) {
    if (_characters.isEmpty) {
      _backgroundSwipeTransition.value = BackgroundSwipeTransition(
        leftPreset: _boundBackgroundPreset,
        rightPreset: _boundBackgroundPreset,
        onlineReady: _onlineDwellReady,
      );
      return;
    }
    final controller = _carouselController;
    final rawPage =
        page ??
        (controller != null && controller.hasClients
            ? controller.page
            : _currentCarouselPage.toDouble()) ??
        _currentCarouselPage.toDouble();
    final boundedPage = rawPage.clamp(0.0, _characters.length - 1.0);
    final leftIndex = boundedPage.floor();
    final rightIndex = boundedPage.ceil();
    final leftId = _characters[leftIndex]['id'] as String;
    final rightId = _characters[rightIndex]['id'] as String;
    _backgroundSwipeTransition.value = BackgroundSwipeTransition(
      leftPreset: _boundBackgroundPresets[leftId],
      rightPreset: _boundBackgroundPresets[rightId],
      progress: rightIndex == leftIndex ? 0 : boundedPage - leftIndex,
      onlineReady: _onlineDwellReady,
    );
  }

  Future<void> _loadHomeForegroundPalette(BackgroundPreset? preset) async {
    final generation = ++_backgroundForegroundGeneration;
    final path = preset?.homePath.trim() ?? '';
    final palette = await BackgroundForegroundService.resolve(path);
    if (!mounted || generation != _backgroundForegroundGeneration) return;
    if ((_boundBackgroundPreset?.homePath.trim() ?? '') != path) return;
    setState(() => _homeForegroundPalette = palette);
  }

  Future<void> _startNewChat() async {
    if (_isStartingChat) return;
    if (_characters.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(L.get('char_create_hint'))));
      return;
    }

    _isStartingChat = true;
    try {
      // 防禦：active ID 可能因競態殘留 'default'，校正為實際角色
      var charId = _activeCharacterId;
      if (!_characters.any((c) => c['id'] == charId)) {
        charId = _characters.first['id'] as String;
        _activeCharacterId = charId;
        unawaited(UserSettings.saveActiveCharacterId(charId));
      }

      final convId = const Uuid().v4();
      final mode = await ContextModeSettings.effectiveMode(charId);
      if (!mounted) return;
      var continuityId = 'main';
      if (mode == ContextMode.rp) {
        await DatabaseHelper.ensureDefaultRpStoryline(charId);
        final storylines = await DatabaseHelper.getRpStorylines(charId);
        if (storylines.isEmpty) return;
        var selected = storylines.first;
        for (final storyline in storylines) {
          if (storyline['is_default'] == 1) {
            selected = storyline;
            break;
          }
        }
        continuityId = selected['id']?.toString() ?? 'main';
      }
      final resolvedPersona = await UserPersonaService.resolveForNewWindow(
        characterId: charId,
        contextMode: mode,
        continuityId: continuityId,
      );
      final conv = Conversation(
        id: convId,
        characterId: charId,
        contextMode: mode,
        continuityId: continuityId,
        userPersonaId: resolvedPersona.persona.id,
        userPersonaSnapshot: resolvedPersona.promptSnapshot,
      );
      await DatabaseHelper.createConversation(conv);

      if (mounted) {
        await _pushChatRoute(arguments: convId, restoreCharacterId: charId);
        if (await DatabaseHelper.getMessageCount(convId) == 0) {
          if (KeepAliveService.instance.activeConversationId == convId) {
            await KeepAliveService.instance.stop();
          }
          await DatabaseHelper.deleteConversation(convId);
        }
        // 從聊天頁返回 → 刷新保活狀態 + 貝殼餘額
        await _refreshAfterChatReturn();
      }
    } catch (e) {
      debugPrint('_startNewChat failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              L.pick(en: 'Could not open chat: $e', zhTW: '無法開啟對話：$e'),
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      _isStartingChat = false;
    }
  }

  Future<void> _toggleProfileThemeMode() async {
    final nextPreset = YanciTheme.isDark
        ? await ThemeSettings.getLastLightPreset()
        : await ThemeSettings.getLastDarkPreset();

    if (!mounted) return;
    await ThemeSettings.restoreThemeBubbleColors(nextPreset);
    if (!mounted) return;
    YanciTheme.setPreset(nextPreset);
    setState(() {});
    themeNotifier.value++;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: YanciTheme.isDark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: YanciTheme.isDark
            ? Brightness.light
            : Brightness.dark,
      ),
    );
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    await ThemeSettings.saveThemePreset(nextPreset);
  }

  Future<void> _refreshProfileTheme() async {
    final preset = await BackgroundPresetService.boundPresetForCharacter(
      _activeCharacterId,
    );
    if (!mounted) return;
    setState(() {
      _boundBackgroundPreset = preset;
      _boundBackgroundPresets[_activeCharacterId] = preset;
      _homeForegroundPalette = BackgroundForegroundService.cached(
        preset?.homePath ?? '',
      );
    });
    await _loadHomeForegroundPalette(preset);
  }

  @override
  Widget build(BuildContext context) {
    return HoltSidebarShell(
      key: _sidebarKey,
      sidebar: HoltControlSidebar(
        guideVisible: _guideAvailable,
        shellEconomyVisible: _shellEconomyEnabled,
        shellBalance: _userCoins,
        onGuideTap: () {
          if (_showGuideIntro) {
            unawaited(GuideSettings.markIntroSeen());
            setState(() => _showGuideIntro = false);
          }
          unawaited(_openGuide());
        },
        onShopTap: () => unawaited(_showShopBottomSheet(context)),
        onBackpackTap: () =>
            unawaited(_showBackpackBottomSheet(context, 'user')),
      ),
      background: GradientBackground(
        // 背景來源始終是首頁目前交流角色；角色頁只把綁定圖片柔和
        // 淡出至主題底色，不讓角色卡輪盤的瀏覽位置改變背景來源。
        scope: YanciBackgroundScope.home,
        presetOverride: _boundBackgroundPreset,
        transitionDirection: _backgroundTransitionDirection,
        transitionRevision: _backgroundTransitionRevision,
        transitionDuration: _characterArrivalDuration,
        customBackgroundTransitionDuration: _tabBackgroundTransitionDuration,
        customBackgroundTransitionDirection: _tabBackgroundTransitionDirection,
        customBackgroundOpacity: _currentTab == 0 ? 0 : 1,
        swipeTransition: _backgroundSwipeTransition,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: 88,
              child: TickerMode(
                enabled: YanciTheme.starEnabled && !_reduceMotion,
                child: Offstage(
                  offstage: !YanciTheme.starEnabled,
                  child: const RepaintBoundary(child: AmbientParticleField()),
                ),
              ),
            ),
          ],
        ),
      ),
      child: Scaffold(
        extendBody: true,
        backgroundColor: Colors.transparent,
        body: SafeArea(child: _buildCurrentPage()),
        bottomNavigationBar: YanciBottomNavBar(
          activeIndex: _currentTab,
          reduceMotion: _reduceMotion,
          backgroundPalette: _currentTab == 0 ? null : _homeForegroundPalette,
          onTap: _handleNavTap,
        ),
      ),
    );
  }

  Widget _buildCurrentPage() {
    // 三個底部導航頁保持同層且持續存活；角色頁不再 push 新 route，
    // 因此底部導航和外層側邊欄手勢都不會消失。
    return IndexedStack(
      index: _currentTab,
      children: [
        TickerMode(
          enabled: _currentTab == 0,
          child: CharacterListScreen(
            embedded: true,
            activeCharacterId: _activeCharacterId,
            onActiveCharacterChanged: (id) =>
                unawaited(_loadCharacters(selectId: id)),
          ),
        ),
        TickerMode(enabled: _currentTab == 1, child: _buildHomePage()),
        TickerMode(enabled: _currentTab == 2, child: _buildProfilePage()),
      ],
    );
  }

  // ═══════════════════════════════════
  // 主頁
  // ═══════════════════════════════════

  Widget _buildHomePage() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        // 扣除底部導航欄（extendBody: true 所以 h 包含被遮住的部分）
        const navBarH = 66.0;
        final visibleH = h - navBarH;
        // 輪盤以畫面上 1/3 線為基準，再整組下移。
        // 輪盤內容含四行簽名與卡片下方的在線提示；高度與輪盤 widget 一致，
        // 避免提示文字在 Positioned 內被擠出底部。
        final carouselH = Theme.of(context).platform == TargetPlatform.iOS
            ? 136.0
            : 156.0;
        final carouselCenterY = visibleH / 3;
        final baseCarouselTop = max(0.0, carouselCenterY - carouselH / 2);
        final carouselTop = baseCarouselTop + _homeCarouselOffsetY;
        // 問候語在頂部（≈50 給貝殼/歷史行）與輪盤之間的正中心
        const topReserved = 50.0;
        final canShowGreeting = baseCarouselTop - 10 >= topReserved;
        final greetingCenterY = (topReserved + baseCarouselTop) / 2;
        // 小螢幕沒有足夠間距時直接隱藏問候語，不對無效區間 clamp。
        final greetingTop = canShowGreeting
            ? (greetingCenterY - 20).clamp(topReserved, baseCarouselTop - 10)
            : 0.0;

        return Stack(
          children: [
            // ═══ 問候文本 ═══
            if (canShowGreeting)
              Positioned(
                top: greetingTop,
                left: 0,
                right: 0,
                child: KeyedSubtree(
                  key: ValueKey('home-greeting-$_activeCharacterId'),
                  child: _buildGreeting(),
                ),
              ),
            // ═══ 角色輪盤 ═══
            Positioned(
              top: carouselTop,
              left: 0,
              right: 0,
              height: carouselH,
              child: _buildCharacterCarousel(),
            ),
            // ═══ 心跳 + 心電圖 + 正在聊 ═══
            Positioned(
              top: carouselTop + carouselH,
              left: 0,
              right: 0,
              bottom: 28,
              child: KeyedSubtree(
                key: ValueKey('home-live-state-$_activeCharacterId'),
                child: Column(
                  children: [
                    if (_anniversariesAt(
                      AnniversaryPlacement.aboveHeartbeat,
                    ).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 2),
                        child: AnniversaryDayCounterGroup(
                          entries: _anniversariesAt(
                            AnniversaryPlacement.aboveHeartbeat,
                          ),
                        ),
                      ),
                    if (_heartbeat != null) _buildHeartbeatValue(),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Semantics(
                        button: true,
                        label: L.pick(en: 'Start a new chat', zhTW: '開始新對話'),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _startNewChat,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              _buildHeartbeatLine(),
                              _buildPulsingDot(),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_keepAliveConvId != null) _buildActiveConvEntry(),
                  ],
                ),
              ),
            ),
            // ═══ 側邊欄入口與貝殼餘額（左上角）═══
            Positioned(
              top: 12,
              left: 12,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: L.pick(
                      en: 'Open settings',
                      zhTW: '打開設定',
                      zhCN: '打开设置',
                    ),
                    child: IconButton(
                      onPressed: () => _sidebarKey.currentState?.open(),
                      icon: Icon(
                        Icons.menu_rounded,
                        size: 23,
                        color:
                            _homeForegroundPalette?.primary ??
                            YanciTheme.textSecondary.withValues(alpha: 0.68),
                      ),
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                    ),
                  ),
                  if (_shellEconomyEnabled) ...[
                    const SizedBox(width: 2),
                    Tooltip(
                      message: L.pick(
                        en: 'Open Shell Shop',
                        zhTW: '點擊餘額進入貝殼商店',
                        zhCN: '点击余额进入贝壳商店',
                      ),
                      child: Semantics(
                        button: true,
                        label: L.pick(
                          en: 'Shell balance $_userCoins; open shop',
                          zhTW: '貝殼餘額 $_userCoins；進入商店',
                          zhCN: '贝壳余额 $_userCoins；进入商店',
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => unawaited(_showShopBottomSheet(context)),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 44),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Image.asset(
                                    'assets/images/shell_coin.png',
                                    width: 20,
                                    height: 20,
                                    filterQuality: FilterQuality.none,
                                  ),
                                  const SizedBox(width: 6),
                                  CoinAmountText(_userCoins),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // ═══ 歷史對話按鈕（右上角）═══
            Positioned(
              top: 12,
              right: 20,
              child: Tooltip(
                message: L.pick(en: 'Chat history', zhTW: '歷史對話'),
                child: Semantics(
                  button: true,
                  label: L.pick(en: 'Chat history', zhTW: '歷史對話'),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _showConversationList,
                    child: SizedBox.square(
                      dimension: 48,
                      child: Center(
                        child: Icon(
                          Icons.history_rounded,
                          size: 22,
                          color:
                              _homeForegroundPalette?.primary ??
                              YanciTheme.textSecondary.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildGreeting() {
    final imagePrimary = _homeForegroundPalette?.primary;
    // 優先顯示 AI 便箋
    String? noteToShow;
    if (_latestNote != null && _latestNote!.isNotEmpty) {
      noteToShow = _latestNote;
    } else if (_randomNotes.isNotEmpty) {
      noteToShow = _randomNotes[_randomNoteIndex % _randomNotes.length];
    }

    if (noteToShow != null) {
      final notePreview = noteToShow.replaceAll(RegExp(r'\s+'), ' ').trim();
      return Semantics(
        button: true,
        label: L.pick(en: 'Open notes', zhTW: '開啟便箋'),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _showNotesSheet,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: WidowSafeText(
              '「$notePreview」',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w300,
                color:
                    imagePrimary ??
                    YanciTheme.textPrimary.withValues(alpha: 0.8),
                fontFamily: YanciTheme.fontFamily,
                letterSpacing: 1.5,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              balanceLines: true,
            ),
          ),
        ),
      );
    }

    // 沒有便箋，回退到時間段問候
    final hour = DateTime.now().hour;
    String greeting;
    if (hour < 6) {
      greeting = L.get('greeting_night');
    } else if (hour < 12) {
      greeting = L.get('greeting_morning');
    } else if (hour < 18) {
      greeting = L.get('greeting_afternoon');
    } else {
      greeting = L.get('greeting_evening');
    }

    if (_userName.isNotEmpty) {
      greeting = '$greeting，$_userName';
    }

    return Semantics(
      button: true,
      label: L.pick(en: 'Open notes', zhTW: '開啟便箋'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _showNotesSheet,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: WidowSafeText(
            greeting,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w300,
              color:
                  imagePrimary ?? YanciTheme.textPrimary.withValues(alpha: 0.7),
              fontFamily: YanciTheme.fontFamily,
              letterSpacing: 1.5,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            balanceLines: true,
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════
  // 角色輪盤（卡片式撥動切換 + 居中放大 + 兩側漸小漸淡）
  // ═══════════════════════════════════

  Widget _buildCharacterCarousel() {
    final isIos = Theme.of(context).platform == TargetPlatform.iOS;
    if (_characters.isEmpty || _carouselController == null) {
      return SizedBox(
        height: 120,
        child: Center(
          child: GestureDetector(
            onTap: () async {
              final newId = await Navigator.of(context).pushNamed('/character');
              if (newId != null && mounted) {
                await _loadCharacters(selectId: newId as String);
                _selectCharacter(newId);
              }
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.auto_awesome,
                  size: 20,
                  color: YanciTheme.accent.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 8),
                Text(
                  L.get('char_create_hint'),
                  style: YanciTheme.bodySmall.copyWith(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final carouselWidth = min(MediaQuery.sizeOf(context).width - 28, 380.0);
    final canGoPrevious = _currentCarouselPage > 0;
    final canGoNext = _currentCarouselPage < _characters.length - 1;
    final carouselRevision = _characterCarouselRevision;

    void moveCarouselTo(int index) {
      final controller = _carouselController;
      if (controller == null || !controller.hasClients) return;
      controller.animateToPage(
        index,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }

    return SizedBox(
      height: isIos ? 136 : 156,
      child: Stack(
        children: [
          Center(
            child: SizedBox(
              width: carouselWidth,
              child: PageView.builder(
                key: ValueKey('home-character-carousel-$carouselRevision'),
                controller: _carouselController!,
                itemCount: _characters.length,
                onPageChanged: (index) {
                  if (_suspendCharacterCarouselSelection ||
                      carouselRevision != _characterCarouselRevision ||
                      index < 0 ||
                      index >= _characters.length) {
                    return;
                  }
                  _currentCarouselPage = index;
                  final id = _characters[index]['id'] as String;
                  unawaited(_selectCharacter(id));
                },
                itemBuilder: (context, index) {
                  return AnimatedBuilder(
                    animation: _carouselController!,
                    builder: (context, child) {
                      double page;
                      try {
                        page =
                            _carouselController!.page ??
                            _currentCarouselPage.toDouble();
                      } catch (_) {
                        page = _currentCarouselPage.toDouble();
                      }

                      final diff = (page - index).abs();
                      final scale = (1.0 - diff * 0.12).clamp(0.84, 1.0);
                      final isCenter = diff < 0.5;
                      // 靜止時只保留選中的角色可見；拖動開始後再讓鄰近卡片
                      // 依位移漸入，保留原本的輪盤滑動回饋與觸控範圍。
                      final distanceFromRest =
                          (page - _currentCarouselPage.toDouble()).abs();
                      final revealDuringSwipe = (distanceFromRest / 0.25).clamp(
                        0.0,
                        1.0,
                      );
                      final opacity = isCenter
                          ? 1.0
                          : (1.0 - diff * 0.38).clamp(0.0, 1.0) *
                                revealDuringSwipe;
                      final character = _characters[index];
                      final id = character['id'] as String;
                      final name = character['name'] as String? ?? '？';
                      final avatarPath =
                          character['avatar_path'] as String? ?? '';
                      final hasAvatar =
                          avatarPath.isNotEmpty &&
                          File(avatarPath).existsSync();
                      final isOnline =
                          isCenter &&
                          id == _activeCharacterId &&
                          _onlineDwellReady;
                      final isRp =
                          _globalRpEnabled ||
                          ContextModeSettings.preferredModeFromCharacter(
                                character,
                              ) ==
                              ContextMode.rp;

                      return Center(
                        child: Semantics(
                          button: true,
                          selected: isCenter,
                          label: isRp
                              ? '$name，RP'
                              : isOnline
                              ? '$name，${L.pick(en: 'Online', zhTW: '對方已上線', zhCN: '对方已上线')}'
                              : name,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              if (index == _currentCarouselPage) {
                                unawaited(_selectCharacter(id));
                                return;
                              }
                              moveCarouselTo(index);
                            },
                            child: Transform.scale(
                              scale: scale,
                              child: Opacity(
                                opacity: opacity,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      height: isIos ? 108 : 128,
                                      padding: const EdgeInsets.fromLTRB(
                                        10,
                                        9,
                                        10,
                                        8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.transparent,
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color:
                                              (_homeForegroundPalette
                                                          ?.secondary ??
                                                      YanciTheme.accent)
                                                  .withValues(
                                                    alpha: isCenter
                                                        ? (YanciTheme.isDark
                                                              ? 0.20
                                                              : 0.16)
                                                        : 0.10,
                                                  ),
                                          width: 0.6,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 50,
                                            height: 50,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: YanciTheme.accent
                                                  .withValues(
                                                    alpha: isCenter
                                                        ? 0.14
                                                        : 0.08,
                                                  ),
                                              border: Border.all(
                                                color: isCenter
                                                    ? YanciTheme.accent
                                                          .withValues(
                                                            alpha: 0.3,
                                                          )
                                                    : YanciTheme.textSecondary
                                                          .withValues(
                                                            alpha: 0.12,
                                                          ),
                                              ),
                                              image: hasAvatar
                                                  ? DecorationImage(
                                                      image: FileImage(
                                                        File(avatarPath),
                                                      ),
                                                      fit: BoxFit.cover,
                                                    )
                                                  : null,
                                            ),
                                            child: hasAvatar
                                                ? null
                                                : Icon(
                                                    Icons.person_rounded,
                                                    size: 27,
                                                    color: YanciTheme.accent
                                                        .withValues(alpha: 0.5),
                                                  ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Flexible(
                                                      child: Text(
                                                        name,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          fontSize: isCenter
                                                              ? 16
                                                              : 14,
                                                          fontWeight:
                                                              FontWeight.w400,
                                                          color: isCenter
                                                              ? (_homeForegroundPalette
                                                                        ?.primary ??
                                                                    YanciTheme
                                                                        .accent)
                                                              : (_homeForegroundPalette
                                                                        ?.secondary ??
                                                                    YanciTheme
                                                                        .textPrimary
                                                                        .withValues(
                                                                          alpha:
                                                                              0.64,
                                                                        )),
                                                          fontFamily: YanciTheme
                                                              .fontFamily,
                                                        ),
                                                      ),
                                                    ),
                                                    if (isRp || isOnline) ...[
                                                      const SizedBox(width: 6),
                                                      Container(
                                                        width: 7,
                                                        height: 7,
                                                        decoration: BoxDecoration(
                                                          color: isRp
                                                              ? contextRpColor
                                                              : Color(
                                                                  0xFF65C98A,
                                                                ),
                                                          shape:
                                                              BoxShape.circle,
                                                          boxShadow: [
                                                            BoxShadow(
                                                              color: Color(
                                                                0x5965C98A,
                                                              ),
                                                              blurRadius: 5,
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                                const SizedBox(height: 4),
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 4,
                                                      ),
                                                  child: CharacterSignaturePanel(
                                                    compact: true,
                                                    foregroundColor:
                                                        _homeForegroundPalette
                                                            ?.secondary,
                                                    ruleColor:
                                                        _homeForegroundPalette
                                                            ?.subtle,
                                                    onShowHistory: () =>
                                                        _showSignatureHistoryFor(
                                                          character['id']
                                                              as String,
                                                        ),
                                                    signature:
                                                        character['signature']
                                                            as String?,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (isRp || isOnline)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          isRp
                                              ? 'RP'
                                              : L.pick(
                                                  en: 'Online',
                                                  zhTW: '對方已上線',
                                                  zhCN: '对方已上线',
                                                ),
                                          style: TextStyle(
                                            fontSize: 9,
                                            height: 1.0,
                                            color: isRp
                                                ? contextRpColor
                                                : const Color(0xFF65C98A),
                                            fontFamily: YanciTheme.fontFamily,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          if (canGoPrevious)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: IconButton(
                onPressed: () => moveCarouselTo(_currentCarouselPage - 1),
                tooltip: L.pick(
                  en: 'Previous character',
                  zhTW: '上一個角色',
                  zhCN: '上一个角色',
                ),
                padding: EdgeInsets.zero,
                iconSize: 15,
                style: IconButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  tapTargetSize: MaterialTapTargetSize.padded,
                  foregroundColor: YanciTheme.textSecondary.withValues(
                    alpha: YanciTheme.isDark ? 0.19 : 0.15,
                  ),
                ),
                icon: const Icon(Icons.arrow_back_ios_new_rounded),
              ),
            ),
          if (canGoNext)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: IconButton(
                onPressed: () => moveCarouselTo(_currentCarouselPage + 1),
                tooltip: L.pick(
                  en: 'Next character',
                  zhTW: '下一個角色',
                  zhCN: '下一个角色',
                ),
                padding: EdgeInsets.zero,
                iconSize: 15,
                style: IconButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  tapTargetSize: MaterialTapTargetSize.padded,
                  foregroundColor: YanciTheme.textSecondary.withValues(
                    alpha: YanciTheme.isDark ? 0.19 : 0.15,
                  ),
                ),
                icon: const Icon(Icons.arrow_forward_ios_rounded),
              ),
            ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════
  // 心跳數值顯示（輪盤正下方）
  // ═══════════════════════════════════

  Widget _buildHeartbeatValue() {
    final bpm = _heartbeat ?? 0;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.favorite,
            size: 12,
            color: YanciTheme.accent.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 4),
          Text(
            '$bpm',
            style: YanciTheme.bodyText.copyWith(
              fontSize: 13,
              color: YanciTheme.accent.withValues(alpha: 0.7),
              fontWeight: FontWeight.w500,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════
  // 正在聊窗口入口
  // ═══════════════════════════════════

  Widget _buildActiveConvEntry() {
    final title = _keepAliveConvTitle ?? '';
    final imagePrimary = _homeForegroundPalette?.primary;
    final imageSecondary = _homeForegroundPalette?.secondary;
    final imageSubtle = _homeForegroundPalette?.subtle;
    final homePath = _boundBackgroundPreset?.homePath.trim() ?? '';
    final hasCustomHomeImage =
        homePath.isNotEmpty && File(homePath).existsSync();
    final dominant = _homeForegroundPalette?.dominant;
    final adaptiveSolid = dominant == null
        ? YanciTheme.surfacePanel
        : Color.lerp(
            dominant,
            dominant.computeLuminance() < 0.42 ? Colors.black : Colors.white,
            dominant.computeLuminance() < 0.42 ? 0.48 : 0.72,
          )!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(width: 46), // 對稱佔位 (38 + 8)
          Flexible(
            child: GestureDetector(
              onTap: () async {
                if (_keepAliveConvId == null) return;
                await _pushChatRoute(
                  arguments: _keepAliveConvId!,
                  restoreCharacterId: _activeCharacterId,
                );
                await _refreshAfterChatReturn();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: hasCustomHomeImage
                      ? adaptiveSolid.withValues(alpha: 0.9)
                      : YanciTheme.isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.white.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: hasCustomHomeImage
                        ? (imageSecondary ?? YanciTheme.accent).withValues(
                            alpha: 0.22,
                          )
                        : YanciTheme.accent.withValues(alpha: 0.2),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: YanciTheme.accent.withValues(alpha: 0.7),
                        boxShadow: [
                          BoxShadow(
                            color: YanciTheme.accent.withValues(alpha: 0.4),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        title.isEmpty
                            ? (L.pick(en: 'Continue chat', zhTW: '繼續對話'))
                            : title,
                        style: YanciTheme.bodyText.copyWith(
                          fontSize: 12,
                          color:
                              imagePrimary ??
                              YanciTheme.textPrimary.withValues(alpha: 0.7),
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.chevron_right,
                      size: 14,
                      color:
                          imageSecondary ??
                          YanciTheme.textSecondary.withValues(alpha: 0.5),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: L.pick(en: 'Manual summary', zhTW: '手動摘要'),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showManualSummaryOptions,
              child: SizedBox.square(
                dimension: 48,
                child: Center(
                  child: Icon(
                    Icons.edit_rounded,
                    size: 19,
                    color:
                        imageSubtle ??
                        YanciTheme.accent.withValues(alpha: 0.65),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showManualSummaryOptions() async {
    final convId = _keepAliveConvId;
    if (convId == null) return;

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: YanciTheme.surfacePanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  Icons.subject_rounded,
                  color: YanciTheme.accent.withValues(alpha: 0.78),
                ),
                title: Text(
                  L.pick(en: 'Summarize all messages', zhTW: '摘要全部聊天'),
                  style: TextStyle(color: YanciTheme.textPrimary),
                ),
                subtitle: Text(
                  L.pick(
                    en: 'Summarize every message in this window',
                    zhTW: '摘要目前窗口的全部消息',
                  ),
                  style: TextStyle(color: YanciTheme.textSecondary),
                ),
                onTap: () => Navigator.of(ctx).pop('all'),
              ),
              ListTile(
                leading: Icon(
                  Icons.checklist_rounded,
                  color: YanciTheme.accent.withValues(alpha: 0.78),
                ),
                title: Text(
                  L.pick(en: 'Select messages', zhTW: '選擇消息摘要'),
                  style: TextStyle(color: YanciTheme.textPrimary),
                ),
                subtitle: Text(
                  L.pick(
                    en: 'Select user and character bubbles in the chat',
                    zhTW: '進聊天窗口勾選 user / char 氣泡',
                  ),
                  style: TextStyle(color: YanciTheme.textSecondary),
                ),
                onTap: () => Navigator.of(ctx).pop('selected'),
              ),
              ListTile(
                leading: Icon(
                  Icons.library_books_rounded,
                  color: YanciTheme.accent.withValues(alpha: 0.78),
                ),
                title: Text(
                  L.pick(en: 'Character memory summaries', zhTW: '角色記憶摘要'),
                  style: TextStyle(color: YanciTheme.textPrimary),
                ),
                subtitle: Text(
                  L.pick(
                    en: 'Open summaries for the current character',
                    zhTW: '打開目前角色的記憶摘要頁',
                  ),
                  style: TextStyle(color: YanciTheme.textSecondary),
                ),
                onTap: () => Navigator.of(ctx).pop('memory_summary'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;

    if (choice == 'all') {
      await _confirmManualSummaryAll(convId);
    } else if (choice == 'selected') {
      await _pushChatRoute(
        arguments: {'conversationId': convId, 'manualSummarySelection': true},
        restoreCharacterId: _activeCharacterId,
      );
      await _refreshAfterChatReturn();
    } else if (choice == 'memory_summary') {
      await _openMemorySummaryShortcut(convId);
    }
  }

  Future<void> _openMemorySummaryShortcut(String convId) async {
    final conv = await DatabaseHelper.getConversation(convId);
    if (!mounted) return;
    await Navigator.pushNamed(
      context,
      '/memory',
      arguments: {
        'characterId': conv?.characterId ?? _activeCharacterId,
        'initialTab': 2,
      },
    );
  }

  Future<void> _confirmManualSummaryAll(String convId) async {
    final messages = await DatabaseHelper.getMessages(convId);
    final estimatedTokens = messages.fold<int>(
      0,
      (total, message) => total + TokenEstimator.estimate(message.text),
    );
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.surfacePanel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          L.pick(en: 'Summarize all messages', zhTW: '摘要全部聊天'),
          style: TextStyle(color: YanciTheme.textPrimary),
        ),
        content: Text(
          L.pick(
            en:
                'This window contains approximately $estimatedTokens message tokens. '
                'Summarize every message without changing chat content or automatic summaries.',
            zhTW:
                '目前窗口約有 $estimatedTokens tokens。會摘要全部消息，'
                '不會改動聊天內容，也不影響自動摘要。',
            zhCN:
                '当前窗口约有 $estimatedTokens tokens。将摘要全部消息，'
                '不会改动聊天内容，也不影响自动摘要。',
          ),
          style: TextStyle(color: YanciTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(L.pick(en: 'Cancel', zhTW: '取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(L.pick(en: 'Start', zhTW: '開始摘要')),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _runManualSummaryAll(convId, messages: messages);
  }

  Future<void> _runManualSummaryAll(
    String convId, {
    List<Message>? messages,
  }) async {
    final conv = await DatabaseHelper.getConversation(convId);
    final characterId = conv?.characterId ?? _activeCharacterId;
    final title = conv?.title ?? _keepAliveConvTitle ?? '';
    final sourceMessages = messages ?? await DatabaseHelper.getMessages(convId);
    if (!mounted) return;
    if (sourceMessages.isEmpty) {
      _showSnack(
        L.pick(en: 'There is no chat content to summarize', zhTW: '沒有可摘要的聊天內容'),
      );
      return;
    }

    showThemedPillNotice(
      context,
      L.pick(en: 'Creating summary…', zhTW: '正在整理摘要……', zhCN: '正在整理摘要……'),
    );

    try {
      await ManualSummaryService.summarizeMessages(
        conversationId: convId,
        characterId: characterId,
        messages: sourceMessages,
      );
      if (!mounted) return;
      showThemedPillNotice(
        context,
        L.pick(
          en: 'Manual summary completed.',
          zhTW: '手動摘要已完成',
          zhCN: '手动摘要已完成',
        ),
      );
    } on ManualSummaryPolicyFailure catch (e) {
      if (!mounted) return;
      _showManualSummaryFailureSnack(
        convId: convId,
        characterId: characterId,
        title: title,
        excerpt: e.excerpt,
      );
    } catch (e) {
      await AppErrorLogService.record(
        error: e,
        trigger: 'functional_summary_model_request',
        source: 'functional_model',
      );
      if (!mounted) return;
      showThemedPillNotice(
        context,
        '${L.pick(en: 'Summary failed', zhTW: '摘要失敗', zhCN: '摘要失败')}：$e',
        tone: ThemedNoticeTone.error,
      );
    }
  }

  void _showManualSummaryFailureSnack({
    required String convId,
    required String characterId,
    required String title,
    required String excerpt,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          L.pick(
            en: 'Summary failed. Please edit it manually.',
            zhTW: '摘要失敗，請手動摘要。',
          ),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: YanciTheme.accent,
        action: SnackBarAction(
          label: L.pick(en: 'Edit', zhTW: '編輯'),
          textColor: Colors.white,
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ManualSummaryCleanScreen(
                  conversationId: convId,
                  characterId: characterId,
                  title: title,
                  initialExcerpt: excerpt,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        backgroundColor: YanciTheme.accent,
      ),
    );
  }

  // ═══════════════════════════════════
  // 心電圖動畫（貫穿橫屏中段）
  // ═══════════════════════════════════

  Widget _buildHeartbeatLine() {
    return AnimatedBuilder(
      animation: _ecgController,
      builder: (context, _) {
        return CustomPaint(
          painter: _EcgPainter(
            progress: _ecgController.value,
            color: YanciTheme.ecgGlow,
            glowColor: YanciTheme.accentGlow,
            lineColor: YanciTheme.ecgLine,
            headColor: YanciTheme.ecgHead,
          ),
          size: Size.infinite,
        );
      },
    );
  }

  Widget _buildPulsingDot() {
    return AnimatedBuilder(
      animation: _ecgController,
      builder: (context, _) {
        final beat = sin(_ecgController.value * 2 * 3.14159 * 2);
        final scale = 1.0 + beat.abs() * 0.4;
        final opacity = 0.35 + beat.abs() * 0.35;

        return Transform.scale(
          scale: scale,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  YanciTheme.accent.withValues(alpha: opacity * 0.7),
                  YanciTheme.accent.withValues(alpha: opacity * 0.25),
                  YanciTheme.accent.withValues(alpha: 0),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
              boxShadow: [
                BoxShadow(
                  color: YanciTheme.accent.withValues(alpha: opacity * 0.5),
                  blurRadius: 25,
                  spreadRadius: 6,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 便利貼面板
  void _showNotesSheet() {
    final characterId = _activeCharacterId;
    final ctrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: YanciTheme.isDark
                    ? const Color(0xF0252228)
                    : Colors.white.withValues(alpha: 0.97),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(YanciTheme.radiusLg),
                ),
              ),
              padding: const EdgeInsets.all(YanciTheme.spacingMd),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: YanciTheme.spacingMd),
                  Row(
                    children: [
                      Icon(
                        Icons.sticky_note_2_outlined,
                        size: 16,
                        color: YanciTheme.accent,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        L.get('note_title'),
                        style: YanciTheme.headingMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: YanciTheme.spacingMd),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: ctrl,
                          autofocus: true,
                          style: YanciTheme.bodyText.copyWith(fontSize: 14),
                          decoration: InputDecoration(
                            hintText: L.pick(
                              en: 'Write something…',
                              zhTW: '寫點什麼……',
                            ),
                            hintStyle: YanciTheme.bodySmall.copyWith(
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.4,
                              ),
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(
                                YanciTheme.radiusSm,
                              ),
                              borderSide: BorderSide(
                                color: YanciTheme.accent.withValues(alpha: 0.2),
                              ),
                            ),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () async {
                          if (ctrl.text.trim().isEmpty) return;
                          await DatabaseHelper.addNote(
                            ctrl.text.trim(),
                            characterId: characterId,
                          );
                          ctrl.clear();
                          if (characterId == _activeCharacterId) {
                            _loadLatestNote(characterId: characterId);
                          }
                          setSheetState(() {});
                        },
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: YanciTheme.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(
                              YanciTheme.radiusSm,
                            ),
                          ),
                          child: Icon(
                            Icons.send_rounded,
                            size: 18,
                            color: YanciTheme.accent,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: YanciTheme.spacingMd),
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: DatabaseHelper.getNotes(
                      limit: 10,
                      characterId: characterId,
                    ),
                    builder: (ctx, snap) {
                      if (!snap.hasData || snap.data!.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.all(YanciTheme.spacingMd),
                          child: Text(
                            L.get('note_empty'),
                            style: YanciTheme.bodySmall.copyWith(
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.4,
                              ),
                            ),
                          ),
                        );
                      }
                      return Column(
                        children: snap.data!.map((n) {
                          return Dismissible(
                            key: ValueKey(n['id']),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 16),
                              child: Icon(
                                Icons.delete_outline,
                                size: 16,
                                color: Colors.red.withValues(alpha: 0.5),
                              ),
                            ),
                            onDismissed: (_) {
                              final id = n['id'] as int;
                              DatabaseHelper.deleteNote(id).then((_) {
                                if (characterId == _activeCharacterId) {
                                  _loadLatestNote(characterId: characterId);
                                }
                                setSheetState(() {});
                              });
                            },
                            child: Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: YanciTheme.aiBubble.withValues(
                                  alpha: 0.3,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      n['content'] as String,
                                      style: YanciTheme.bodyText.copyWith(
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    ((n['created_at'] as String?)?.substring(
                                          5,
                                          16,
                                        ) ??
                                        ''),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: YanciTheme.textSecondary
                                          .withValues(alpha: 0.35),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ═══════════════════════════════════
  // 歷史對話
  // 歷史對話
  Future<void> _showConversationList() async {
    final charId = _activeCharacterId;
    final allConversations = await DatabaseHelper.getConversations(
      characterId: charId,
    );
    var historyFilter = await ContextModeSettings.historyFilter(charId);
    if (!mounted) return;

    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final safeH = MediaQuery.of(context).size.height - topPad - bottomPad;
    // 與 _buildHomePage 一致：歷史浮層隨輪盤下移，保留原有間距。
    final visibleH = safeH - 66.0;
    final carouselBottom =
        topPad + visibleH / 3 + 28 + 12 + _homeCarouselOffsetY;
    final topInset = carouselBottom;
    // 底部：菜單欄高度(66) + 底部 padding + 菜單上方間距
    final bottomInset = 66.0 + (bottomPad > 0 ? bottomPad : 16.0) + 12.0;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'history',
      barrierColor: Colors.black.withValues(alpha: 0.2),
      transitionDuration: const Duration(milliseconds: 200),
      transitionBuilder: (_, anim, _, child) {
        final curve = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(opacity: curve, child: child);
      },
      pageBuilder: (dialogCtx, _, _) {
        var searchResults = List<Conversation>.from(allConversations);
        var conversations = ContextModeSettings.filterConversations(
          searchResults,
          historyFilter,
        );
        final searchCtrl = TextEditingController();
        // 搜尋世代號：每字一查是 async 的，慢的舊查詢後到會把
        // 新結果覆蓋回去——只採納最新一代的結果
        var searchGeneration = 0;

        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final historySurface = YanciTheme.isDark
                ? const Color(0xF5201D24)
                : Colors.white.withValues(alpha: 0.97);
            return Padding(
              padding: EdgeInsets.only(
                top: topInset,
                bottom: bottomInset,
                left: 24,
                right: 24,
              ),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    color: historySurface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: YanciTheme.isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.white.withValues(alpha: 0.7),
                      width: 0.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: YanciTheme.isDark ? 0.4 : 0.12,
                        ),
                        blurRadius: 32,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Column(
                      children: [
                        // ── 頂部：退出 + 標題 ──
                        Padding(
                          padding: const EdgeInsets.fromLTRB(6, 10, 16, 0),
                          child: Row(
                            children: [
                              IconButton(
                                onPressed: () => Navigator.pop(dialogCtx),
                                icon: Icon(
                                  Icons.close_rounded,
                                  size: 20,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                                padding: const EdgeInsets.all(8),
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                L.get('history_title'),
                                style: YanciTheme.headingMedium.copyWith(
                                  fontSize: 15,
                                ),
                              ),
                              const Spacer(),
                              HistoryModePill(
                                value: historyFilter.name,
                                backgroundColor: historySurface,
                                onChanged: (raw) {
                                  final next = ConversationHistoryFilter.values
                                      .firstWhere((value) => value.name == raw);
                                  setDialogState(() {
                                    historyFilter = next;
                                    conversations =
                                        ContextModeSettings.filterConversations(
                                          searchResults,
                                          next,
                                        );
                                  });
                                  unawaited(
                                    ContextModeSettings.setHistoryFilter(
                                      charId,
                                      next,
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),

                        // ── 搜索框 ──
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                          child: Container(
                            height: 38,
                            decoration: BoxDecoration(
                              color: YanciTheme.isDark
                                  ? Colors.white.withValues(alpha: 0.06)
                                  : Colors.grey.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: TextField(
                              controller: searchCtrl,
                              style: YanciTheme.bodyText.copyWith(fontSize: 13),
                              decoration: InputDecoration(
                                hintText: L.pick(en: 'Search…', zhTW: '搜索……'),
                                hintStyle: YanciTheme.bodySmall.copyWith(
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.35,
                                  ),
                                  fontSize: 13,
                                ),
                                prefixIcon: Icon(
                                  Icons.search_rounded,
                                  size: 18,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 9,
                                ),
                              ),
                              onChanged: (query) async {
                                final gen = ++searchGeneration;
                                final q = query.trim();
                                final results = q.isEmpty
                                    ? await DatabaseHelper.getConversations(
                                        characterId: charId,
                                      )
                                    : await DatabaseHelper.searchConversations(
                                        q,
                                        characterId: charId,
                                      );
                                // 已有更新的輸入 → 這批結果過期，丟棄
                                if (gen != searchGeneration) return;
                                setDialogState(() {
                                  searchResults = List.from(results);
                                  conversations =
                                      ContextModeSettings.filterConversations(
                                        searchResults,
                                        historyFilter,
                                      );
                                });
                              },
                            ),
                          ),
                        ),

                        // ── 對話列表 ──
                        if (conversations.isEmpty)
                          Expanded(
                            child: Center(
                              child: Text(
                                L.get('history_empty'),
                                textAlign: TextAlign.center,
                                style: YanciTheme.bodySmall.copyWith(
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          )
                        else
                          Expanded(
                            child: ListView.builder(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              itemCount: conversations.length,
                              itemBuilder: (listCtx, i) {
                                final conv = conversations[i];
                                final dateStr = conv.updatedAt
                                    .toIso8601String()
                                    .substring(0, 16)
                                    .replaceAll('T', ' ');
                                return InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () async {
                                    Navigator.pop(dialogCtx);
                                    await _pushChatRoute(
                                      arguments: conv.id,
                                      restoreCharacterId: charId,
                                    );
                                    await _refreshAfterChatReturn();
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        // 星標指示
                                        if (conv.isStarred)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 8,
                                            ),
                                            child: Icon(
                                              Icons.star_rounded,
                                              size: 14,
                                              color: YanciTheme.accent
                                                  .withValues(alpha: 0.7),
                                            ),
                                          ),
                                        // 標題+日期
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  ContextModeLabel(
                                                    mode: conv.contextMode,
                                                    compact: true,
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Expanded(
                                                    child: Text(
                                                      conv.title ??
                                                          L.pick(
                                                            en: 'New chat',
                                                            zhTW: '新對話',
                                                          ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: YanciTheme.bodyText
                                                          .copyWith(
                                                            fontSize: 14,
                                                          ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                dateStr,
                                                style: YanciTheme.bodySmall
                                                    .copyWith(
                                                      color: YanciTheme
                                                          .textSecondary
                                                          .withValues(
                                                            alpha: 0.45,
                                                          ),
                                                      fontSize: 11,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        // ── 操作按鈕（加大點擊範圍 44×44）──
                                        _historyAction(
                                          icon: Icons.edit_outlined,
                                          color: YanciTheme.textSecondary
                                              .withValues(alpha: 0.4),
                                          onTap: () =>
                                              _editConversationTitle(conv),
                                        ),
                                        _historyAction(
                                          icon: conv.isStarred
                                              ? Icons.star_rounded
                                              : Icons.star_border_rounded,
                                          color: conv.isStarred
                                              ? YanciTheme.accent
                                              : YanciTheme.textSecondary
                                                    .withValues(alpha: 0.4),
                                          onTap: () async {
                                            await DatabaseHelper.toggleStarConversation(
                                              conv.id,
                                              !conv.isStarred,
                                            );
                                            final updated =
                                                await DatabaseHelper.getConversations(
                                                  characterId: charId,
                                                );
                                            setDialogState(() {
                                              searchResults = List.from(
                                                updated,
                                              );
                                              conversations =
                                                  ContextModeSettings.filterConversations(
                                                    searchResults,
                                                    historyFilter,
                                                  );
                                            });
                                          },
                                        ),
                                        _historyAction(
                                          icon: Icons.delete_outline_rounded,
                                          color: Colors.red.withValues(
                                            alpha: 0.4,
                                          ),
                                          onTap: () async {
                                            final confirm = await showDialog<bool>(
                                              context: listCtx,
                                              builder: (dlgCtx) => AlertDialog(
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        YanciTheme.radiusMd,
                                                      ),
                                                ),
                                                backgroundColor:
                                                    YanciTheme.isDark
                                                    ? const Color(0xFF1E1E2E)
                                                    : Colors.white,
                                                content: Text(
                                                  L.pick(
                                                    en: 'Delete this conversation?',
                                                    zhTW: '確認刪除這段對話？',
                                                  ),
                                                  style: YanciTheme.bodyText
                                                      .copyWith(fontSize: 14),
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.pop(
                                                          dlgCtx,
                                                          false,
                                                        ),
                                                    child: Text(
                                                      L.get('cancel'),
                                                      style: TextStyle(
                                                        color: YanciTheme
                                                            .textSecondary,
                                                      ),
                                                    ),
                                                  ),
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.pop(
                                                          dlgCtx,
                                                          true,
                                                        ),
                                                    child: Text(
                                                      L.get('confirm_delete'),
                                                      style: TextStyle(
                                                        color: Colors.red
                                                            .withValues(
                                                              alpha: 0.7,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                            if (confirm == true) {
                                              if (KeepAliveService
                                                      .instance
                                                      .activeConversationId ==
                                                  conv.id) {
                                                await KeepAliveService.instance
                                                    .stop();
                                              }
                                              await DatabaseHelper.deleteConversation(
                                                conv.id,
                                              );
                                              final updated =
                                                  await DatabaseHelper.getConversations(
                                                    characterId: charId,
                                                  );
                                              setDialogState(() {
                                                searchResults = List.from(
                                                  updated,
                                                );
                                                conversations =
                                                    ContextModeSettings.filterConversations(
                                                      searchResults,
                                                      historyFilter,
                                                    );
                                              });
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 歷史列表操作按鈕 — 最小觸控 44×44（無障礙標準）
  Widget _historyAction({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(child: Icon(icon, size: 18, color: color)),
      ),
    );
  }

  // ═══════════════════════════════════
  // 編輯對話標題
  // ═══════════════════════════════════

  void _editConversationTitle(Conversation conv) {
    final ctrl = TextEditingController(text: conv.title ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.isDark
            ? const Color(0xFF252228)
            : Colors.white,
        title: Text(
          L.get('history_edit_title'),
          style: YanciTheme.headingMedium,
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: YanciTheme.bodyText,
          decoration: InputDecoration(
            hintText: L.pick(en: 'Enter a title…', zhTW: '輸入標題……'),
            hintStyle: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: 0.4),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              L.get('cancel'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              final title = ctrl.text.trim();
              if (title.isNotEmpty) {
                await DatabaseHelper.updateConversation(conv.id, title: title);
              }
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              // 重新加載歷史列表
              if (!mounted) return;
              Navigator.pop(context);
              _showConversationList();
            },
            child: Text(
              L.get('confirm_ok'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════
  // 我的 tab
  // ═══════════════════════════════════

  // ═══════════════════════════════════
  // 底部導航
  // ═══════════════════════════════════

  Future<void> _handleNavTap(int index) async {
    if (index == _currentTab) return;
    HapticFeedback.selectionClick();
    if (index == 0 && _currentTab != 0) {
      await UserSettings.saveActiveCharacterId(_activeCharacterId);
      if (!mounted) return;
    }
    setState(() {
      _tabBackgroundTransitionDirection = index < _currentTab
          ? BackgroundTransitionDirection.leftToRight
          : BackgroundTransitionDirection.rightToLeft;
      _currentTab = index;
    });
    if (index != 0) unawaited(_loadCharacters());
    _syncHomeAnimations();
  }
}

/// 發光心電線 — Light Line 風格，從左往右掃描
class _EcgPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color glowColor;
  final Color lineColor; // 主線：主題色系，與背景有對比
  final Color headColor; // 掃描頭亮點

  _EcgPainter({
    required this.progress,
    required this.color,
    required this.glowColor,
    required this.lineColor,
    required this.headColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    final w = size.width;

    // 掃描頭位置（從左到右循環，延長離場距離讓尾跡完全消失再重置）
    final headX = progress * w * 1.8 - w * 0.2;
    // 可見窗口：掃描頭左邊一段距離（加長尾跡，淡出更柔和）
    final trailLen = w * 0.7;

    // 心電圖波形定義（一個週期的關鍵點 [x比例, y偏移]）
    // 平線 → P波 → 平線 → Q → R(主峰) → S → 平線 → T波 → 平線
    final waveLen = w * 0.32;

    // 在 x 位置取波形 y 值
    double waveY(double x) {
      // 對 waveLen 取模得到週期內位置
      double t = (x % waveLen) / waveLen;
      if (t < 0) t += 1;

      if (t < 0.30) return 0; // 平線
      if (t < 0.38) {
        // P波（小圓弧）
        final p = (t - 0.30) / 0.08;
        return -12 * sin(p * 3.14159);
      }
      if (t < 0.42) return 0; // 短平線
      if (t < 0.46) {
        // Q 下降
        final p = (t - 0.42) / 0.04;
        return 10 * p;
      }
      if (t < 0.52) {
        // R 主峰（上衝）
        final p = (t - 0.46) / 0.06;
        return 10 - 60 * sin(p * 3.14159);
      }
      if (t < 0.56) {
        // S 下谷
        final p = (t - 0.52) / 0.04;
        return 15 * (1 - p);
      }
      if (t < 0.62) return 0; // 短平線
      if (t < 0.75) {
        // T波
        final p = (t - 0.62) / 0.13;
        return -18 * sin(p * 3.14159);
      }
      return 0; // 平線
    }

    // 點的亮度：離掃描頭越近越亮，超出 trail 完全消失
    double brightness(double x) {
      final dist = headX - x;
      if (dist < 0 || dist > trailLen) return 0;
      // 靠近頭部最亮，尾巴漸出（三次曲線更柔和）
      final t = 1.0 - (dist / trailLen);
      return t * t * t;
    }

    // 繪製路徑（逐像素取樣）
    final step = 2.0;

    // 第一層：寬光暈
    for (double x = 0; x < w; x += step * 2) {
      final b = brightness(x);
      if (b < 0.02) continue;
      final y = waveY(x);
      final glowP = Paint()
        ..color = color.withValues(alpha: b * 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 25);
      canvas.drawCircle(Offset(x, midY + y), 8, glowP);
    }

    // 第二層：窄光暈
    for (double x = 0; x < w; x += step) {
      final b = brightness(x);
      if (b < 0.03) continue;
      final y = waveY(x);
      final glowP = Paint()
        ..color = color.withValues(alpha: b * 0.4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawCircle(Offset(x, midY + y), 3, glowP);
    }

    // 第三層：主線條
    Path? linePath;
    double? lastB;
    for (double x = 0; x < w; x += step) {
      final b = brightness(x);
      if (b < 0.03) {
        if (linePath != null && lastB != null && lastB >= 0.03) {
          final lineP = Paint()
            ..color = lineColor.withValues(alpha: 0.9)
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round;
          canvas.drawPath(linePath, lineP);
          linePath = null;
        }
        lastB = b;
        continue;
      }
      final y = waveY(x);
      if (linePath == null) {
        linePath = Path()..moveTo(x, midY + y);
      } else {
        linePath.lineTo(x, midY + y);
      }
      lastB = b;
    }
    if (linePath != null) {
      final lineP = Paint()
        ..color = lineColor.withValues(alpha: 0.9)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(linePath, lineP);
    }

    // 掃描頭亮點
    if (headX > 0 && headX < w) {
      final hy = waveY(headX);
      final dotP = Paint()
        ..color = headColor
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawCircle(Offset(headX, midY + hy), 3, dotP);

      // 頭部額外光暈
      final haloP = Paint()
        ..color = color.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20);
      canvas.drawCircle(Offset(headX, midY + hy), 12, haloP);
    }
  }

  @override
  bool shouldRepaint(covariant _EcgPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/*
/// 像素小屋入口的迷你角色（16×24 @1.5x = 24×36）
class _MiniYanciPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    YanciPixels.paintFrame(canvas, YanciPixels.idle, 1.5);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
*/

// 原「開關」入口圖示；造型更像用量環，保留給側欄用量摘要卡使用。
// ignore: unused_element
class _SegmentedUsageIcon extends StatelessWidget {
  const _SegmentedUsageIcon({
    required this.size,
    required this.baseColor,
    required this.accentColor,
  });

  final double size;
  final Color baseColor;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _SegmentedUsageIconPainter(
          baseColor: baseColor,
          accentColor: accentColor,
        ),
      ),
    );
  }
}

class _SegmentedUsageIconPainter extends CustomPainter {
  const _SegmentedUsageIconPainter({
    required this.baseColor,
    required this.accentColor,
  });

  final Color baseColor;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final d = min(size.width, size.height);
    final stroke = d * 0.14;
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: d - stroke,
      height: d - stroke,
    );

    final basePaint = Paint()
      ..color = baseColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    final accentPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    // 重新計算完美的弧度，留出均勻且足夠的圓角呼吸空間
    // Accent (短弧)：位於右上方，大約從 -70度 到 -25度 (45度的圓弧)
    final double accentStart = -1.22;
    final double accentSweep = 0.78;

    // Base (長弧)：大約從 5度 到 260度 (255度的圓弧)
    final double baseStart = 0.09;
    final double baseSweep = 4.45;

    canvas.drawArc(rect, baseStart, baseSweep, false, basePaint);
    canvas.drawArc(rect, accentStart, accentSweep, false, accentPaint);
  }

  @override
  bool shouldRepaint(covariant _SegmentedUsageIconPainter oldDelegate) {
    return oldDelegate.baseColor != baseColor ||
        oldDelegate.accentColor != accentColor;
  }
}
