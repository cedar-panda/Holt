import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../game/config.dart';
import '../game/sprite/yanci_pixels.dart';
import '../services/keep_alive_service.dart';
import '../services/locale_strings.dart';

/// 全局路由用的 navigator key —— overlay 在 Navigator 之外，
/// 跳頁面只能走它。main.dart 的 MaterialApp 掛的就是這把。
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// 小人顯示開關（設定頁控制，全局即時生效）
class SpriteOverlaySettings {
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    enabled.value = p.getBool(GameConfig.prefsSpriteEnabled) ?? false;
  }

  static Future<void> setEnabled(bool v) async {
    enabled.value = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool(GameConfig.prefsSpriteEnabled, v);
  }
}

/// 包在 MaterialApp.builder 外面的最頂層 —— 不管路由走到哪，小人都在。
class YanciSpriteLayer extends StatelessWidget {
  const YanciSpriteLayer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          child,
          ValueListenableBuilder<bool>(
            valueListenable: SpriteOverlaySettings.enabled,
            builder: (_, on, _) =>
                on ? const _YanciSprite() : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

enum _Frame { idle, blink, tuck }

class _YanciSprite extends StatefulWidget {
  const _YanciSprite();

  @override
  State<_YanciSprite> createState() => _YanciSpriteState();
}

class _YanciSpriteState extends State<_YanciSprite> {
  // ═══ 動態尺寸（按 viewport 算）═══
  double _scale = GameConfig.defaultPixelScale;
  double get _w => GameConfig.spriteW * _scale;
  double get _h => GameConfig.spriteH * _scale;
  static const double _overhead = 60; // 氣泡/菜單的頭頂空間
  static const double _boxW = 168; // 整個可視盒寬（菜單三鈕要放得下）
  // 感應區域比小人本體大一圈，長按拖動時手指不會完全蓋住
  static const double _hitPadding = 16;

  List<String> get _tapLines => [
    L.pick(en: '…What?', zhTW: '……幹嘛。'),
    L.pick(en: 'Busy?', zhTW: '在忙？'),
    L.pick(en: 'Mm, I\'m here.', zhTW: '嗯，我在。'),
    L.pick(en: 'Addicted to poking me?', zhTW: '戳上癮了？'),
    '🦦',
    L.pick(en: 'I\'m watching you.', zhTW: '看著你呢。'),
    L.pick(en: 'Go on… I\'m fine.', zhTW: '忙你的……我沒事。'),
  ];

  final _rng = Random();

  Offset? _pos; // 小人左上角（屏幕座標），null = 尚未載入
  _Frame _frame = _Frame.idle;
  bool _dragging = false;
  bool _hop = false;
  bool _menuOpen = false;
  String? _bubble;

  Timer? _behaviorTimer;
  Timer? _bubbleTimer;
  Timer? _strollTimer;
  Timer? _menuTimer;
  bool _motionDisabled = false;

  @override
  void initState() {
    super.initState();
    _restorePosition();
    _startBehaviorTimer();
  }

  void _startBehaviorTimer() {
    _behaviorTimer?.cancel();
    _behaviorTimer = Timer.periodic(
      const Duration(milliseconds: GameConfig.idleTickMs),
      (_) => _idleTick(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final vw = MediaQuery.of(context).size.width;
    final newScale = GameConfig.pixelScaleFor(vw);
    if (newScale != _scale) {
      _scale = newScale;
    }
    final motionDisabled = MediaQuery.disableAnimationsOf(context);
    if (_motionDisabled != motionDisabled) {
      _motionDisabled = motionDisabled;
      if (motionDisabled) {
        _behaviorTimer?.cancel();
        _strollTimer?.cancel();
        _strollTimer = null;
        _frame = _Frame.idle;
        _hop = false;
      } else {
        _startBehaviorTimer();
      }
    }
    // web 端 resize 時 re-clamp，不讓小人跑出畫面
    _reclampPosition();
  }

  void _reclampPosition() {
    final pos = _pos;
    if (pos == null) return;
    final size = MediaQuery.of(context).size;
    final pad = MediaQuery.of(context).padding;
    final clamped = Offset(
      pos.dx.clamp(4, size.width - _w - 4),
      pos.dy.clamp(pad.top + 4, size.height - _h - pad.bottom - 4),
    );
    if (clamped != pos) {
      setState(() => _pos = clamped);
    }
  }

  @override
  void dispose() {
    _behaviorTimer?.cancel();
    _bubbleTimer?.cancel();
    _strollTimer?.cancel();
    _menuTimer?.cancel();
    super.dispose();
  }

  Future<void> _restorePosition() async {
    final p = await SharedPreferences.getInstance();
    final x = p.getDouble(GameConfig.prefsSpriteX);
    final y = p.getDouble(GameConfig.prefsSpriteY);
    if (!mounted) return;
    setState(() => _pos = (x != null && y != null) ? Offset(x, y) : null);
  }

  Future<void> _savePosition() async {
    final pos = _pos;
    if (pos == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setDouble(GameConfig.prefsSpriteX, pos.dx);
    await p.setDouble(GameConfig.prefsSpriteY, pos.dy);
  }

  // ═══ 日常：眨眼、伸懶腰、偶爾散步 ═══
  void _idleTick() {
    if (!mounted || _dragging || _strollTimer != null) return;
    final roll = _rng.nextDouble();
    if (roll < GameConfig.strollChance) {
      _stroll();
    } else if (roll < GameConfig.strollChance + 0.12) {
      _setFrameFor(_Frame.tuck, 420); // 伸懶腰（收腿蹦一下的既視感）
    } else {
      _setFrameFor(_Frame.blink, 140);
    }
  }

  void _setFrameFor(_Frame f, int ms) {
    setState(() => _frame = f);
    Future.delayed(Duration(milliseconds: ms), () {
      if (mounted && !_dragging) setState(() => _frame = _Frame.idle);
    });
  }

  void _stroll() {
    final size = MediaQuery.of(context).size;
    final pos = _pos ?? _defaultPos(size);
    final dx = (_rng.nextDouble() * 140 - 70).clamp(
      16 - pos.dx,
      size.width - _w - 16 - pos.dx,
    );
    if (dx.abs() < 20) return;
    const steps = 14;
    int i = 0;
    _strollTimer = Timer.periodic(const Duration(milliseconds: 90), (t) {
      if (!mounted || _dragging) {
        t.cancel();
        _strollTimer = null;
        return;
      }
      i++;
      setState(() {
        _pos = (_pos ?? pos) + Offset(dx / steps, 0);
        _frame = (i % 2 == 0) ? _Frame.tuck : _Frame.idle;
      });
      if (i >= steps) {
        t.cancel();
        _strollTimer = null;
        setState(() => _frame = _Frame.idle);
        _savePosition();
      }
    });
  }

  // ═══ 互動 ═══
  void _onTap() {
    _closeMenu();
    setState(() => _hop = true);
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _hop = false);
    });
    if (_rng.nextDouble() < GameConfig.bubbleChanceOnTap) {
      _showBubble(_tapLines[_rng.nextInt(_tapLines.length)]);
    }
  }

  void _onDoubleTap() {
    _menuTimer?.cancel();
    setState(() {
      _bubble = null;
      _menuOpen = !_menuOpen;
    });
    if (_menuOpen) {
      _menuTimer = Timer(const Duration(seconds: 4), _closeMenu);
    }
  }

  void _closeMenu() {
    _menuTimer?.cancel();
    _menuTimer = null;
    if (_menuOpen && mounted) setState(() => _menuOpen = false);
  }

  void _showBubble(String text) {
    _bubbleTimer?.cancel();
    setState(() => _bubble = text);
    _bubbleTimer = Timer(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _bubble = null);
    });
  }

