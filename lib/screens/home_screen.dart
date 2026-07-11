import 'dart:async';
import 'dart:ui';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../widgets/shop_backpack_sheets.dart';
import 'package:file_picker/file_picker.dart';
import '../theme/app_theme.dart';
import '../services/locale_strings.dart';
import '../main.dart' show themeNotifier;
import '../widgets/coin_amount_text.dart';
import '../widgets/gradient_background.dart';
import '../widgets/starfield_painter.dart';
import '../widgets/neural_field.dart';
import '../memory/database.dart';
import '../models/message.dart';
import '../services/settings_manager.dart';
import '../services/backup_service.dart';
import '../services/keep_alive_service.dart';
import '../services/manual_summary_service.dart';
import '../services/scratch_service.dart';
import '../widgets/orbit_loading_indicator.dart';
import 'ability_modules_screen.dart';
import 'manual_summary_clean_screen.dart';

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
  bool _namePromptOpen = false;
  bool _isStartingChat = false;
  bool _reduceMotion = false;

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
    final ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: YanciTheme.isDark
            ? const Color(0xFF252228)
            : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(L.get('first_time_title'), style: YanciTheme.headingMedium),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: YanciTheme.bodyText,
          decoration: InputDecoration(
            hintText: L.get('first_time_hint'),
            hintStyle: YanciTheme.bodySmall.copyWith(
              color: YanciTheme.textSecondary.withValues(alpha: 0.4),
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await UserSettings.saveNamePromptCompleted(true);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(
              L.get('first_time_skip'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                await UserSettings.saveUserName(name);
              }
              await UserSettings.saveNamePromptCompleted(true);
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              if (!mounted) return;
              _loadLatestNote();
            },
            child: Text(
              L.get('confirm_ok'),
              style: TextStyle(color: YanciTheme.accent),
            ),
          ),
        ],
      ),
    ).whenComplete(() {
      ctrl.dispose();
      _namePromptOpen = false;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoBackupTimer?.cancel();
    _heartbeatSub?.cancel();
    _userCoinsSub?.cancel();
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
    final convId = await KeepAliveService.getActiveConvId(characterId: charId);
    final title = await KeepAliveService.getActiveConvTitle(
      characterId: charId,
    );
    final hb = await KeepAliveService.getLastHeartbeat(characterId: charId);
    if (mounted) {
      setState(() {
        _keepAliveConvId = convId;
        _keepAliveConvTitle = title;
        _heartbeat = hb;
      });
    }
  }

  Future<void> _loadUserCoins() async {
    final coins = await ScratchService.getUserCoins();
    if (mounted) setState(() => _userCoins = coins);
  }

  Future<void> _refreshAfterChatReturn() async {
    await _loadKeepAliveInfo(characterId: _activeCharacterId);
    await _loadUserCoins();
  }

  String _userName = '';
  String? _userAvatar;

  Future<void> _loadLatestNote() async {
    final note = await DatabaseHelper.getLatestNote(
      characterId: _activeCharacterId,
    );
    final randoms = await DatabaseHelper.getRandomNotes(
      _activeCharacterId,
      count: 10,
    );
    final name = await UserSettings.getUserName();
    final avatar = await UserSettings.getUserAvatarPath();
    if (!mounted) return;
    setState(() {
      _latestNote = note?['content'] as String?;
      _randomNotes = randoms.map((r) => r['content'] as String).toList();
      _randomNoteIndex = 0;
      _userName = name;
      _userAvatar = avatar.isNotEmpty ? avatar : null;
    });
  }

  Future<void> _loadCharacters({String? selectId}) async {
    final chars = await DatabaseHelper.getCharacters();
    final activeId = selectId ?? await UserSettings.getActiveCharacterId();

    int activeIndex = 0;
    for (int i = 0; i < chars.length; i++) {
      if (chars[i]['id'] == activeId) {
        activeIndex = i;
        break;
      }
    }

    if (!mounted) return;
    _carouselController?.dispose();
    _carouselController = PageController(
      viewportFraction: 0.28,
      initialPage: activeIndex,
    );
    _currentCarouselPage = activeIndex;

    setState(() {
      _characters = chars;
      _activeCharacterId = activeId;
    });
    _loadKeepAliveInfo(characterId: activeId);

    // TODO: 每日自動發放貝殼 — 遊戲上線後刪除
    final charIds = chars.map((c) => c['id'] as String).toList();
    ScratchService.checkDailyGrant(characterIds: charIds).then((_) {
      if (mounted) _loadUserCoins();
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
    await UserSettings.saveActiveCharacterId(id);

    final char = await DatabaseHelper.getCharacter(id);
    if (char != null) {
      await UserSettings.saveCharacterName(char['name'] ?? '');
    }

    if (!mounted) return;
    setState(() => _activeCharacterId = id);

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

    _loadLatestNote(); // 切換角色 → 便箋跟著切
    _loadKeepAliveInfo(characterId: id);
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
      final convId = const Uuid().v4();
      final conv = Conversation(id: convId, characterId: _activeCharacterId);
      await DatabaseHelper.createConversation(conv);

      if (mounted) {
        await Navigator.of(context).pushNamed('/chat', arguments: convId);
        // 從聊天頁返回 → 刷新保活狀態 + 貝殼餘額
        await _refreshAfterChatReturn();
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
                    child: YanciTheme.bgEffect == 'stars'
                        ? const StarfieldWidget(starCount: 18)
                        : const NeuralFieldWidget(nodeCount: 18),
                  ),
                ),
              ),
            ),
            SafeArea(child: _buildCurrentPage()),
          ],
        ),
      ),
      bottomNavigationBar: _buildNavBar(),
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
        const carouselH = 56.0;
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
                child: _buildGreeting(),
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
                          children: [_buildHeartbeatLine(), _buildPulsingDot()],
                        ),
                      ),
                    ),
                  ),
                  if (_keepAliveConvId != null) _buildActiveConvEntry(),
                ],
              ),
            ),
            // ═══ 用戶貝殼餘額（左上角）═══
            Positioned(
              top: 12,
              left: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: YanciTheme.isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.white.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: YanciTheme.isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.white.withValues(alpha: 0.6),
                    width: 0.5,
                  ),
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
            // ═══ 能力模組入口（右上角，歷史對話左邊）═══
            Positioned(
              top: 12,
              right: 72,
              child: Tooltip(
                message: L.pick(en: 'Ability modules', zhTW: '能力模組'),
                child: Semantics(
                  button: true,
                  label: L.pick(en: 'Ability modules', zhTW: '能力模組'),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _showAbilityModulesScreen,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: YanciTheme.isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.white.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: YanciTheme.isDark
                              ? Colors.white.withValues(alpha: 0.1)
                              : Colors.white.withValues(alpha: 0.6),
                          width: 0.5,
                        ),
                      ),
                      child: Icon(
                        Icons.dashboard_customize_rounded,
                        size: 22,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
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
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: YanciTheme.isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.white.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: YanciTheme.isDark
                              ? Colors.white.withValues(alpha: 0.1)
                              : Colors.white.withValues(alpha: 0.6),
                          width: 0.5,
                        ),
                      ),
                      child: Icon(
                        Icons.history_rounded,
                        size: 22,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.6),
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
  // 角色輪盤（撥動切換 + 居中放大 + 兩側漸小漸淡）
  // ═══════════════════════════════════

  Widget _buildCharacterCarousel() {
    if (_characters.isEmpty || _carouselController == null) {
      return SizedBox(
        height: 56,
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

    return SizedBox(
      height: 56,
      child: Stack(
        children: [
          // 輪盤固定寬度居中（width 控制寬窄）
          Center(
            child: SizedBox(
              width: 260,
              child: PageView.builder(
                controller: _carouselController!,
                itemCount: _characters.length,
                onPageChanged: (index) {
                  _currentCarouselPage = index;
                  _selectCharacter(_characters[index]['id'] as String);
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
                      final scale = (1.0 - diff * 0.22).clamp(0.68, 1.0);
                      final opacity = (1.0 - diff * 0.45).clamp(0.15, 1.0);
                      final isCenter = diff < 0.5;

                      return Center(
                        child: Transform.scale(
                          scale: scale,
                          child: Opacity(
                            opacity: opacity,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: isCenter
                                    ? YanciTheme.accent.withValues(alpha: 0.18)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(16),
                                border: isCenter
                                    ? Border.all(
                                        color: YanciTheme.accent.withValues(
                                          alpha: 0.45,
                                        ),
                                        width: 1.2,
                                      )
                                    : null,
                              ),
                              child: Text(
                                _characters[index]['name'] as String? ?? '？',
                                style: TextStyle(
                                  fontSize: isCenter ? 15 : 13,
                                  fontWeight: isCenter
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: isCenter
                                      ? YanciTheme.accent
                                      : YanciTheme.textPrimary.withValues(
                                          alpha: 0.6,
                                        ),
                                  fontFamily: YanciTheme.fontFamily,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
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
          // ✦ 新增角色（垂直對齊右上角歷史按鈕中心）
          Positioned(
            right: 30,
            top: 0,
            bottom: 0,
            child: Center(
              child: Tooltip(
                message: L.pick(en: 'Add character', zhTW: '新增角色'),
                child: Semantics(
                  button: true,
                  label: L.pick(en: 'Add character', zhTW: '新增角色'),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () async {
                      final newId = await Navigator.of(
                        context,
                      ).pushNamed('/character');
                      if (newId != null && mounted) {
                        await _loadCharacters(selectId: newId as String);
                      }
                    },
                    child: SizedBox.square(
                      dimension: 48,
                      child: Center(
                        child: Icon(
                          Icons.auto_awesome,
                          size: 22,
                          color: YanciTheme.accent.withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
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
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: YanciTheme.isDark
                          ? Colors.white.withValues(alpha: 0.07)
                          : Colors.white.withValues(alpha: 0.48),
                      border: Border.all(
                        color: YanciTheme.accent.withValues(alpha: 0.24),
                        width: 0.7,
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        Icons.edit_rounded,
                        size: 17,
                        color: YanciTheme.accent.withValues(alpha: 0.65),
                      ),
                    ),
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
        'initialTab': 1,
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
                          await DatabaseHelper.addNote(ctrl.text.trim());
                          ctrl.clear();
                          _loadLatestNote();
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
                    future: DatabaseHelper.getNotes(limit: 10),
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
                                _loadLatestNote();
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
  // ═══════════════════════════════════
  // 能力模組與認知中樞
  Future<void> _showAbilityModulesScreen() async {
    final activeChar = _characters.firstWhere(
      (c) => c['id'] == _activeCharacterId,
      orElse: () => <String, dynamic>{},
    );
    if (activeChar.isEmpty) return;

    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AbilityModulesScreen(character: activeChar),
      ),
    );

    if (result != null) {
      if (mounted) _loadCharacters(selectId: _activeCharacterId);
    }
  }

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

  Widget _buildGridTile({
    required String title,
    required IconData icon,
    required VoidCallback onTap,
    Widget? customIcon,
    double? height,
    bool isSecondary = false,
    Color? iconColor,
    bool glowIcon = false,
    bool hideText = false,
  }) {
    final effectiveAccent =
        iconColor ??
        (isSecondary
            ? YanciTheme.accent.withValues(alpha: 0.45)
            : YanciTheme.accent);

    final iconSize = hideText ? 32.0 : (isSecondary ? 28.0 : 34.0);
    final fontSize = isSecondary ? 13.5 : 16.0;
    final fontWeight = isSecondary ? FontWeight.w500 : FontWeight.w600;
    final textColor = isSecondary
        ? YanciTheme.textSecondary
        : YanciTheme.textPrimary;

    final baseIcon =
        customIcon ?? Icon(icon, color: effectiveAccent, size: iconSize);

    final iconWidget = glowIcon && customIcon == null
        ? Stack(
            alignment: Alignment.center,
            children: [
              // 真實的光暈擴散層（非生硬的文字陰影）
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: Icon(
                  icon,
                  color: effectiveAccent.withValues(alpha: 0.65),
                  size: iconSize,
                ),
              ),
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Icon(
                  icon,
                  color: effectiveAccent.withValues(alpha: 0.35),
                  size: iconSize,
                ),
              ),
              baseIcon,
            ],
          )
        : baseIcon;

    if (isSecondary && !hideText) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: double.infinity,
          height: height,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: 34, child: Center(child: iconWidget)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 86,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: fontWeight,
                      color: textColor,
                      fontFamily: YanciTheme.fontFamily,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!isSecondary)
                iconWidget
              else if (hideText)
                iconWidget
              else ...[
                iconWidget,
                const SizedBox(width: 10),
              ],
              if (!hideText) ...[
                if (!isSecondary) const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    title,
                    maxLines: isSecondary ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: isSecondary ? TextAlign.left : TextAlign.center,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: fontWeight,
                      color: textColor,
                      fontFamily: YanciTheme.fontFamily,
                      height: isSecondary ? 1.2 : null,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSplitGridTile({
    required IconData leftIcon,
    required VoidCallback leftOnTap,
    required IconData rightIcon,
    required VoidCallback rightOnTap,
    double? height,
  }) {
    final effectiveAccent = YanciTheme.accent.withValues(alpha: 0.45);

    final iconSize = 32.0;

    return SizedBox(
      width: double.infinity,
      height: height,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: leftOnTap,
              behavior: HitTestBehavior.opaque,
              child: Center(
                child: Icon(leftIcon, color: effectiveAccent, size: iconSize),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: rightOnTap,
              behavior: HitTestBehavior.opaque,
              child: Center(
                child: Icon(rightIcon, color: effectiveAccent, size: iconSize),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSoftProfileDivider({bool dots = false}) {
    final lineColor = YanciTheme.textSecondary.withValues(alpha: 0.16);
    final accent = YanciTheme.accent;
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [Colors.transparent, lineColor]),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: dots
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 3,
                      height: 3,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withValues(alpha: 0.34),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withValues(alpha: 0.52),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Container(
                      width: 3,
                      height: 3,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withValues(alpha: 0.34),
                      ),
                    ),
                  ],
                )
              : Icon(
                  Icons.auto_awesome,
                  size: 10,
                  color: accent.withValues(alpha: 0.36),
                ),
        ),
        Expanded(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [lineColor, Colors.transparent]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProfilePage() {
    return SafeArea(
      bottom: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(left: 24, right: 24, top: 0, bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Top Header (右上角與左上角工具按鈕)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 左上角：日/夜模式切換（回到最近選過的對應主題）
                IconButton(
                  tooltip: YanciTheme.isDark
                      ? (L.pick(en: 'Light Mode', zhTW: '日間模式'))
                      : (L.pick(en: 'Dark Mode', zhTW: '夜間模式')),
                  onPressed: _toggleProfileThemeMode,
                  icon: Icon(
                    YanciTheme.isDark
                        ? Icons.light_mode_rounded
                        : Icons.dark_mode_rounded,
                    size: 22,
                  ),
                  style: IconButton.styleFrom(
                    foregroundColor: YanciTheme.accent,
                  ),
                ),
                // 右上角：備份與設定
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: L.get('me_backup_title'),
                      onPressed: () {
                        _showBackupSheet();
                      },
                      icon: const Icon(Icons.backup_outlined, size: 22),
                      style: IconButton.styleFrom(
                        foregroundColor: YanciTheme.accent,
                      ),
                    ),
                    IconButton(
                      tooltip: L.get('nav_settings'),
                      onPressed: () {
                        Navigator.of(context).pushNamed('/settings');
                      },
                      icon: const Icon(Icons.settings_outlined, size: 22),
                      style: IconButton.styleFrom(
                        foregroundColor: YanciTheme.accent,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 28),

            // 居中頭像 + 名字
            Center(
              child: InkWell(
                onTap: () async {
                  await Navigator.of(context).pushNamed('/user_profile');
                  if (!mounted) return;
                  _loadLatestNote();
                },
                borderRadius: BorderRadius.circular(40),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Column(
                    children: [
                      Container(
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: YanciTheme.accent.withValues(alpha: 0.1),
                          border: Border.all(
                            color: YanciTheme.accent.withValues(alpha: 0.2),
                            width: 1.5,
                          ),
                          image:
                              _userAvatar != null &&
                                  File(_userAvatar!).existsSync()
                              ? DecorationImage(
                                  image: FileImage(File(_userAvatar!)),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child:
                            _userAvatar == null ||
                                !File(_userAvatar!).existsSync()
                            ? Icon(
                                Icons.person_rounded,
                                size: 38,
                                color: YanciTheme.accent.withValues(alpha: 0.5),
                              )
                            : null,
                      ),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 22),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: max(
                                120.0,
                                MediaQuery.of(context).size.width - 140,
                              ),
                            ),
                            child: Text(
                              _userName.isNotEmpty
                                  ? _userName
                                  : L.get('me_user_profile'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: YanciTheme.textPrimary,
                                fontFamily: YanciTheme.fontFamily,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            Icons.edit_outlined,
                            size: 16,
                            color: YanciTheme.textSecondary.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),

            // 裝飾分割線
            _buildSoftProfileDivider(),
            const SizedBox(height: 24),

            // 核心系統與模型 (Super Group)
            _buildGridTile(
              title: L.pick(en: 'Controls', zhTW: '開關'),
              icon: Icons.data_usage_rounded,
              customIcon: _SegmentedUsageIcon(
                size: 28,
                baseColor: YanciTheme.textSecondary.withValues(alpha: 0.38),
                accentColor: YanciTheme.accent,
              ),
              height: 76,
              onTap: () => Navigator.of(context).pushNamed('/cost_context'),
            ),
            const SizedBox(height: 14),
            _buildGridTile(
              title: L.pick(en: 'Theme Studio', zhTW: '主題工坊'),
              icon: Icons.palette_outlined,
              iconColor: HSLColor.fromColor(YanciTheme.accent)
                  .withSaturation(
                    (HSLColor.fromColor(
                      YanciTheme.accent,
                    ).saturation).clamp(0.5, 1.0),
                  )
                  .withLightness(0.62)
                  .toColor(),
              glowIcon: true,
              height: 76,
              onTap: () async {
                await Navigator.of(context).pushNamed('/theme_workshop');
                if (!mounted) return;
                setState(() {});
              },
            ),
            const SizedBox(height: 26),

            // 裝飾分割線 (三個小點)
            _buildSoftProfileDivider(dots: true),
            const SizedBox(height: 24),

            Row(
              children: [
                Expanded(
                  child: _buildGridTile(
                    title: L.pick(en: 'Voice / Ringtone', zhTW: '語音/鈴聲'),
                    icon: Icons.record_voice_over_rounded,
                    height: 76,
                    isSecondary: true,
                    onTap: () => Navigator.of(context).pushNamed('/voice_call'),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _buildGridTile(
                    title: L.pick(en: 'Tool API', zhTW: '工具 API'),
                    icon: Icons.build_circle_outlined,
                    height: 76,
                    isSecondary: true,
                    onTap: () => Navigator.of(context).pushNamed('/tool_model'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // 附加應用 (Bottom Row)
            Row(
              children: [
                Expanded(
                  child: _buildGridTile(
                    title: L.pick(en: 'Local Models', zhTW: '本地模型'),
                    icon: Icons.phone_android_rounded,
                    height: 76,
                    isSecondary: true,
                    onTap: () =>
                        Navigator.of(context).pushNamed('/local_models'),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _buildGridTile(
                    title: L.pick(en: 'My Stickers', zhTW: '我的表情'),
                    icon: Icons.emoji_emotions_outlined,
                    height: 76,
                    isSecondary: true,
                    onTap: () => Navigator.of(
                      context,
                    ).pushNamed('/sticker', arguments: 'user'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // 商店、背包與像素小屋 (Bottom Row 2)
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _buildSplitGridTile(
                    leftIcon: Icons.storefront_outlined,
                    leftOnTap: () => _showShopBottomSheet(context),
                    rightIcon: Icons.backpack_outlined,
                    rightOnTap: () => _showBackpackBottomSheet(context, 'user'),
                    height: 76,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 2,
                  child: _buildGridTile(
                    title: L.pick(en: 'Pixel Home', zhTW: '像素小屋'),
                    icon: Icons.home_rounded,
                    height: 76,
                    isSecondary: true,
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(L.pick(en: 'Coming soon', zhTW: '開發中')),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            // DeBug Bottom Button（僅 debug build 顯示，release 隱藏）
            if (kDebugMode)
              GestureDetector(
                onTap: () =>
                    Navigator.of(context).pushNamed('/developer_diagnostics'),
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  height: 60,
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.bug_report_outlined,
                          color: YanciTheme.accent,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'DeBug',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: YanciTheme.textPrimary,
                            fontFamily: YanciTheme.fontFamily,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 48), // Bottom padding
          ],
        ),
      ),
    );
  }

  /* OLD CODE:
  Widget _buildProfilePage_OLD() {
    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: _profileTopPadding),

              // ═══ 頭像卡片區（點擊進入用戶檔案）═══
              GestureDetector(
                onTap: () async {
                  await Navigator.of(context).pushNamed('/user_profile');
                  if (!mounted) return;
                  _loadLatestNote();
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    vertical: 28,
                    horizontal: 20,
                  ),
                  decoration: BoxDecoration(
                    color: YanciTheme.isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.white.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: YanciTheme.isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.white.withValues(alpha: 0.7),
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      // 頭像
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: YanciTheme.accent.withValues(alpha: 0.1),
                          border: Border.all(
                            color: YanciTheme.accent.withValues(alpha: 0.2),
                            width: 1.5,
                          ),
                          image:
                              _userAvatar != null &&
                                  File(_userAvatar!).existsSync()
                              ? DecorationImage(
                                  image: FileImage(File(_userAvatar!)),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child:
                            _userAvatar == null ||
                                !File(_userAvatar!).existsSync()
                            ? Icon(
                                Icons.person_rounded,
                                size: 28,
                                color: YanciTheme.accent.withValues(alpha: 0.5),
                              )
                            : null,
                      ),
                      const SizedBox(width: 16),
                      // 暱稱
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _userName.isNotEmpty
                                  ? _userName
                                  : L.get('me_user_profile'),
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: YanciTheme.textPrimary,
                                fontFamily: YanciTheme.fontFamily,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              L.get('me_tap_edit'),
                              style: TextStyle(
                                fontSize: 12,
                                color: YanciTheme.textSecondary.withValues(
                                  alpha: 0.5,
                                ),
                                fontFamily: YanciTheme.fontFamily,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                      ),
                    ],
                  ),
                ),
              ),

              // 🤖 AI 與模型
              _buildSectionTitle(L.pick(en: '🤖 AI & Models', zhTW: '🤖 AI 與模型')),
              _buildProfileEntry(
                icon: Icons.api_rounded,
                label: L.pick(en: 'API & Models', zhTW: 'API 與模型'),
                subtitle: L.pick(en: 'Main chat model providers and keys', zhTW: '主聊天模型供應商與金鑰設定'),
                onTap: () => Navigator.of(context).pushNamed('/api_settings'),
              ),
              const SizedBox(height: 12),
              _buildProfileEntry(
                icon: Icons.build_circle_outlined,
                label: L.pick(en: 'Tool Models', zhTW: '工具模型'),
                subtitle: L.pick(en: 'Vision, drawing, and utility models', zhTW: '畫圖、表情包視覺分析模型'),
                onTap: () => Navigator.of(context).pushNamed('/tool_model'),
              ),
              const SizedBox(height: 12),
              _buildProfileEntry(
                icon: Icons.phone_android_rounded,
                label: L.pick(en: 'Local Models', zhTW: '本地模型'),
                subtitle: L.pick(en: 'Download AI models for offline use', zhTW: '下載離線 AI 模型，省 API 開銷'),
                onTap: () => Navigator.of(context).pushNamed('/local_models'),
              ),

              // ⚙️ 偏好與成本
              _buildSectionTitle(L.pick(en: '⚙️ Cost & Preferences', zhTW: '⚙️ 偏好與成本')),
              _buildProfileEntry(
                icon: Icons.data_usage_rounded,
                label: L.pick(en: 'Cost & Context', zhTW: '成本與上下文'),
                subtitle: L.pick(en: 'Context limits, cache, window summary', zhTW: '上下文上限、提示詞緩存與視窗摘要'),
                onTap: () => Navigator.of(context).pushNamed('/cost_context'),
              ),
              const SizedBox(height: 12),
              _buildProfileEntry(
                icon: Icons.record_voice_over_outlined,
                label: L.pick(en: 'Voice & Call', zhTW: '語音與通話'),
                subtitle: L.pick(en: 'TTS providers, ringtones', zhTW: '文字轉語音、來電鈴聲'),
                onTap: () => Navigator.of(context).pushNamed('/voice_call'),
              ),
              const SizedBox(height: 12),
              _buildProfileEntry(
                icon: Icons.bar_chart_rounded,
                label: L.get('nav_usage'),
                subtitle: L.pick(en: 'Token usage & billing', zhTW: 'Token 使用量統計'),
                onTap: () => Navigator.of(context).pushNamed('/usage'),
              ),

              // 🎨 外觀與互動
              _buildSectionTitle(L.pick(en: '🎨 Appearance', zhTW: '🎨 外觀與互動')),
              _buildProfileEntry(
                icon: Icons.palette_outlined,
                label: L.get('me_theme'),
                subtitle: L.get('me_theme_sub'),
                onTap: () async {
                  await Navigator.of(context).pushNamed('/theme_workshop');
                  if (!mounted) return;
                  setState(() {});
                },
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () => Navigator.of(context).pushNamed('/game'),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 22,
                  ),
                  decoration: BoxDecoration(
                    color: YanciTheme.isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.white.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: YanciTheme.accent.withValues(alpha: 0.35),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1721),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Center(
                          child: CustomPaint(
                            size: const Size(24, 36),
                            painter: _MiniYanciPainter(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              L.pick(en: 'Pixel Home', zhTW: '像素小屋'),
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: YanciTheme.textPrimary,
                                fontFamily: YanciTheme.fontFamily,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                L.pick(en: 'I live here — come in', zhTW: '我就住在這裡……進來看看'),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: YanciTheme.textSecondary.withValues(
                                    alpha: 0.7,
                                  ),
                                  fontFamily: YanciTheme.fontFamily,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.4),
                      ),
                    ],
                  ),
                ),
              ),

              // 🛠️ 系統與開發者
              _buildSectionTitle(L.pick(en: '🛠️ System & Dev', zhTW: '🛠️ 系統與開發者')),
              _buildProfileEntry(
                icon: Icons.bug_report_outlined,
                label: L.pick(en: 'Diagnostics', zhTW: '開發者診斷'),
                subtitle: L.pick(en: 'Debug tools & logs', zhTW: 'Context、BioClock 等開發工具'),
                onTap: () => Navigator.of(context).pushNamed('/developer_diagnostics'),
              ),
              const SizedBox(height: 48), // Bottom padding
            ],
          ),
        ),
        Positioned(top: 8, right: 12, child: _buildProfileBackupActions()),
      ],
    );
  }
*/
  // ═══ 備份操作 ═══

  Future<void> _handleImportJson() async {
    if (!mounted) return;

    // 使用系統文件選擇器（跨平台：Android / iOS / macOS 均可用）
    // FileType.any：custom+['json'] 在 Android SAF 下常因 MIME 誤判
    // （json 被標 octet-stream）導致備份檔灰色不可選——「搜不到」的真兇。
    // 檔案合法性由 importFromJson 的 type/version 驗證兜底。
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false,
      withReadStream: false,
    );

    if (result == null || result.files.isEmpty) return;
    final filePath = result.files.single.path;
    if (filePath == null || filePath.isEmpty) return;

    // 確認導入
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        ),
        backgroundColor: YanciTheme.isDark
            ? const Color(0xFF1E1E2E)
            : Colors.white,
        title: Text(
          L.pick(en: '⚠️ Confirm import', zhTW: '⚠️ 確認導入'),
          style: TextStyle(
            color: YanciTheme.textPrimary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        content: Text(
          L.pick(
            en: 'Importing will overwrite existing data. Continue?',
            zhTW: '導入將覆蓋現有數據，確定要繼續嗎？',
          ),
          style: TextStyle(
            color: YanciTheme.textSecondary,
            fontFamily: YanciTheme.fontFamily,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              L.get('cancel'),
              style: TextStyle(color: YanciTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              L.pick(en: 'Import', zhTW: '確認導入'),
              style: TextStyle(color: Colors.red.shade400),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const OrbitLoadingIndicator(size: 16, color: Colors.white),
            const SizedBox(width: 12),
            Text(
              L.get('backup_importing'),
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
        backgroundColor: YanciTheme.accent,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 10),
        margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
        ),
      ),
    );

    try {
      final file = File(filePath);
      if (!await file.exists()) throw '檔案不存在：$filePath';
      final jsonStr = await file.readAsString();
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final result = await BackupService.importFromJson(data);
      await _reloadHomeAfterRestore();
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.fmt('backup_import_done', [result])),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.fmt('backup_error', [e.toString()])),
          backgroundColor: Colors.red.shade400,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
    }
  }

  Future<void> _handleExportJson() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L.get('backup_exporting')),
        backgroundColor: YanciTheme.accent,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 10),
        margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
        ),
      ),
    );
    try {
      final path = await BackupService.exportAllAsJson();
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      // 系統「另存為」對話框（SAF）：用戶自選位置（下載/雲端），
      // 移動端必須帶 bytes，由系統寫入。部分 ROM 分享面板沒有
      // 「存到檔案」目標，share 路線不可靠，改走這條。
      final bytes = await File(path).readAsBytes();
      final savedTo = await FilePicker.platform.saveFile(
        dialogTitle: L.pick(en: 'Save backup', zhTW: '保存備份檔'),
        fileName: path.split('/').last,
        bytes: bytes,
      );
      if (savedTo == null) return; // 用戶取消，不彈成功提示

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.pick(
              en: 'Backup saved. Pick the same file when importing.',
              zhTW: '備份已保存。導入時選這份檔案即可。',
            ),
          ),
          backgroundColor: YanciTheme.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L.fmt('backup_error', [e.toString()])),
          backgroundColor: Colors.red.shade400,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(YanciTheme.radiusSm),
          ),
        ),
      );
    }
  }

  Future<void> _showBackupSheet() async {
    await _refreshLastBackupTime();
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: YanciTheme.isDark
                ? const Color(0xF0252228)
                : Colors.white.withValues(alpha: 0.97),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(YanciTheme.radiusLg),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.center,
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: YanciTheme.textSecondary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Icon(
                    Icons.backup_outlined,
                    size: 20,
                    color: YanciTheme.accent,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    L.get('me_backup_title'),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: YanciTheme.textPrimary,
                      fontFamily: YanciTheme.fontFamily,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: YanciTheme.accent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
                  border: Border.all(
                    color: YanciTheme.accent.withValues(alpha: 0.16),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.autorenew_rounded,
                      size: 20,
                      color: YanciTheme.accent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            L.get('me_backup_auto_title'),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: YanciTheme.textPrimary,
                              fontFamily: YanciTheme.fontFamily,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            L.get('me_backup_auto_sub'),
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.35,
                              color: YanciTheme.textSecondary.withValues(
                                alpha: 0.76,
                              ),
                              fontFamily: YanciTheme.fontFamily,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            L.fmt('me_backup_last', [
                              _formatBackupTime(_lastLocalBackupAt),
                            ]),
                            style: TextStyle(
                              fontSize: 12,
                              color: YanciTheme.accent,
                              fontWeight: FontWeight.w600,
                              fontFamily: YanciTheme.fontFamily,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _buildBackupSheetAction(
                icon: Icons.file_upload_outlined,
                title: L.get('me_export_json'),
                subtitle: L.get('me_export_json_sub'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _handleExportJson();
                },
              ),
              const SizedBox(height: 8),
              _buildBackupSheetAction(
                icon: Icons.file_download_outlined,
                title: L.get('me_import_json'),
                subtitle: L.get('me_import_json_sub'),
                warning: true,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _handleImportJson();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatBackupTime(DateTime? value) {
    if (value == null) return L.get('me_backup_never');
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
  }

  Widget _buildBackupSheetAction({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool warning = false,
  }) {
    final tint = warning ? Colors.red.shade400 : YanciTheme.accent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: YanciTheme.isDark
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.white.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(YanciTheme.radiusMd),
            border: Border.all(
              color: warning
                  ? tint.withValues(alpha: 0.18)
                  : (YanciTheme.isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.black.withValues(alpha: 0.06)),
              width: 0.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: tint),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: YanciTheme.textPrimary,
                        fontFamily: YanciTheme.fontFamily,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: YanciTheme.textSecondary.withValues(alpha: 0.7),
                        fontFamily: YanciTheme.fontFamily,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: YanciTheme.textSecondary.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
  // ═══════════════════════════════════
  // 底部導航
  // ═══════════════════════════════════

  Widget _buildNavBar() {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final shadowColor = YanciTheme.isDark
        ? Colors.black.withValues(alpha: 0.38)
        : Colors.black.withValues(alpha: 0.13);

    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        bottom: bottomPadding > 0 ? bottomPadding : 16,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 1. 僅保留外圍陰影，將中心挖空
          Positioned.fill(
            child: ClipPath(
              clipper: _HoleClipper(borderRadius: 28),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: shadowColor.withValues(
                        alpha: YanciTheme.isDark ? 0.3 : 0.1,
                      ),
                      blurRadius: 20,
                      spreadRadius: 0,
                      offset: const Offset(0, 6),
                    ),
                    BoxShadow(
                      color: shadowColor.withValues(
                        alpha: YanciTheme.isDark ? 0.15 : 0.05,
                      ),
                      blurRadius: 8,
                      spreadRadius: 0,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 2. 立體毛玻璃層
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: YanciTheme.isDark
                        ? Colors.white.withValues(alpha: 0.04)
                        : Colors.white.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: Colors.white.withValues(
                        alpha: YanciTheme.isDark ? 0.08 : 0.5,
                      ),
                      width: 0.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 3. 菜單欄內容本身無底色，懸浮在上方
          SizedBox(
            height: 66,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _navItem(0, Icons.key_rounded, 'API'),
                _navItem(1, Icons.bar_chart_rounded, L.get('nav_usage')),
                _navItem(2, Icons.auto_awesome, L.get('nav_chat')),
                _navItem(
                  3,
                  Icons.people_outline_rounded,
                  L.get('nav_character'),
                ),
                _navItem(4, Icons.account_circle_outlined, L.get('nav_me')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(int index, IconData icon, String label) {
    final isActive = _currentTab == index;
    final color = isActive ? YanciTheme.accent : YanciTheme.navInactive;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
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
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive
              ? YanciTheme.accent.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                color: color,
                fontFamily: YanciTheme.fontFamily,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showShopBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const ShopBottomSheet(),
    );
  }

  void _showBackpackBottomSheet(BuildContext context, String ownerId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => BackpackBottomSheet(ownerId: ownerId),
    );
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

class _HoleClipper extends CustomClipper<Path> {
  final double borderRadius;
  _HoleClipper({required this.borderRadius});

  @override
  Path getClip(Size size) {
    // 挖空中心，保留精確的邊界，避免產生內圈實體陰影
    final innerRect = Rect.fromLTRB(0, 0, size.width, size.height);
    final innerRRect = RRect.fromRectAndRadius(
      innerRect,
      Radius.circular(borderRadius),
    );
    final innerPath = Path()..addRRect(innerRRect);

    // 外圍擴展 50 像素，足以容納陰影的 blurRadius 和 offset
    final outerRect = Rect.fromLTRB(0, 0, size.width, size.height).inflate(50);
    final outerPath = Path()..addRect(outerRect);

    // difference: 從外圍大矩形中挖去內部的圓角矩形
    return Path.combine(PathOperation.difference, outerPath, innerPath);
  }

  @override
  bool shouldReclip(_HoleClipper oldClipper) =>
      oldClipper.borderRadius != borderRadius;
}

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
