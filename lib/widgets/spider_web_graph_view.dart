import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../memory/spider_web_core.dart';
import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

const double _canvasSize = 3200.0;
const double _canvasCenter = _canvasSize / 2;
const double _graphRadius = 1180.0;

class _Node {
  final Map<String, dynamic> data;
  double x;
  double y;
  double vx = 0;
  double vy = 0;
  bool isDragged = false;
  final double clarity;
  final int mentionCount;
  final String category;

  _Node({
    required this.data,
    required this.x,
    required this.y,
    required this.clarity,
    required this.mentionCount,
    required this.category,
  });

  double get tapRadius => 24 + mentionCount.clamp(0, 8).toDouble();
}

class _Edge {
  final _Node source;
  final _Node target;

  _Edge(this.source, this.target);
}

class SpiderWebGraphView extends StatefulWidget {
  final List<Map<String, dynamic>> memories;
  final List<Map<String, dynamic>> links;
  final void Function(Map<String, dynamic> memory) onNodeTapped;

  const SpiderWebGraphView({
    super.key,
    required this.memories,
    required this.links,
    required this.onNodeTapped,
  });

  @override
  State<SpiderWebGraphView> createState() => _SpiderWebGraphViewState();
}

class _SpiderWebGraphViewState extends State<SpiderWebGraphView>
    with TickerProviderStateMixin {
  final TransformationController _transformationController =
      TransformationController();

  late final AnimationController _animationController;
  late Animation<Matrix4> _animation;
  late final Ticker _physicsTicker;

  List<_Node> _nodes = [];
  List<_Edge> _edges = [];
  String _graphSignature = '';
  _Node? _draggedNode;
  Size? _viewSize;
  bool _hasAnimated = false;

  // ═══ 環境動畫時鐘（呼吸/流光/漣漪/入場）═══
  double _timeSec = 0;
  DateTime _spawnAt = DateTime.now();
  Duration _lastVisualTick = Duration.zero;
  final List<_Ripple> _ripples = [];

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _physicsTicker = createTicker(_tick)..start();
    _initGraph();
  }

  @override
  void didUpdateWidget(SpiderWebGraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextSignature = _signatureFor(widget.memories, widget.links);
    if (nextSignature != _graphSignature) {
      _initGraph();
      _hasAnimated = false;
    }
  }

  @override
  void dispose() {
    _physicsTicker.dispose();
    _animationController.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  /// 模擬溫度：1.0 → 逐幀降溫 → <0.02 物理凍結（節點釘住不再飄）。
  /// 開新圖時滿溫重排；拖拽釋放時局部回溫讓鄰居讓位後再靜下來。
  double _simAlpha = 1.0;

  void _tick(Duration elapsed) {
    if (_nodes.isEmpty) return;

    // ═══ 環境動畫時鐘（呼吸/流光/漣漪永遠走，與物理無關）═══
    _timeSec = elapsed.inMicroseconds / 1e6;
    _ripples.removeWhere(
      (r) => DateTime.now().difference(r.at).inMilliseconds > _Ripple.lifeMs,
    );

    // ═══ 物理已冷卻：只維持低頻視覺重繪，節點釘住 ═══
    if (_simAlpha < 0.02 && _draggedNode == null) {
      if ((elapsed - _lastVisualTick).inMilliseconds >= 66 && mounted) {
        _lastVisualTick = elapsed;
        setState(() {});
      }
      return;
    }

    // Physics parameters for "沉穩微調" (stable & viscous)
    const double repulsionK = 450000.0;
    const double springK = 0.008;
    const double springLength = 160.0;
    const double damping = 0.55;
    const double gravityK = 0.00012;

    final forces = List.generate(_nodes.length, (_) => [0.0, 0.0]);

    // Repulsion
    for (int i = 0; i < _nodes.length; i++) {
      for (int j = i + 1; j < _nodes.length; j++) {
        final n1 = _nodes[i];
        final n2 = _nodes[j];
        final dx = n1.x - n2.x;
        final dy = n1.y - n2.y;
        double distSq = dx * dx + dy * dy;
        if (distSq < 10.0) distSq = 10.0;
        final f = repulsionK / distSq;
        final dist = sqrt(distSq);
        final fx = (dx / dist) * f;
        final fy = (dy / dist) * f;

        forces[i][0] += fx;
        forces[i][1] += fy;
        forces[j][0] -= fx;
        forces[j][1] -= fy;
      }
    }

    // Spring (Edges)
    for (final edge in _edges) {
      final n1 = edge.source;
      final n2 = edge.target;
      final dx = n2.x - n1.x;
      final dy = n2.y - n1.y;
      final dist = sqrt(dx * dx + dy * dy);
      if (dist > 0) {
        final f = (dist - springLength) * springK;
        final fx = (dx / dist) * f;
        final fy = (dy / dist) * f;

        final i = _nodes.indexOf(n1);
        final j = _nodes.indexOf(n2);
        forces[i][0] += fx;
        forces[i][1] += fy;
        forces[j][0] -= fx;
        forces[j][1] -= fy;
      }
    }

    // Gravity & Boundary
    for (int i = 0; i < _nodes.length; i++) {
      final n = _nodes[i];
      forces[i][0] -= n.x * gravityK;
      forces[i][1] -= n.y * gravityK;

      // Boundary enforcement: acts like a strong invisible elastic net
      // Expanded boundary to allow nodes to explore the larger web
      final maxNodeRadius = 1400.0;
      final dist = sqrt(n.x * n.x + n.y * n.y);
      if (dist > maxNodeRadius) {
        final push = (dist - maxNodeRadius) * 0.08;
        forces[i][0] -= (n.x / dist) * push;
        forces[i][1] -= (n.y / dist) * push;
      }
    }

    bool needsRepaint = false;
    for (int i = 0; i < _nodes.length; i++) {
      final n = _nodes[i];
      if (n.isDragged) continue;

      // 力乘溫度：降溫過程中推力漸弱，網「織好就定形」，不再永久漂移
      n.vx = (n.vx + forces[i][0] * _simAlpha) * damping;
      n.vy = (n.vy + forces[i][1] * _simAlpha) * damping;

      if (n.vx.abs() > 0.05 || n.vy.abs() > 0.05) {
        n.x += n.vx;
        n.y += n.vy;
        needsRepaint = true;
      }
    }

    // 降溫（~4 秒冷卻）；拖拽中保持熱度讓鄰居持續讓位
    if (_draggedNode == null) {
      _simAlpha *= 0.988;
    }

    // ═══ 環境動畫：低頻心跳兜底（~15fps）═══
    if (!needsRepaint && (elapsed - _lastVisualTick).inMilliseconds >= 66) {
      needsRepaint = true;
    }

    if (needsRepaint && mounted) {
      _lastVisualTick = elapsed;
      setState(() {});
    }
  }

  void _startEntryAnimation() {
    if (!mounted || widget.memories.isEmpty || _viewSize == null) return;

    final size = _viewSize!;
    final startScale = 0.42;
    final endScale = _nodes.length <= 8 ? 0.88 : 0.72;

    Matrix4 centeredMatrix(double scale) {
      final tx = size.width / 2 - _canvasCenter * scale;
      final ty = size.height / 2 - _canvasCenter * scale;
      // translate/scale 已 deprecated：改用等價的顯式構造
      return Matrix4.translationValues(
        tx,
        ty,
        0,
      ).multiplied(Matrix4.diagonal3Values(scale, scale, 1));
    }

    _animationController
      ..stop()
      ..reset();
    _animation =
        Matrix4Tween(
          begin: centeredMatrix(startScale),
          end: centeredMatrix(endScale),
        ).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeOutCubic,
          ),
        );

    void listener() {
      _transformationController.value = _animation.value;
    }

    _animation.addListener(listener);
    _animationController.forward().whenCompleteOrCancel(() {
      _animation.removeListener(listener);
    });
  }

  void _initGraph() {
    _graphSignature = _signatureFor(widget.memories, widget.links);
    _spawnAt = DateTime.now(); // 節點織網入場動畫起點
    _simAlpha = 1.0; // 新圖滿溫重排，~4s 後自然凍結
    final sorted = [...widget.memories];
    sorted.sort((a, b) {
      final ac = _clarityFor(a);
      final bc = _clarityFor(b);
      final c = bc.compareTo(ac);
      if (c != 0) return c;
      return (_memoryId(a) ?? 0).compareTo(_memoryId(b) ?? 0);
    });

    final nodeMap = <int, _Node>{};
    final random = Random(42);
    const spokes = 12;

    _nodes = <_Node>[];
    for (var i = 0; i < sorted.length; i++) {
      final memory = sorted[i];
      final id = _memoryId(memory);
      if (id == null) continue;

      final clarity = _clarityFor(memory).clamp(0.18, 1.0);
      final mentionCount = (memory['mention_count'] as int?) ?? 0;
      final category = memory['category'] as String? ?? '';

      final ring = i ~/ spokes;
      final spoke = i % spokes;
      final angle =
          ((spoke + ring * 0.38) * 2 * pi / spokes) +
          (random.nextDouble() - 0.5) * 0.16;
      final clarityPull = (1 - clarity) * 360;
      final mentionPull = min(mentionCount, 8) * 18;
      final ringRadius = 210 + ring * 150 + clarityPull - mentionPull;
      final radius = ringRadius.clamp(180.0, _graphRadius);

      final node = _Node(
        data: memory,
        x: radius * cos(angle),
        y: radius * sin(angle),
        clarity: clarity,
        mentionCount: mentionCount,
        category: category,
      );
      nodeMap[id] = node;
      _nodes.add(node);
    }

    _edges = widget.links
        .map((link) {
          final id1 = link['memory_id_1'] as int?;
          final id2 = link['memory_id_2'] as int?;
          if (id1 == null || id2 == null) return null;
          final n1 = nodeMap[id1];
          final n2 = nodeMap[id2];
          if (n1 == null || n2 == null) return null;
          return _Edge(n1, n2);
        })
        .whereType<_Edge>()
        .toList();

    if (mounted) setState(() {});
  }

  String _signatureFor(
    List<Map<String, dynamic>> memories,
    List<Map<String, dynamic>> links,
  ) {
    final memPart = memories
        .map(
          (m) =>
              '${m['id']}:${m['last_accessed'] ?? ''}:${m['mention_count'] ?? 0}',
        )
        .join('|');
    final linkPart = links
        .map((l) => '${l['memory_id_1']}-${l['memory_id_2']}')
        .join('|');
    return '$memPart::$linkPart';
  }

  int? _memoryId(Map<String, dynamic> memory) {
    final raw = memory['id'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }

  double _clarityFor(Map<String, dynamic> memory) {
    final category = memory['category'] as String? ?? '';
    final lastAccessed = memory['last_accessed'] as String?;
    final createdAt =
        memory['created_at'] as String? ?? DateTime.now().toIso8601String();
    final refTime = lastAccessed != null && lastAccessed.isNotEmpty
        ? lastAccessed
        : createdAt;

    try {
      return SpiderWebCore.calculateClarity(refTime, category: category);
    } catch (_) {
      return 1.0;
    }
  }

  void _handlePointerUp(PointerUpEvent details) {
    final adjustedTapPos =
        details.localPosition - const Offset(_canvasCenter, _canvasCenter);

    _Node? best;
    double bestDistance = double.infinity;
    for (final node in _nodes) {
      final dx = node.x - adjustedTapPos.dx;
      final dy = node.y - adjustedTapPos.dy;
      final distance = dx * dx + dy * dy;
      // Use the same generous hit radius as down
      final hitRadius = node.tapRadius * 2.5;
      if (distance <= hitRadius * hitRadius && distance < bestDistance) {
        best = node;
        bestDistance = distance;
      }
    }

    // Only consider it a tap if the user didn't drag it significantly
    if (best != null && _draggedDistance < 8.0) {
      _ripples.add(_Ripple(Offset(best.x, best.y), DateTime.now()));
      widget.onNodeTapped(best.data);
    }

    _handlePointerUpOrCancel();
  }

  double _draggedDistance = 0.0;

  void _handlePointerDown(PointerDownEvent details) {
    _draggedDistance = 0.0;
    final adjustedTapPos =
        details.localPosition - const Offset(_canvasCenter, _canvasCenter);

    _Node? best;
    double bestDistance = double.infinity;
    for (final node in _nodes) {
      final dx = node.x - adjustedTapPos.dx;
      final dy = node.y - adjustedTapPos.dy;
      final distance = dx * dx + dy * dy;
      final hitRadius = node.tapRadius * 2.5;
      if (distance <= hitRadius * hitRadius && distance < bestDistance) {
        best = node;
        bestDistance = distance;
      }
    }

    if (best != null) {
      final node = best; // 閉包內 promotion 失效，取非空局部變量
      setState(() {
        _draggedNode = node;
        node.isDragged = true;
        node.vx = 0;
        node.vy = 0;
        // 回溫：拖拽期間鄰居要能讓位
        _simAlpha = max(_simAlpha, 0.55);
      });
    }
  }

  void _handlePointerMove(PointerMoveEvent details) {
    if (_draggedNode != null) {
      _draggedDistance += details.localDelta.distance;
      setState(() {
        _draggedNode!.x += details.localDelta.dx;
        _draggedNode!.y += details.localDelta.dy;
      });
    }
  }

  void _handlePointerUpOrCancel() {
    if (_draggedNode != null) {
      setState(() {
        _draggedNode!.isDragged = false;
        _draggedNode = null;
        // 鬆手後留一點餘溫收拾殘局，隨後自然凍結
        _simAlpha = max(_simAlpha, 0.30);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.memories.isEmpty) return const _EmptySpiderWeb();

    return ClipRRect(
      borderRadius: BorderRadius.circular(YanciTheme.radiusLg),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: YanciTheme.isDark
                    ? Colors.black.withValues(alpha: 0.16)
                    : Colors.white.withValues(alpha: 0.28),
              ),
            ),
          ),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final newSize = Size(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                if (_viewSize != newSize) {
                  _viewSize = newSize;
                  if (!_hasAnimated) {
                    _hasAnimated = true;
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _startEntryAnimation(),
                    );
                  }
                }
                return InteractiveViewer(
                  transformationController: _transformationController,
                  constrained: false,
                  panEnabled: _draggedNode == null,
                  scaleEnabled: _draggedNode == null,
                  boundaryMargin: const EdgeInsets.all(1400),
                  minScale: 0.18,
                  maxScale: 2.4,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _handlePointerDown,
                    onPointerMove: _handlePointerMove,
                    onPointerUp: _handlePointerUp,
                    onPointerCancel: (_) => _handlePointerUpOrCancel(),
                    child: CustomPaint(
                      size: const Size(_canvasSize, _canvasSize),
                      painter: _GraphPainter(
                        _nodes,
                        _edges,
                        timeSec: _timeSec,
                        entryElapsedMs: DateTime.now()
                            .difference(_spawnAt)
                            .inMilliseconds,
                        ripples: _ripples,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: _GraphBadge(
              icon: Icons.hub_outlined,
              label: L.pick(
                en: '${_nodes.length} nodes',
                zhTW: '${_nodes.length} 節點',
              ),
            ),
          ),
          if (_edges.isNotEmpty)
            Positioned(
              top: 12,
              right: 12,
              child: _GraphBadge(
                icon: Icons.polyline_rounded,
                label: L.pick(
                  en: '${_edges.length} links',
                  zhTW: '${_edges.length} 連線',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GraphBadge extends StatelessWidget {
  final IconData icon;
  final String label;

  const _GraphBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: YanciTheme.isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.white.withValues(alpha: 0.64),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: YanciTheme.isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.white.withValues(alpha: 0.72),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: YanciTheme.accent),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: YanciTheme.textSecondary,
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptySpiderWeb extends StatelessWidget {
  const _EmptySpiderWeb();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(YanciTheme.radiusLg),
      child: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          color: YanciTheme.isDark
              ? Colors.black.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.32),
          border: Border.all(
            color: YanciTheme.accent.withValues(alpha: 0.12),
            width: 0.5,
          ),
        ),
        child: CustomPaint(
          painter: _EmptyWebPainter(),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.hub_outlined,
                  size: 30,
                  color: YanciTheme.accent.withValues(alpha: 0.76),
                ),
                const SizedBox(height: 10),
                Text(
                  L.pick(en: 'No nodes yet', zhTW: '還沒有節點'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: YanciTheme.textPrimary,
                    fontFamily: YanciTheme.fontFamily,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 點擊節點的擴散漣漪
class _Ripple {
  static const int lifeMs = 480;
  final Offset center;
  final DateTime at;
  _Ripple(this.center, this.at);
}

class _GraphPainter extends CustomPainter {
  final List<_Node> nodes;
  final List<_Edge> edges;
  final double timeSec; // 環境動畫時鐘（呼吸/流光）
  final int entryElapsedMs; // 入場經過毫秒（織網 stagger）
  final List<_Ripple> ripples;

  _GraphPainter(
    this.nodes,
    this.edges, {
    this.timeSec = 0,
    this.entryElapsedMs = 99999,
    this.ripples = const [],
  });

  // 入場參數：每節點錯開 35ms、單節點 420ms 完成
  static const int _entryStaggerMs = 35;
  static const int _entryDurMs = 420;

  /// 第 i 個節點的入場進度 0~1（easeOutBack 由調用側套）
  double _entryProgress(int i) {
    final t = (entryElapsedMs - i * _entryStaggerMs) / _entryDurMs;
    return t.clamp(0.0, 1.0);
  }

  static double _easeOutBack(double t) {
    const c1 = 1.70158;
    const c3 = c1 + 1;
    final u = t - 1;
    return 1 + c3 * u * u * u + c1 * u * u;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    _drawWeb(canvas);
    _drawEdges(canvas);
    _drawRipples(canvas);
    _drawNodes(canvas);
    canvas.restore();
  }

  void _drawRipples(Canvas canvas) {
    final now = DateTime.now();
    for (final r in ripples) {
      final t = (now.difference(r.at).inMilliseconds / _Ripple.lifeMs).clamp(
        0.0,
        1.0,
      );
      if (t >= 1) continue;
      final ease = 1 - pow(1 - t, 3).toDouble(); // easeOutCubic
      final paint = Paint()
        ..color = YanciTheme.accentLight.withValues(alpha: 0.38 * (1 - t))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2 * (1 - t) + 0.6;
      canvas.drawCircle(r.center, 14 + ease * 52, paint);
      // 第二圈慢半拍，漣漪更像水
      if (t > 0.18) {
        final t2 = ((t - 0.18) / 0.82).clamp(0.0, 1.0);
        final ease2 = 1 - pow(1 - t2, 3).toDouble();
        canvas.drawCircle(
          r.center,
          10 + ease2 * 38,
          paint
            ..color = YanciTheme.accentGlow.withValues(alpha: 0.22 * (1 - t2)),
        );
      }
    }
  }

  // 蛛網幾何是確定性的（jitter 用 sin 偽隨機）——Path 只建一次，
  // 每幀重建 8圈×12輻貝茲是白燒的 CPU。
  static Path? _cachedWebPath;

  static Path _buildWebPath() {
    const spokes = 12;
    const radius = _graphRadius + 220;

    final spokeAngles = <double>[];
    for (int i = 0; i < spokes; i++) {
      final jitter = sin(i * 99.7) * 0.35;
      spokeAngles.add((i * 2 * pi / spokes) + jitter);
    }

    final path = Path();
    // 輻線：延伸至遠方邊界作為錨線
    for (var i = 0; i < spokes; i++) {
      final angle = spokeAngles[i];
      const anchorRadius = radius * 4.0;
      path.moveTo(0, 0);
      path.lineTo(cos(angle) * anchorRadius, sin(angle) * anchorRadius);
    }

    // 連續螺旋網
    final intersections = <Offset>[];
    double r = 85.0;
    for (int ring = 0; ring < 8; ring++) {
      for (int i = 0; i < spokes; i++) {
        final angle = spokeAngles[i];
        final wobble =
            sin(ring * 3.1 + i * 2.7) * 75.0 + cos(i * 5.5 - ring * 1.2) * 45.0;
        final currentR = (r + wobble).clamp(r - 70.0, r + 140.0);
        intersections.add(Offset(cos(angle) * currentR, sin(angle) * currentR));
        r += (175.0 + ring * 30.0) / spokes;
      }
      r += 25.0 + sin(ring * 4.2) * 35.0;
    }

    for (int i = 0; i < intersections.length - 1; i++) {
      final p1 = intersections[i];
      final p2 = intersections[i + 1];
      final angle1 = spokeAngles[i % spokes];
      var angle2 = spokeAngles[(i + 1) % spokes];
      if (angle2 < angle1) angle2 += 2 * pi;
      final midAngle = (angle1 + angle2) / 2;
      final r1 = p1.distance;
      final r2 = p2.distance;
      final droop = ((r1 + r2) / 2) * 0.16;
      final controlR = ((r1 + r2) / 2) - droop;
      final control = Offset(
        cos(midAngle) * controlR,
        sin(midAngle) * controlR,
      );
      if (i == 0) path.moveTo(p1.dx, p1.dy);
      path.quadraticBezierTo(control.dx, control.dy, p2.dx, p2.dy);
    }
    return path;
  }

  void _drawWeb(Canvas canvas) {
    _cachedWebPath ??= _buildWebPath();
    // 絲線光澤極緩慢地明暗（週期 ~9s）。基準壓淡一檔——
    // 背景是裝飾，真實記憶連線才是主角，層次要拉開。
    final sheen = 0.20 + 0.06 * sin(timeSec * 0.7);
    final webPaint = Paint()
      ..color = YanciTheme.accent.withValues(alpha: sheen)
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(_cachedWebPath!, webPaint);
  }

  /// 二次貝茲上的點（t∈0~1）——流光沿線走用
  static Offset _quadPoint(Offset p0, Offset c, Offset p1, double t) {
    final u = 1 - t;
    return Offset(
      u * u * p0.dx + 2 * u * t * c.dx + t * t * p1.dx,
      u * u * p0.dy + 2 * u * t * c.dy + t * t * p1.dy,
    );
  }

  void _drawEdges(Canvas canvas) {
    for (var ei = 0; ei < edges.length; ei++) {
      final edge = edges[ei];
      final p1 = Offset(edge.source.x, edge.source.y);
      final p2 = Offset(edge.target.x, edge.target.y);
      final midpoint = Offset.lerp(p1, p2, 0.5)!;
      final control = Offset.lerp(midpoint, Offset.zero, 0.22)!;
      final clarity = ((edge.source.clarity + edge.target.clarity) / 2).clamp(
        0.22,
        1.0,
      );
      // 拖拽高亮：牽的那幾根線亮起來、變韌
      final tugged = edge.source.isDragged || edge.target.isDragged;
      // 可見性映射：clarity 只調強弱，不再乘到隱形——
      // 老記憶 clarity 貼底時舊算法 alpha≈0.09，被 0.3+ 的背景蛛網
      // 完全淹沒，「連線消失」的真兇。底線抬到 0.55。
      final vis = 0.55 + 0.40 * clarity;

      final path = Path()
        ..moveTo(p1.dx, p1.dy)
        ..quadraticBezierTo(control.dx, control.dy, p2.dx, p2.dy);

      final glow = Paint()
        ..color = YanciTheme.accentGlow.withValues(
          alpha: (tugged ? 0.40 : 0.24) * vis,
        )
        ..strokeWidth = tugged ? 9 : 7
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      final line = Paint()
        ..color = YanciTheme.accentLight.withValues(
          alpha: (tugged ? 0.95 : 0.80) * vis,
        )
        ..strokeWidth = (tugged ? 2.8 : 2.2) + clarity * 0.8
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;

      canvas.drawPath(path, glow);
      canvas.drawPath(path, line);

      // ═══ 流光：清晰的連線上有微光沿絲滑行（神經傳導感）═══
      if (clarity >= 0.55 && edges.length <= 60) {
        // 每根線相位錯開，速度 ~8s 一趟，方向由索引奇偶交替
        var t = (timeSec * 0.13 + ei * 0.37) % 1.0;
        if (ei.isOdd) t = 1.0 - t;
        final pos = _quadPoint(p1, control, p2, t);
        final sparkAlpha = (0.5 + 0.3 * sin(timeSec * 2.1 + ei)) * clarity;
        canvas.drawCircle(
          pos,
          5.5,
          Paint()
            ..color = YanciTheme.accentGlow.withValues(alpha: sparkAlpha * 0.5)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        );
        canvas.drawCircle(
          pos,
          2.1,
          Paint()..color = Colors.white.withValues(alpha: sparkAlpha),
        );
      }
    }
  }

  void _drawNodes(Canvas canvas) {
    for (var ni = 0; ni < nodes.length; ni++) {
      final node = nodes[ni];
      // ═══ 入場：沿排序逐個「織」出來（縮放回彈 + 淡入）═══
      final entry = _entryProgress(ni);
      if (entry <= 0) continue;
      final entryScale = _easeOutBack(entry).clamp(0.0, 1.12);
      final entryAlpha = entry.clamp(0.0, 1.0);

      final p = Offset(node.x, node.y);
      final color = _categoryColor(node.category);
      final mentionBoost = min(node.mentionCount, 8) * 0.45;

      // ═══ 呼吸：相位按索引錯開；清晰度越低呼吸越微弱（將熄的燈）═══
      final breath =
          sin(timeSec * 1.5 + ni * 1.7) * (0.35 + 0.65 * node.clarity);
      final breathGlow = 1.0 + 0.16 * breath;
      // 被拖拽的本體與其鄰居一起提亮（牽一髮動全網）
      final excited =
          node.isDragged ||
          edges.any(
            (e) =>
                (e.source == node && e.target.isDragged) ||
                (e.target == node && e.source.isDragged),
          );
      final excite = excited ? 1.35 : 1.0;

      final dotRadius = (5.8 + node.clarity * 5.2 + mentionBoost) * entryScale;
      final glowRadius = dotRadius * (2.4 + node.clarity) * breathGlow * excite;

      final outerGlow = Paint()
        ..color = color.withValues(
          alpha:
              (0.22 + node.clarity * 0.22) *
              (1.0 + 0.25 * breath) *
              excite *
              entryAlpha,
        )
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
      final halo = Paint()
        ..color = color.withValues(alpha: 0.12 * entryAlpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      final dot = Paint()
        ..color = color.withValues(
          alpha: (0.66 + node.clarity * 0.32) * entryAlpha,
        );
      final core = Paint()
        ..color = Colors.white.withValues(alpha: 0.86 * entryAlpha);

      canvas.drawCircle(p, glowRadius, outerGlow);
      canvas.drawCircle(p, dotRadius + 8, halo);
      canvas.drawCircle(p, dotRadius, dot);
      canvas.drawCircle(p, max(2.0, dotRadius * 0.28), core);

      final shouldLabel =
          (nodes.length <= 18 ||
              node.clarity >= 0.64 ||
              node.mentionCount >= 3) &&
          entry >= 1.0;
      if (shouldLabel) _drawLabel(canvas, node, p, color);
    }
  }

  void _drawLabel(Canvas canvas, _Node node, Offset p, Color color) {
    final snippet = _getSnippet(node.data['content'] as String? ?? '');
    if (snippet.isEmpty) return;

    final textPainter = TextPainter(
      text: TextSpan(
        text: snippet,
        style: TextStyle(
          color: YanciTheme.isDark
              ? Color.lerp(color, Colors.white, 0.35)
              : Color.lerp(color, Colors.black, 0.18),
          fontSize: 14,
          fontWeight: FontWeight.w700,
          fontFamily: YanciTheme.fontFamily,
          height: 1.15,
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 124);

    final above = p.dy > 120;
    final y = above ? p.dy - 38 : p.dy + 36;
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(p.dx, y),
        width: textPainter.width + 18,
        height: textPainter.height + 10,
      ),
      const Radius.circular(10),
    );

    final fill = Paint()
      ..color = YanciTheme.isDark
          ? Colors.black.withValues(alpha: 0.34)
          : Colors.white.withValues(alpha: 0.74);
    final border = Paint()
      ..color = color.withValues(alpha: 0.22 + node.clarity * 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    canvas.drawRRect(rect, fill);
    canvas.drawRRect(rect, border);
    textPainter.paint(
      canvas,
      Offset(
        rect.center.dx - textPainter.width / 2,
        rect.center.dy - textPainter.height / 2,
      ),
    );
  }

  Color _categoryColor(String category) {
    if (category.contains('重要') || category.contains('事件')) {
      return const Color(0xFFFFC85A);
    }
    if (category.contains('情緒') || category.contains('Emotion')) {
      return const Color(0xFFFF77B7);
    }
    if (category.contains('偏好') || category.contains('Preference')) {
      return const Color(0xFF7DDCFF);
    }
    if (category.contains('約定') ||
        category.contains('承諾') ||
        category.contains('Promise')) {
      return const Color(0xFF82E6A8);
    }
    if (category.contains('自我') || category.contains('Persona')) {
      return const Color(0xFFBBA2FF);
    }
    return YanciTheme.accentLight;
  }

  String _getSnippet(String content) {
    final cleaned = content
        .replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), '')
        .replaceAll('\n', ' ')
        .trim();
    if (cleaned.length <= 8) return cleaned;
    return '${cleaned.substring(0, 8)}…';
  }

  @override
  bool shouldRepaint(covariant _GraphPainter oldDelegate) {
    // 節點列表是同一個引用被原地 mutate，引用比較永遠 false 會凍畫。
    // 重繪頻率已由 state 側節流（物理靜止時 ~15fps），這裡直接 true。
    return true;
  }
}

class _EmptyWebPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = min(size.width, size.height) * 0.36;
    final paint = Paint()
      ..color = YanciTheme.accent.withValues(alpha: 0.14)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    for (var i = 0; i < 10; i++) {
      final angle = i * 2 * pi / 10;
      canvas.drawLine(
        center,
        center + Offset(cos(angle) * maxRadius, sin(angle) * maxRadius),
        paint,
      );
    }

    for (var i = 1; i <= 4; i++) {
      canvas.drawCircle(center, maxRadius * i / 4, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
