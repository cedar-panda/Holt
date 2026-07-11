import 'dart:math';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';

import 'config.dart';
import 'sprite/yanci_pixels.dart';

/// Holt 像素小屋 —— M1 骨架。
///
/// 現在：代碼畫的佔位房間（米白地板 + 格線）+ 佔位角色在裡面溜達。
/// M2：flame_tiled 換真地圖，ScheduleBridge 接管他去哪。
/// M3：EmotionBridge 接管表情。
/// 遊戲層規矩（規劃表 表五）：不碰 DB、不 await 網絡，數據只從 bridge 進。
class HoltGame extends FlameGame with TapCallbacks {
  static const _floor = Color(0xFFD6C3AB); // 米白
  static const _grid = Color(0xFFA89484); // 米灰
  static const _wall = Color(0xFF7A6A5E); // 暖灰

  late final YanciNpc _yanci;
  late final double _scale;

  @override
  Color backgroundColor() => const Color(0xFF1A1721); // 夜墨

  @override
  Future<void> onLoad() async {
    _scale = GameConfig.pixelScaleFor(canvasSize.x);
    final tile = GameConfig.tileSize * _scale;
    final worldW = GameConfig.mapCols * tile;
    final worldH = GameConfig.mapRows * tile;

    add(_PlaceholderRoom(size: Vector2(worldW, worldH), tilePx: tile));

    _yanci = YanciNpc(
      roomSize: Vector2(worldW, worldH),
      position: Vector2(worldW / 2, worldH / 2),
      scale_: _scale,
    );
    add(_yanci);

    // 相機看房間中心，整數倍縮放保像素
    camera.viewfinder.anchor = Anchor.center;
    camera.viewfinder.position = Vector2(worldW / 2, worldH / 2);
  }

  @override
  void onTapUp(TapUpEvent event) {
    // 點地板 → 他走過去（M1 的全部互動）
    final target = event.localPosition;
    _yanci.walkTo(target);
  }

  double get tilePx => GameConfig.tileSize * _scale;

  // 供房間繪製使用
  static Color get floorColor => _floor;
  static Color get gridColor => _grid;
  static Color get wallColor => _wall;
}

/// 佔位房間：地板 + 格線 + 一圈牆。Tiled 地圖就位後整個刪掉。
class _PlaceholderRoom extends PositionComponent {
  _PlaceholderRoom({required Vector2 size, required this.tilePx})
    : super(size: size, priority: 0);

  final double tilePx;

  @override
  void render(Canvas canvas) {
    final tile = tilePx;
    final paint = Paint()..filterQuality = FilterQuality.none;

    paint.color = HoltGame.floorColor;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), paint);

    paint.color = HoltGame.gridColor.withValues(alpha: 0.35);
    for (double x = 0; x <= size.x; x += tile) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.y), paint);
    }
    for (double y = 0; y <= size.y; y += tile) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.x, 1), paint);
    }

    paint.color = HoltGame.wallColor;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, tile / 2), paint);
    canvas.drawRect(
      Rect.fromLTWH(0, size.y - tile / 2, size.x, tile / 2),
      paint,
    );
    canvas.drawRect(Rect.fromLTWH(0, 0, tile / 2, size.y), paint);
    canvas.drawRect(
      Rect.fromLTWH(size.x - tile / 2, 0, tile / 2, size.y),
      paint,
    );
  }
}

/// 佔位角色：待機眨眼 + 隨機溜達 + 點地板走過去。
/// 素材就位後：渲染換 SpriteAnimationGroupComponent，狀態機不變。
class YanciNpc extends PositionComponent {
  YanciNpc({
    required this.roomSize,
    required Vector2 position,
    required double scale_,
  }) : _scale = scale_,
       super(
         position: position,
         size: Vector2(
           GameConfig.spriteW * scale_,
           GameConfig.spriteH * scale_,
         ),
         anchor: Anchor.bottomCenter,
         priority: 10,
       );

  final Vector2 roomSize;
  final double _scale;
  final _rng = Random();

  Vector2? _target;
  double _speed = 90; // 邏輯像素/秒
  double _blinkTimer = 0;
  double _decideTimer = 3;
  double _stepPhase = 0;
  bool _blinking = false;

  double get _tilePx => GameConfig.tileSize * _scale;

  void walkTo(Vector2 target) {
    final tile = _tilePx;
    _target = Vector2(
      target.x.clamp(tile, roomSize.x - tile),
      target.y.clamp(tile * 1.5, roomSize.y - tile / 2),
    );
  }

  @override
  void update(double dt) {
    super.update(dt);

    // 眨眼節奏
    _blinkTimer -= dt;
    if (_blinkTimer <= 0) {
      _blinking = !_blinking;
      _blinkTimer = _blinking ? 0.12 : 2.2 + _rng.nextDouble() * 2.5;
    }

    final target = _target;
    if (target != null) {
      final delta = target - position;
      final dist = delta.length;
      if (dist < 3) {
        _target = null;
        _stepPhase = 0;
      } else {
        position += delta.normalized() * (_speed * dt).clamp(0, dist);
        _stepPhase += dt * 8;
      }
    } else {
      // 沒目標：偶爾自己找地方溜達
      _decideTimer -= dt;
      if (_decideTimer <= 0) {
        _decideTimer = 3 + _rng.nextDouble() * 5;
        if (_rng.nextDouble() < 0.5) {
          final tile = _tilePx;
          walkTo(
            Vector2(
              tile + _rng.nextDouble() * (roomSize.x - tile * 2),
              tile * 1.5 + _rng.nextDouble() * (roomSize.y - tile * 2),
            ),
          );
          _speed = 70 + _rng.nextDouble() * 50;
        }
      }
    }
  }

  @override
  void render(Canvas canvas) {
    // 走路 = tuck / idle 交替的蹦跳步；停下 = idle + 眨眼
    final walking = _target != null;
    final frame = walking
        ? ((_stepPhase.floor() % 2 == 0) ? YanciPixels.tuck : YanciPixels.idle)
        : (_blinking ? YanciPixels.blink : YanciPixels.idle);

    // 座標取整（像素三件套之二）
    canvas.save();
    canvas.translate(
      position.x.roundToDouble() - position.x,
      position.y.roundToDouble() - position.y,
    );
    YanciPixels.paintFrame(canvas, frame, _scale);
    canvas.restore();
  }
}
