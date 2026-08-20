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
import '../widgets/starfield_painter.dart';
import '../widgets/rain_painter.dart';
import '../widgets/neural_field.dart';
import '../memory/database.dart';
import '../models/message.dart';
import '../services/settings_manager.dart';
import '../services/backup_service.dart';
import '../services/device_file_saver.dart';
import '../services/keep_alive_service.dart';
import '../services/manual_summary_service.dart';
import '../services/character_signature_service.dart';
import '../services/scratch_service.dart';
import '../widgets/orbit_loading_indicator.dart';
import '../widgets/yanci_bottom_nav_bar.dart';
import '../widgets/character_signature_panel.dart';
import '../utils/latest_request_gate.dart';
import 'manual_summary_clean_screen.dart';

part 'home_screen_profile.dart';

enum _BackupExportMode { save, share }

enum _BackupSheetAction { save, share, import, cleanup }

/// 主頁 — 角色輪盤 + 水晶球 + 底部導航
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  int _currentTab = 2; // 首頁居中
  List<Map<String, dynamic>> _characters = [];
  String _activeCharacterId = 'default';
  String? _latestNote;
  List<String> _randomNotes = [];
  int _randomNoteIndex = 0;

  // 角色輪盤
  PageController? _carouselController;
  int _currentCarouselPage = 0;
  Timer? _onlineDwellTimer;
  bool _onlineDwellReady = false;

  // 心電圖動畫
  late AnimationController _ecgController;

  // 保活心跳
  int? _heartbeat;
  String? _keepAliveConvId;
  String? _keepAliveConvTitle;
  StreamSubscription<KeepAliveHeartbeat>? _heartbeatSub;

  // 用戶貝殼餘額
  int _userCoins = 0;
  StreamSubscription<int>? _userCoinsSub;

  static const Duration _autoBackupInterval = Duration(hours: 1);
  Timer? _autoBackupTimer;
  DateTime? _lastLocalBackupAt;
  bool _autoBackupRunning = false;
  bool _backupExportRunning = false;
  bool _namePromptOpen = false;
  bool _isStartingChat = false;
  bool _reduceMotion = false;
  final LatestRequestGate _charactersGate = LatestRequestGate();
  final LatestRequestGate _noteGate = LatestRequestGate();
  final LatestRequestGate _coinsGate = LatestRequestGate();
  final LatestRequestGate _keepAliveGate = LatestRequestGate();
  int _characterSelectionGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ecgController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
    // 順序化啟動：先解析＋校正＋持久化 active character，再載入
    // 便箋/貝殼/保活等附屬資料——並行啟動時附屬項可能先用 default
    // 跑完把正確資料蓋掉，或失效 activeId 一直殘留在內部。
    unawaited(_reloadHomeAfterRestore());
    _checkFirstTimeUser();

    // 監聽心跳流
    _heartbeatSub = KeepAliveService.instance.heartbeatStream.listen((event) {
      if (!mounted || event.characterId != _activeCharacterId) return;
      setState(() => _heartbeat = event.value);
    });

    // 用戶貝殼變更即時同步。聊天頁轉帳 / 刮刮卡結算時會推送這裡。
    _userCoinsSub = ScratchService.userCoinsChanged.listen((coins) {
      if (!mounted) return;
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
    _charactersGate.invalidate();
    _noteGate.invalidate();
    _coinsGate.invalidate();
    _keepAliveGate.invalidate();
    _autoBackupTimer?.cancel();
    _heartbeatSub?.cancel();
    _userCoinsSub?.cancel();
    _onlineDwellTimer?.cancel();
    _carouselController?.dispose();
    _ecgController.dispose();
    super.dispose();
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
    final shouldAnimate = mounted && !_reduceMotion && _currentTab != 4;
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
    }
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
    final convId = await KeepAliveService.getActiveConvId(characterId: charId);
    final title = await KeepAliveService.getActiveConvTitle(
      characterId: charId,
    );
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
    final coins = await ScratchService.getUserCoins();
    if (mounted && _coinsGate.isCurrent(generation)) {
      setState(() => _userCoins = coins);
    }
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

  String _userName = '';
  String? _userAvatar;

  Future<void> _loadLatestNote({String? characterId}) async {
    final charId = characterId ?? _activeCharacterId;
    final generation = _noteGate.begin();
    final note = await DatabaseHelper.getLatestNote(characterId: charId);
    final randoms = await DatabaseHelper.getRandomNotes(charId, count: 10);
    final name = await UserSettings.getUserName();
    final avatar = await UserSettings.getUserAvatarPath();
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
      _userAvatar = avatar.isNotEmpty ? avatar : null;
    });
  }

  Future<void> _loadCharacters({String? selectId}) async {
    final generation = _charactersGate.begin();
    final chars = await DatabaseHelper.getCharacters();
    final activeId = selectId ?? await UserSettings.getActiveCharacterId();

    int activeIndex = 0;
    for (int i = 0; i < chars.length; i++) {
      if (chars[i]['id'] == activeId) {
        activeIndex = i;
        break;
      }
    }

    if (!mounted || !_charactersGate.isCurrent(generation)) return;
    _carouselController?.dispose();
    _carouselController = PageController(
      viewportFraction: 0.72,
      initialPage: activeIndex,
    );
    _currentCarouselPage = activeIndex;

    setState(() {
      _characters = chars;
      _activeCharacterId = activeId;
    });
    _beginOnlineDwell(activeId);
    unawaited(_loadKeepAliveInfo(characterId: activeId));

    // TODO: 每日自動發放貝殼 — 遊戲上線後刪除
    final charIds = chars.map((c) => c['id'] as String).toList();
    ScratchService.checkDailyGrant(characterIds: charIds).then((_) {
      if (mounted && _charactersGate.isCurrent(generation)) {
        _loadUserCoins();
      }
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
      _loadUserCoins(),
      _loadKeepAliveInfo(characterId: activeId),
      _refreshLastBackupTime(),
    ]);
  }

  Future<void> _selectCharacter(String id) async {
    if (id == _activeCharacterId && _characters.isNotEmpty) return;
    final generation = ++_characterSelectionGeneration;
    _charactersGate.invalidate();

    // UI selection must change before any persistence or database await.
    if (mounted) {
      setState(() {
        _activeCharacterId = id;
        _onlineDwellReady = false;
        _latestNote = null;
        _randomNotes = const [];
        _heartbeat = null;
        _keepAliveConvId = null;
        _keepAliveConvTitle = null;
      });
    }
    _beginOnlineDwell(id);
    _noteGate.invalidate();
    _keepAliveGate.invalidate();

    unawaited(_loadLatestNote(characterId: id));
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
    setState(() => _onlineDwellReady = false);
    _onlineDwellTimer = Timer(const Duration(seconds: 1), () {
      if (!mounted || _activeCharacterId != characterId) return;
      setState(() => _onlineDwellReady = true);
    });
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
      final conv = Conversation(id: convId, characterId: charId);
      await DatabaseHelper.createConversation(conv);

      if (mounted) {
        await Navigator.of(context).pushNamed('/chat', arguments: convId);
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

  void _refreshProfileTheme() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: GradientBackground(
        scope: YanciBackgroundScope.home,
        child: Stack(
          children: [
            Positioned.fill(
              child: TickerMode(
                enabled:
                    YanciTheme.starEnabled &&
                    _currentTab != 4 &&
                    !_reduceMotion,
                child: Offstage(
                  offstage: !YanciTheme.starEnabled || _currentTab == 4,
                  child: RepaintBoundary(
                    child: switch (YanciTheme.bgEffect) {
                      'stars' => const StarfieldWidget(starCount: 18),
                      'rain' => const RainWidget(dropCount: 30),
                      _ => const NeuralFieldWidget(nodeCount: 18),
                    },
                  ),
                ),
              ),
            ),
            SafeArea(child: _buildCurrentPage()),
          ],
        ),
      ),
      bottomNavigationBar: YanciBottomNavBar(
        activeIndex: _currentTab,
        reduceMotion: _reduceMotion,
        onTap: _handleNavTap,
      ),
    );
  }

  Widget _buildCurrentPage() {
    // IndexedStack 保持 home 頁存活，切到 profile 再切回來不丟輪盤選中
    return IndexedStack(
      index: _currentTab == 4 ? 1 : 0,
      children: [_buildHomePage(), _buildProfilePage()],
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
        // 畫面均分三塊，輪盤中心落在上 1/3 線
        // 輪盤內容含卡片下方的在線提示；與輪盤 widget 的 120 高度一致，
        // 避免提示文字在 Positioned 內被擠出底部。
        const carouselH = 120.0;
        final carouselCenterY = visibleH / 3;
        final carouselTop = max(0.0, carouselCenterY - carouselH / 2);
        // 問候語在頂部（≈50 給貝殼/歷史行）與輪盤之間的正中心
        const topReserved = 50.0;
        final canShowGreeting = carouselTop - 10 >= topReserved;
        final greetingCenterY = (topReserved + carouselTop) / 2;
        // 小螢幕沒有足夠間距時直接隱藏問候語，不對無效區間 clamp。
        final greetingTop = canShowGreeting
            ? (greetingCenterY - 20).clamp(topReserved, carouselTop - 10)
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
            // ═══ 用戶貝殼餘額（左上角）═══
            Positioned(
              top: 12,
              left: 20,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
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
                          color: YanciTheme.textSecondary.withValues(
                            alpha: 0.6,
                          ),
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
    // 優先顯示 AI 便箋
    String? noteToShow;
    if (_latestNote != null && _latestNote!.isNotEmpty) {
      noteToShow = _latestNote;
    } else if (_randomNotes.isNotEmpty) {
      noteToShow = _randomNotes[_randomNoteIndex % _randomNotes.length];
    }

    if (noteToShow != null) {
      return Semantics(
        button: true,
        label: L.pick(en: 'Open notes', zhTW: '開啟便箋'),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _showNotesSheet,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              '「$noteToShow」',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w300,
                color: YanciTheme.textPrimary.withValues(alpha: 0.8),
                fontFamily: YanciTheme.fontFamily,
                letterSpacing: 1.5,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
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
          child: Text(
            greeting,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w300,
              color: YanciTheme.textPrimary.withValues(alpha: 0.7),
              fontFamily: YanciTheme.fontFamily,
              letterSpacing: 1.5,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════
  // 角色輪盤（卡片式撥動切換 + 居中放大 + 兩側漸小漸淡）
  // ═══════════════════════════════════

  Widget _buildCharacterCarousel() {
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
      height: 120,
      child: Stack(
        children: [
          Center(
            child: SizedBox(
              width: carouselWidth,
              child: PageView.builder(
                controller: _carouselController!,
                itemCount: _characters.length,
                onPageChanged: (index) {
                  _currentCarouselPage = index;
                  final id = _characters[index]['id'] as String;
                  _beginOnlineDwell(id);
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

                      return Center(
                        child: Semantics(
                          button: true,
                          selected: isCenter,
                          label: isOnline
                              ? '$name，${L.pick(en: 'Online', zhTW: '對方已上線', zhCN: '对方已上线')}'
                              : name,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _selectCharacter(id),
                            child: Transform.scale(
                              scale: scale,
                              child: Opacity(
                                opacity: opacity,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      height: 92,
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
                                          color: YanciTheme.accent.withValues(
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
                                                              ? YanciTheme
                                                                    .accent
                                                              : YanciTheme
                                                                    .textPrimary
                                                                    .withValues(
                                                                      alpha:
                                                                          0.64,
                                                                    ),
                                                          fontFamily: YanciTheme
                                                              .fontFamily,
                                                        ),
                                                      ),
                                                    ),
                                                    if (isOnline) ...[
                                                      const SizedBox(width: 6),
                                                      Container(
                                                        width: 7,
                                                        height: 7,
                                                        decoration:
                                                            const BoxDecoration(
                                                              color: Color(
                                                                0xFF65C98A,
                                                              ),
                                                              shape: BoxShape
                                                                  .circle,
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
                                    if (isOnline)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          L.pick(
                                            en: 'Online',
                                            zhTW: '對方已上線',
                                            zhCN: '对方已上线',
                                          ),
                                          style: TextStyle(
                                            fontSize: 9,
                                            height: 1.0,
                                            color: const Color(0xFF65C98A),
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
                await Navigator.pushNamed(
                  context,
                  '/chat',
                  arguments: _keepAliveConvId,
                );
                await _refreshAfterChatReturn();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: YanciTheme.isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.white.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: YanciTheme.accent.withValues(alpha: 0.2),
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
                          color: YanciTheme.textPrimary.withValues(alpha: 0.7),
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.chevron_right,
                      size: 14,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.5),
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
                    color: YanciTheme.accent.withValues(alpha: 0.65),
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
      await Navigator.pushNamed(
        context,
        '/chat',
        arguments: {'conversationId': convId, 'manualSummarySelection': true},
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
            en: 'Summarizes every message in this window without changing chat content or automatic summaries.',
            zhTW: '會摘要目前窗口內全部消息，不會改動聊天內容，也不影響自動摘要。',
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
    await _runManualSummaryAll(convId);
  }

  Future<void> _runManualSummaryAll(String convId) async {
    final conv = await DatabaseHelper.getConversation(convId);
    final characterId = conv?.characterId ?? _activeCharacterId;
    final title = conv?.title ?? _keepAliveConvTitle ?? '';
    final messages = await DatabaseHelper.getMessages(convId);
    if (!mounted) return;
    if (messages.isEmpty) {
      _showSnack(
        L.pick(en: 'There is no chat content to summarize', zhTW: '沒有可摘要的聊天內容'),
      );
      return;
    }

    var loadingOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: YanciTheme.surfacePanel,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      ),
    );

    try {
      await ManualSummaryService.summarizeMessages(
        conversationId: convId,
        characterId: characterId,
        messages: messages,
      );
      if (!mounted) return;
      if (loadingOpen) {
        loadingOpen = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
      _showSnack(L.pick(en: 'Manual summary completed.', zhTW: '手動摘要已完成。'));
    } on ManualSummaryPolicyFailure catch (e) {
      if (!mounted) return;
      if (loadingOpen) {
        loadingOpen = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
      _showManualSummaryFailureSnack(
        convId: convId,
        characterId: characterId,
        title: title,
        excerpt: e.excerpt,
      );
    } catch (e) {
      if (!mounted) return;
      if (loadingOpen) {
        loadingOpen = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
      _showSnack('${L.pick(en: 'Summary failed', zhTW: '摘要失敗')}：$e');
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
    if (!mounted) return;

    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final safeH = MediaQuery.of(context).size.height - topPad - bottomPad;
    // 與 _buildHomePage 一致：可見區域 = safeH - navBar(66)，輪盤中心在 1/3
    final visibleH = safeH - 66.0;
    final carouselBottom =
        topPad + visibleH / 3 + 28 + 12; // center + half + gap
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
        var conversations = List<Conversation>.from(allConversations);
        final searchCtrl = TextEditingController();
        // 搜尋世代號：每字一查是 async 的，慢的舊查詢後到會把
        // 新結果覆蓋回去——只採納最新一代的結果
        var searchGeneration = 0;

        return StatefulBuilder(
          builder: (ctx, setDialogState) {
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
                    color: YanciTheme.isDark
                        ? const Color(0xF5201D24)
                        : Colors.white.withValues(alpha: 0.97),
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
                              const SizedBox(width: 36),
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
                                setDialogState(
                                  () => conversations = List.from(results),
                                );
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
                                    await Navigator.of(
                                      context,
                                    ).pushNamed('/chat', arguments: conv.id);
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
                                              Text(
                                                conv.title ??
                                                    L.pick(
                                                      en: 'New chat',
                                                      zhTW: '新對話',
                                                    ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: YanciTheme.bodyText
                                                    .copyWith(fontSize: 14),
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
                                            setDialogState(
                                              () => conversations = List.from(
                                                updated,
                                              ),
                                            );
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
                                              setDialogState(
                                                () => conversations = List.from(
                                                  updated,
                                                ),
                                              );
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
    HapticFeedback.selectionClick();
    if (index == 0) {
      Navigator.of(context).pushNamed('/api_settings');
      return;
    }
    if (index == 1) {
      Navigator.of(context).pushNamed('/usage');
      return;
    }
    if (index == 3) {
      await Navigator.of(context).pushNamed('/character_list');
      if (mounted) _loadCharacters(selectId: _activeCharacterId);
      return;
    }
    setState(() => _currentTab = index);
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