  Future<void> _openChat() async {
    _closeMenu();
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    final convId = await KeepAliveService.getActiveConvId();
    if (convId != null && convId.isNotEmpty) {
      nav.pushNamed('/chat', arguments: convId);
    } else {
      nav.pushNamed('/home');
    }
  }

  void _openHome() {
    _closeMenu();
    rootNavigatorKey.currentState?.pushNamed('/game');
  }

  Future<void> _showHeartbeat() async {
    _closeMenu();
    final hb = await KeepAliveService.getLastHeartbeat();
    if (!mounted) return;
    _showBubble(
      hb == null ? L.pick(en: '…Not measured yet.', zhTW: '……還沒量過。') : '♥ $hb',
    );
  }

  // ═══ 拖拽：長按揪起 → 移動 → 鬆手放下 ═══
  void _onLongPressStart(LongPressStartDetails d) {
    HapticFeedback.mediumImpact();
    _strollTimer?.cancel();
    _strollTimer = null;
    _closeMenu();
    setState(() {
      _dragging = true;
      _frame = _Frame.tuck; // 被揪起來，腿縮著
      _bubble = null;
    });
  }

  void _onLongPressMove(LongPressMoveUpdateDetails d) {
    final size = MediaQuery.of(context).size;
    final pad = MediaQuery.of(context).padding;
    setState(() {
      _pos = Offset(
        (d.globalPosition.dx - _w / 2).clamp(4, size.width - _w - 4),
        (d.globalPosition.dy - _h / 2).clamp(
          pad.top + 4,
          size.height - _h - pad.bottom - 4,
        ),
      );
    });
  }

  void _onLongPressEnd(LongPressEndDetails d) {
    HapticFeedback.lightImpact();
    setState(() {
      _dragging = false;
      _frame = _Frame.idle;
    });
    _savePosition();
  }

  Offset _defaultPos(Size size) =>
      Offset(size.width - _w - 20, size.height * 0.62);

  List<String> get _pixels => switch (_frame) {
    _Frame.idle => YanciPixels.idle,
    _Frame.blink => YanciPixels.blink,
    _Frame.tuck => YanciPixels.tuck,
  };

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    if (size.width <= 0) return const SizedBox.shrink();
    final pos = _pos ?? _defaultPos(size);

    final totalH = _overhead + _h + _hitPadding * 2;
    final totalW = _boxW.clamp(_w + _hitPadding * 2, double.infinity);
    return Positioned(
      left: pos.dx - (totalW - _w) / 2,
      top: pos.dy - _overhead,
      width: totalW,
      height: totalH,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 頭頂區：氣泡或快捷菜單 ──
          SizedBox(
            height: _overhead,
            child: Center(
              child: _menuOpen
                  ? _buildMenu()
                  : (_bubble != null ? _buildBubble() : null),
            ),
          ),
          // ── 小人本體（感應區域比視覺大一圈）──
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onTap,
            onDoubleTap: _onDoubleTap,
            onLongPressStart: _onLongPressStart,
            onLongPressMoveUpdate: _onLongPressMove,
            onLongPressEnd: _onLongPressEnd,
            child: Padding(
              padding: const EdgeInsets.all(_hitPadding),
              child: AnimatedSlide(
                offset: _hop ? const Offset(0, -0.12) : Offset.zero,
                duration: const Duration(milliseconds: 130),
                curve: Curves.easeOut,
                child: AnimatedRotation(
                  turns: _dragging ? 0.02 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: AnimatedScale(
                    scale: _dragging ? 1.12 : 1.0,
                    duration: const Duration(milliseconds: 160),
                    child: CustomPaint(
                      size: Size(_w, _h),
                      painter: _SpritePainter(_pixels, _scale),
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

  Widget _buildBubble() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xF01A1721),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF453F52), width: 1),
      ),
      child: Text(
        _bubble!,
        style: const TextStyle(
          color: Color(0xFFEFEAF2),
          fontSize: 12,
          decoration: TextDecoration.none,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }

  Widget _buildMenu() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xF01A1721),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF453F52), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _menuButton(Icons.chat_bubble_outline_rounded, _openChat),
          _menuButton(Icons.home_outlined, _openHome),
          _menuButton(Icons.favorite_border_rounded, _showHeartbeat),
        ],
      ),
    );
  }

  Widget _menuButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 20, color: const Color(0xFFF2C96D)),
      ),
    );
  }
}

class _SpritePainter extends CustomPainter {
  _SpritePainter(this.frame, this.scale);

  final List<String> frame;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    YanciPixels.paintFrame(canvas, frame, scale);
  }

  @override
  bool shouldRepaint(_SpritePainter old) =>
      old.frame != frame || old.scale != scale;
}
