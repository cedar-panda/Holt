import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../memory/spider_web_core.dart';
import '../services/locale_strings.dart';
import '../services/spider_web_state_service.dart';
import '../theme/app_theme.dart';

const double _canvasSize = 3200.0;
const double _canvasCenter = _canvasSize / 2;
const double _graphRadius = 1180.0;
const double _minimumScreenNodeHitRadius = 24.0;

class _Node {
  final Map<String, dynamic> data;
  final int webIndex;
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
    required this.webIndex,
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
  final Map<String, dynamic> data;

  _Edge(this.source, this.target, this.data);
}

class _WebTransform {
  final Offset center;
  final double scale;

  const _WebTransform(this.center, this.scale);
}

Offset _edgeWebCenter(_Edge edge, List<_WebTransform> webTransforms) {
  final sourceIndex = edge.source.webIndex;
  final targetIndex = edge.target.webIndex;
  if (sourceIndex < 0 ||
      targetIndex < 0 ||
      sourceIndex >= webTransforms.length ||
      targetIndex >= webTransforms.length) {
    return Offset.zero;
  }
  if (sourceIndex == targetIndex) return webTransforms[sourceIndex].center;
  return Offset.lerp(
    webTransforms[sourceIndex].center,
    webTransforms[targetIndex].center,
    0.5,
  )!;
}

Offset _edgeControlPoint(Offset start, Offset end, Offset webCenter) {
  final midpoint = Offset.lerp(start, end, 0.5)!;
  return Offset.lerp(midpoint, webCenter, 0.22)!;
}

class SpiderWebGraphView extends StatefulWidget {
  final List<Map<String, dynamic>> memories;
  final List<List<Map<String, dynamic>>> memoryGroups;
  final List<bool> smallWebGroups;
  final List<Map<String, dynamic>> links;
  final Map<int, SpiderWebNodePosition> savedPositions;
  final double viewportRightInset;
  final int externalLinkCount;
  final void Function(Map<String, dynamic> memory) onNodeTapped;
  final void Function(
    Map<String, dynamic> link,
    Map<String, dynamic> firstMemory,
    Map<String, dynamic> secondMemory,
  )
  onLinkTapped;
  final void Function(int memoryId, double localX, double localY)
  onNodePositionChanged;
  final VoidCallback? onExternalLinksTapped;
  final VoidCallback? onLinksTapped;
  final VoidCallback? onZeroLinksAction;

  const SpiderWebGraphView({
    super.key,
    required this.memories,
    this.memoryGroups = const [],
    this.smallWebGroups = const [],
    required this.links,
    this.savedPositions = const {},
    this.viewportRightInset = 0,
    this.externalLinkCount = 0,
    required this.onNodeTapped,
    required this.onLinkTapped,
    required this.onNodePositionChanged,
    this.onExternalLinksTapped,
    this.onLinksTapped,
    this.onZeroLinksAction,
  });

  /// Exposes the legacy-position repair rule to focused geometry tests.
  @visibleForTesting
  static Offset snapSavedPositionForTesting(Offset position) =>
      _SpiderWebGraphViewState._nearestLocalSlot(position);

  /// Exposes the responsive camera rule without leaking controller state.
  @visibleForTesting
  static double fittedScaleForTesting({
    required Size viewport,
    required int webCount,
    double rightInset = 0,
  }) => _SpiderWebGraphViewState._fittedScale(
    viewport,
    _SpiderWebGraphViewState._transformsForCount(webCount, const []),
    rightInset,
  );

  /// Exposes the padded visual extent used by the initial fit calculation.
  @visibleForTesting
  static Size fittedContentSizeForTesting({required int webCount}) =>
      _SpiderWebGraphViewState._contentBounds(
        _SpiderWebGraphViewState._transformsForCount(webCount, const []),
      ).size;

  @visibleForTesting
  static int visibleSlotCountForTesting() => _GraphPainter.webSlots.length;

  @visibleForTesting
  static double maximumSlotRadiusForTesting() =>
      _GraphPainter.webSlots.map((slot) => slot.distance).fold(0.0, max);

  @visibleForTesting
  static double screenDragTargetDiameterForTesting({
    required double scale,
    double nodeTapRadius = 24,
  }) =>
      _SpiderWebGraphViewState._nodeHitRadiusForScale(nodeTapRadius, scale) *
      scale *
      2;

  @visibleForTesting
  static Offset edgeControlForTesting({
    required Offset start,
    required Offset end,
    required Offset webCenter,
  }) => _edgeControlPoint(start, end, webCenter);

  @visibleForTesting
  static Offset visibleSlotForTesting(int index) {
    final slots = _GraphPainter.webSlots;
    return slots[index.clamp(0, slots.length - 1)];
  }

  @visibleForTesting
  static double maximumScaleForTesting({required int webCount}) =>
      _SpiderWebGraphViewState._maximumScaleForWebCount(webCount);

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
  List<_WebTransform> _webTransforms = const [_WebTransform(Offset.zero, 1)];
  String _graphSignature = '';
  _Node? _draggedNode;
  Offset? _dragOrigin;
  final Set<int> _activePointers = <int>{};
  bool _multiTouchGestureActive = false;
  Size? _viewSize;
  bool _hasAnimated = false;

  // ═══ 環境動畫時鐘（呼吸/流光/漣漪/入場）═══
  double _timeSec = 0;
  DateTime _spawnAt = DateTime.now();
  Duration _lastVisualTick = Duration.zero;
  final List<_Ripple> _ripples = [];
  int? _selectedMemoryId;
  bool _reduceMotion = false;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(SpiderWebGraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextSignature = _signatureFor(
      widget.memories,
      widget.memoryGroups,
      widget.smallWebGroups,
      widget.links,
      widget.savedPositions,
    );
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

  void _tick(Duration elapsed) {
    if (_nodes.isEmpty || _reduceMotion) return;
    _timeSec = elapsed.inMicroseconds / 1e6;
    _ripples.removeWhere(
      (r) => DateTime.now().difference(r.at).inMilliseconds > _Ripple.lifeMs,
    );
    // Nodes are anchored to the existing web geometry. Only the restrained
    // ambient light/ripple clock repaints; the old O(n²) force simulation is
    // deliberately gone because it pulled memories away from the silk.
    if ((elapsed - _lastVisualTick).inMilliseconds >= 66 && mounted) {
      _lastVisualTick = elapsed;
      setState(() {});
    }
  }

  void _startEntryAnimation() {
    if (!mounted || widget.memories.isEmpty || _viewSize == null) return;

    final size = _viewSize!;
    final endScale = _fittedScale(
      size,
      _webTransforms,
      widget.viewportRightInset,
    );
    final startScale = endScale * 0.72;
    final contentBounds = _contentBounds(_webTransforms);
    final contentCenter = contentBounds.center;
    final viewportCenter = Offset(
      (size.width - widget.viewportRightInset.clamp(0, size.width - 1)) / 2,
      size.height / 2,
    );

    Matrix4 centeredMatrix(double scale) {
      final tx = viewportCenter.dx - (_canvasCenter + contentCenter.dx) * scale;
      final ty = viewportCenter.dy - (_canvasCenter + contentCenter.dy) * scale;
      // translate/scale 已 deprecated：改用等價的顯式構造
      return Matrix4.translationValues(
        tx,
        ty,
        0,
      ).multiplied(Matrix4.diagonal3Values(scale, scale, 1));
    }

    if (_reduceMotion) {
      _transformationController.value = centeredMatrix(endScale);
      return;
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
    _graphSignature = _signatureFor(
      widget.memories,
      widget.memoryGroups,
      widget.smallWebGroups,
      widget.links,
      widget.savedPositions,
    );
    _spawnAt = DateTime.now(); // 節點織網入場動畫起點
    final nodeMap = <int, _Node>{};
    final groups = widget.memoryGroups.isEmpty
        ? <List<Map<String, dynamic>>>[widget.memories]
        : widget.memoryGroups.where((group) => group.isNotEmpty).toList();
    _webTransforms = _transformsFor(groups.length, widget.smallWebGroups);
    _nodes = <_Node>[];
    final slots = _GraphPainter.webSlots;
    for (var webIndex = 0; webIndex < groups.length; webIndex++) {
      final sorted = [...groups[webIndex]];
      sorted.sort((a, b) {
        final mentions = ((b['mention_count'] as num?)?.toInt() ?? 0).compareTo(
          (a['mention_count'] as num?)?.toInt() ?? 0,
        );
        if (mentions != 0) return mentions;
        final clarity = _clarityFor(b).compareTo(_clarityFor(a));
        if (clarity != 0) return clarity;
        return (_memoryId(a) ?? 0).compareTo(_memoryId(b) ?? 0);
      });
      final transform = _webTransforms[webIndex];
      for (var i = 0; i < sorted.length; i++) {
        final memory = sorted[i];
        final id = _memoryId(memory);
        if (id == null) continue;
        final clarity = _clarityFor(memory).clamp(0.18, 1.0);
        final mentionCount = (memory['mention_count'] as num?)?.toInt() ?? 0;
        final category = memory['category'] as String? ?? '';
        final slotIndex = sorted.length <= 1
            ? slots.length ~/ 2
            : ((i * (slots.length - 1)) / (sorted.length - 1)).round();
        final saved = widget.savedPositions[id];
        final slot = saved == null
            ? slots[slotIndex.clamp(0, slots.length - 1)]
            // Older builds persisted free-drag coordinates. Re-snap them at
            // a visible intersection so memories cannot remain between webs
            // or on an extremely faint outer rail.
            : _nearestLocalSlot(Offset(saved.x, saved.y));
        final point = transform.center + slot * transform.scale;
        final node = _Node(
          data: memory,
          webIndex: webIndex,
          x: point.dx,
          y: point.dy,
          clarity: clarity,
          mentionCount: mentionCount,
          category: category,
        );
        nodeMap[id] = node;
        _nodes.add(node);
      }
    }

    _edges = widget.links
        .map((link) {
          final id1 = link['memory_id_1'] as int?;
          final id2 = link['memory_id_2'] as int?;
          if (id1 == null || id2 == null) return null;
          final n1 = nodeMap[id1];
          final n2 = nodeMap[id2];
          if (n1 == null || n2 == null) return null;
          return _Edge(n1, n2, link);
        })
        .whereType<_Edge>()
        .toList();

    if (mounted) setState(() {});
  }

  String _signatureFor(
    List<Map<String, dynamic>> memories,
    List<List<Map<String, dynamic>>> memoryGroups,
    List<bool> smallWebGroups,
    List<Map<String, dynamic>> links,
    Map<int, SpiderWebNodePosition> savedPositions,
  ) {
    final memPart = memories
        .map(
          (m) =>
              '${m['id']}:${m['last_accessed'] ?? ''}:${m['mention_count'] ?? 0}',
        )
        .join('|');
    final linkPart = links
        .map(
          (l) =>
              '${l['memory_id_1']}-${l['memory_id_2']}:${l['status']}:${l['relation_type']}:${l['strength']}',
        )
        .join('|');
    final groupPart = memoryGroups
        .map((group) => group.map((m) => m['id']).join(','))
        .join('/');
    final positionPart = savedPositions.entries
        .map((entry) => '${entry.key}:${entry.value.x}:${entry.value.y}')
        .join('|');
    return '$memPart::$groupPart::${smallWebGroups.join(',')}::$linkPart::$positionPart';
  }

  List<_WebTransform> _transformsFor(int count, List<bool> smallGroups) =>
      _transformsForCount(count, smallGroups);

  static List<_WebTransform> _transformsForCount(
    int count,
    List<bool> smallGroups,
  ) {
    final base = switch (count.clamp(1, 4)) {
      1 => const [_WebTransform(Offset.zero, 1)],
      2 => const [
        _WebTransform(Offset(-690, 0), 0.56),
        _WebTransform(Offset(690, 0), 0.56),
      ],
      3 => const [
        _WebTransform(Offset(-690, -430), 0.47),
        _WebTransform(Offset(690, -430), 0.47),
        _WebTransform(Offset(0, 650), 0.47),
      ],
      _ => const [
        _WebTransform(Offset(-650, -520), 0.42),
        _WebTransform(Offset(650, -520), 0.42),
        _WebTransform(Offset(-650, 520), 0.42),
        _WebTransform(Offset(650, 520), 0.42),
      ],
    };
    return [
      for (var index = 0; index < base.length; index++)
        _WebTransform(
          base[index].center,
          base[index].scale *
              (index < smallGroups.length && smallGroups[index] ? 0.68 : 1),
        ),
    ];
  }

  static Rect _contentBounds(List<_WebTransform> transforms) {
    final safeTransforms = transforms.isEmpty
        ? const [_WebTransform(Offset.zero, 1)]
        : transforms;
    Rect? bounds;
    for (final transform in safeTransforms) {
      // The painted silk ends at graphRadius + 220, but node glows and labels
      // extend beyond it. Keep a real visual gutter in the fit bounds so the
      // outer ring is never flush-clipped by the viewport.
      final radius = (_graphRadius + 360) * transform.scale;
      final webBounds = Rect.fromCircle(
        center: transform.center,
        radius: radius,
      );
      bounds = bounds == null ? webBounds : bounds.expandToInclude(webBounds);
    }
    return bounds!;
  }

  static double _fittedScale(
    Size viewport,
    List<_WebTransform> transforms,
    double rightInset,
  ) {
    final bounds = _contentBounds(transforms);
    final safeInset = rightInset.clamp(0.0, max(0.0, viewport.width - 1));
    final availableWidth = max(1.0, viewport.width - safeInset - 28);
    final availableHeight = max(1.0, viewport.height - 36);
    final widthScale = availableWidth / max(1.0, bounds.width);
    final heightScale = availableHeight / max(1.0, bounds.height);
    return min(widthScale, heightScale).clamp(0.04, 0.34);
  }

  Offset _nearestSilkPoint(_Node node, Offset canvasPoint) {
    final transform = _webTransforms[node.webIndex];
    final local = (canvasPoint - transform.center) / transform.scale;
    final best = _nearestLocalSilkPoint(local);
    return transform.center + best * transform.scale;
  }

  static Offset _nearestLocalSilkPoint(Offset local) {
    var best = _GraphPainter.webRailSamples.first;
    var bestDistance = double.infinity;
    for (final sample in _GraphPainter.webRailSamples) {
      final distance = (sample - local).distanceSquared;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = sample;
      }
    }
    return best;
  }

  static Offset _nearestLocalSlot(Offset local) {
    var best = _GraphPainter.webSlots.first;
    var bestDistance = double.infinity;
    for (final slot in _GraphPainter.webSlots) {
      final distance = (slot - local).distanceSquared;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = slot;
      }
    }
    return best;
  }

  int? _memoryId(Map<String, dynamic> memory) {
    final raw = memory['id'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }

  double get _currentScale =>
      max(0.001, _transformationController.value.getMaxScaleOnAxis());

  static double _nodeHitRadiusForScale(double tapRadius, double scale) =>
      max(tapRadius * 2.5, _minimumScreenNodeHitRadius / max(scale, 0.001));

  double _nodeHitRadius(_Node node) =>
      _nodeHitRadiusForScale(node.tapRadius, _currentScale);

  double get _dragThreshold => 8.0 / _currentScale;

  static double _maximumScaleForWebCount(int webCount) =>
      webCount <= 1 ? 3.6 : 2.4;

  double get _maximumScale => _maximumScaleForWebCount(_webTransforms.length);

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
    _activePointers.remove(details.pointer);
    if (_multiTouchGestureActive) {
      if (_activePointers.isEmpty) _multiTouchGestureActive = false;
      return;
    }
    final adjustedTapPos =
        details.localPosition - const Offset(_canvasCenter, _canvasCenter);

    _Node? best;
    double bestDistance = double.infinity;
    for (final node in _nodes) {
      final dx = node.x - adjustedTapPos.dx;
      final dy = node.y - adjustedTapPos.dy;
      final distance = dx * dx + dy * dy;
      // Use the same generous hit radius as down
      final hitRadius = _nodeHitRadius(node);
      if (distance <= hitRadius * hitRadius && distance < bestDistance) {
        best = node;
        bestDistance = distance;
      }
    }

    // Only consider it a tap if the user didn't drag it significantly
    if (best != null && _draggedDistance < _dragThreshold) {
      final selected = best;
      _ripples.add(_Ripple(Offset(selected.x, selected.y), DateTime.now()));
      setState(() => _selectedMemoryId = _memoryId(selected.data));
      widget.onNodeTapped(selected.data);
    } else if (best == null && _draggedDistance < _dragThreshold) {
      final edge = _nearestEdge(adjustedTapPos);
      if (edge != null) {
        widget.onLinkTapped(edge.data, edge.source.data, edge.target.data);
      } else if (_selectedMemoryId != null) {
        setState(() => _selectedMemoryId = null);
      }
    }

    _handlePointerUpOrCancel();
  }

  double _draggedDistance = 0.0;

  _Edge? _nearestEdge(Offset point) {
    _Edge? best;
    var bestDistance = max(18.0, 18.0 / _currentScale);
    for (final edge in _edges) {
      final start = Offset(edge.source.x, edge.source.y);
      final end = Offset(edge.target.x, edge.target.y);
      final control = _edgeControlPoint(
        start,
        end,
        _edgeWebCenter(edge, _webTransforms),
      );
      for (var sample = 0; sample <= 24; sample++) {
        final candidate = _GraphPainter.quadPoint(
          start,
          control,
          end,
          sample / 24,
        );
        final distance = (candidate - point).distance;
        if (distance < bestDistance) {
          bestDistance = distance;
          best = edge;
        }
      }
    }
    return best;
  }

  void _handlePointerDown(PointerDownEvent details) {
    _activePointers.add(details.pointer);
    if (_activePointers.length > 1) {
      _multiTouchGestureActive = true;
      _cancelNodeDragForViewportGesture();
      return;
    }
    if (_multiTouchGestureActive) return;
    _draggedDistance = 0.0;
    final adjustedTapPos =
        details.localPosition - const Offset(_canvasCenter, _canvasCenter);

    _Node? best;
    double bestDistance = double.infinity;
    for (final node in _nodes) {
      final dx = node.x - adjustedTapPos.dx;
      final dy = node.y - adjustedTapPos.dy;
      final distance = dx * dx + dy * dy;
      final hitRadius = _nodeHitRadius(node);
      if (distance <= hitRadius * hitRadius && distance < bestDistance) {
        best = node;
        bestDistance = distance;
      }
    }

    if (best != null) {
      final node = best; // 閉包內 promotion 失效，取非空局部變量
      setState(() {
        _draggedNode = node;
        _dragOrigin = Offset(node.x, node.y);
        node.isDragged = true;
        node.vx = 0;
        node.vy = 0;
      });
    }
  }

  void _handlePointerMove(PointerMoveEvent details) {
    if (_multiTouchGestureActive || _activePointers.length != 1) return;
    _draggedDistance += details.localDelta.distance;
    if (_draggedNode != null) {
      setState(() {
        final node = _draggedNode!;
        final proposed = Offset(node.x, node.y) + details.localDelta;
        final silk = _nearestSilkPoint(node, proposed);
        final transform = _webTransforms[node.webIndex];
        final stickyRange = max(72.0, 150.0 * transform.scale);
        final next = (proposed - silk).distance <= stickyRange
            ? Offset.lerp(proposed, silk, 0.72)!
            : proposed;
        node.x = next.dx;
        node.y = next.dy;
      });
    }
  }

  void _handlePointerUpOrCancel() {
    if (_draggedNode != null) {
      final node = _draggedNode!;
      final transform = _webTransforms[node.webIndex];
      final silk = _nearestSilkPoint(node, Offset(node.x, node.y));
      final local = (silk - transform.center) / transform.scale;
      setState(() {
        node
          ..x = silk.dx
          ..y = silk.dy
          ..isDragged = false;
        _draggedNode = null;
        _dragOrigin = null;
      });
      final id = _memoryId(node.data);
      if (id != null && _draggedDistance >= _dragThreshold) {
        widget.onNodePositionChanged(id, local.dx, local.dy);
      }
    }
  }

  void _cancelNodeDragForViewportGesture() {
    final node = _draggedNode;
    if (node == null) return;
    final origin = _dragOrigin;
    setState(() {
      if (origin != null) {
        node
          ..x = origin.dx
          ..y = origin.dy;
      }
      node.isDragged = false;
      _draggedNode = null;
      _dragOrigin = null;
      _draggedDistance = 0;
    });
  }

  void _handlePointerCancel(PointerCancelEvent details) {
    _activePointers.remove(details.pointer);
    if (_multiTouchGestureActive) {
      if (_activePointers.isEmpty) _multiTouchGestureActive = false;
      return;
    }
    _handlePointerUpOrCancel();
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
                if (_viewSize != newSize || !_hasAnimated) {
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
                  // Keep the scale recognizer alive while the first finger is
                  // over a node. A second pointer cancels node dragging and
                  // hands the gesture to the viewport instead of blocking
                  // pinch-to-zoom in dense single-web layers.
                  scaleEnabled: true,
                  boundaryMargin: const EdgeInsets.all(1400),
                  minScale: 0.04,
                  maxScale: _maximumScale,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _handlePointerDown,
                    onPointerMove: _handlePointerMove,
                    onPointerUp: _handlePointerUp,
                    onPointerCancel: _handlePointerCancel,
                    child: CustomPaint(
                      size: const Size(_canvasSize, _canvasSize),
                      painter: _GraphPainter(
                        _nodes,
                        _edges,
                        webTransforms: _webTransforms,
                        timeSec: _timeSec,
                        entryElapsedMs: DateTime.now()
                            .difference(_spawnAt)
                            .inMilliseconds,
                        ripples: _ripples,
                        selectedMemoryId: _selectedMemoryId,
                        reduceMotion: _reduceMotion,
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
          Positioned(
            top: 12,
            right: 12,
            child: _GraphBadge(
              icon: Icons.polyline_rounded,
              label: L.pick(
                en: '${_edges.length} links',
                zhTW: '${_edges.length} 連線',
              ),
              onTap: widget.onLinksTapped,
            ),
          ),
          if (widget.externalLinkCount > 0)
            Positioned(
              top: 60,
              right: 12,
              child: _GraphBadge(
                icon: Icons.layers_rounded,
                label: L.pick(
                  en: '${widget.externalLinkCount} cross-layer',
                  zhTW: '${widget.externalLinkCount} 跨層連線',
                  zhCN: '${widget.externalLinkCount} 跨层连线',
                ),
                onTap: widget.onExternalLinksTapped,
              ),
            ),
          if (widget.onZeroLinksAction != null &&
              _edges.isEmpty &&
              widget.externalLinkCount == 0 &&
              _nodes.length >= 2)
            Positioned(
              left: 20,
              right: 20,
              bottom: 18,
              child: Semantics(
                button: widget.onZeroLinksAction != null,
                label: L.pick(
                  en: 'These memories have no relations yet. Run a local scan.',
                  zhTW: '這些記憶尚未建立關係，可執行本地掃描。',
                  zhCN: '这些记忆尚未建立关系，可执行本地扫描。',
                ),
                child: Center(
                  child: OutlinedButton.icon(
                    onPressed: widget.onZeroLinksAction,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      backgroundColor: Colors.transparent,
                      foregroundColor: YanciTheme.textSecondary,
                      side: BorderSide(
                        color: YanciTheme.textSecondary.withValues(alpha: 0.18),
                        width: 0.8,
                      ),
                    ),
                    icon: const Icon(Icons.manage_search_rounded, size: 18),
                    label: Text(
                      L.pick(
                        en: 'On-device memory deduplication check',
                        zhTW: '本機記憶去重檢查',
                        zhCN: '本机记忆去重检查',
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
}

class _GraphBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _GraphBadge({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: label,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(999),
              child: Container(
                constraints: const BoxConstraints(minHeight: 44),
                padding: const EdgeInsets.symmetric(horizontal: 10),
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
  final List<_WebTransform> webTransforms;
  final double timeSec; // 環境動畫時鐘（呼吸/流光）
  final int entryElapsedMs; // 入場經過毫秒（織網 stagger）
  final List<_Ripple> ripples;
  final int? selectedMemoryId;
  final bool reduceMotion;

  _GraphPainter(
    this.nodes,
    this.edges, {
    this.webTransforms = const [_WebTransform(Offset.zero, 1)],
    this.timeSec = 0,
    this.entryElapsedMs = 99999,
    this.ripples = const [],
    this.selectedMemoryId,
    this.reduceMotion = false,
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
  static List<Offset>? _cachedWebSlots;
  static List<Offset>? _cachedWebRailSamples;

  /// Stable node anchors taken from the exact current web construction. The
  /// geometry is shared with the painter, so capacity/layering never changes
  /// the silhouette the user already likes.
  static List<Offset> get webSlots {
    if (_cachedWebSlots != null) return _cachedWebSlots!;
    const spokes = 12;
    final spokeAngles = <double>[
      for (var i = 0; i < spokes; i++)
        (i * 2 * pi / spokes) + sin(i * 99.7) * 0.35,
    ];
    final intersections = <Offset>[];
    var r = 85.0;
    for (var ring = 0; ring < 8; ring++) {
      for (var i = 0; i < spokes; i++) {
        final angle = spokeAngles[i];
        final wobble =
            sin(ring * 3.1 + i * 2.7) * 75.0 + cos(i * 5.5 - ring * 1.2) * 45.0;
        final currentR = (r + wobble).clamp(r - 70.0, r + 140.0);
        intersections.add(Offset(cos(angle) * currentR, sin(angle) * currentR));
        r += (175.0 + ring * 30.0) / spokes;
      }
      r += 25.0 + sin(ring * 4.2) * 35.0;
    }
    // The spiral continues beyond the visible web so the decorative spokes
    // can fade naturally. Memory anchors must not follow those hidden rings:
    // distributing nodes across all 96 intersections placed later memories
    // outside the clipped silk even before the user touched them.
    _cachedWebSlots = List<Offset>.unmodifiable(
      intersections.where((point) => point.distance <= _graphRadius),
    );
    return _cachedWebSlots!;
  }

  /// Dense samples used by range stickiness while dragging. Samples beyond
  /// the visible web radius are excluded so long anchor rays cannot swallow a
  /// memory outside the intended plane.
  static List<Offset> get webRailSamples {
    if (_cachedWebRailSamples != null) return _cachedWebRailSamples!;
    _cachedWebPath ??= _buildWebPath();
    final samples = <Offset>[];
    for (final metric in _cachedWebPath!.computeMetrics()) {
      for (var distance = 0.0; distance <= metric.length; distance += 28.0) {
        final point = metric.getTangentForOffset(distance)?.position;
        if (point != null && point.distance <= _graphRadius + 220) {
          samples.add(point);
        }
      }
    }
    samples.addAll(webSlots);
    _cachedWebRailSamples = List<Offset>.unmodifiable(samples);
    return _cachedWebRailSamples!;
  }

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
    final sheen = reduceMotion ? 0.23 : 0.20 + 0.06 * sin(timeSec * 0.7);
    final webPaint = Paint()
      ..color = YanciTheme.accent.withValues(alpha: sheen)
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final transform in webTransforms) {
      canvas.save();
      canvas.translate(transform.center.dx, transform.center.dy);
      canvas.scale(transform.scale);
      if (webTransforms.length > 1) {
        canvas.clipPath(
          Path()..addOval(
            Rect.fromCircle(center: Offset.zero, radius: _graphRadius + 220),
          ),
        );
      }
      canvas.drawPath(_cachedWebPath!, webPaint);
      canvas.restore();
    }
  }

  /// 二次貝茲上的點（t∈0~1）——流光沿線走用
  static Offset quadPoint(Offset p0, Offset c, Offset p1, double t) {
    final u = 1 - t;
    return Offset(
      u * u * p0.dx + 2 * u * t * c.dx + t * t * p1.dx,
      u * u * p0.dy + 2 * u * t * c.dy + t * t * p1.dy,
    );
  }

  void _drawEdges(Canvas canvas) {
    for (var ei = 0; ei < edges.length; ei++) {
      final edge = edges[ei];
      final status = edge.data['status']?.toString() ?? 'confirmed';
      final type = edge.data['relation_type']?.toString() ?? 'related';
      final suggested = status == 'suggested';
      final p1 = Offset(edge.source.x, edge.source.y);
      final p2 = Offset(edge.target.x, edge.target.y);
      final midpoint = Offset.lerp(p1, p2, 0.5)!;
      final control = _edgeControlPoint(
        p1,
        p2,
        _edgeWebCenter(edge, webTransforms),
      );
      final clarity = ((edge.source.clarity + edge.target.clarity) / 2).clamp(
        0.22,
        1.0,
      );
      // 拖拽高亮：牽的那幾根線亮起來、變韌
      final tugged = edge.source.isDragged || edge.target.isDragged;
      final firstId = _nodeId(edge.source);
      final secondId = _nodeId(edge.target);
      final selectedPath =
          selectedMemoryId == null ||
          selectedMemoryId == firstId ||
          selectedMemoryId == secondId;
      // 可見性映射：clarity 只調強弱，不再乘到隱形——
      // 老記憶 clarity 貼底時舊算法 alpha≈0.09，被 0.3+ 的背景蛛網
      // 完全淹沒，「連線消失」的真兇。底線抬到 0.55。
      final vis = (0.55 + 0.40 * clarity) * (selectedPath ? 1 : 0.18);

      final path = Path()
        ..moveTo(p1.dx, p1.dy)
        ..quadraticBezierTo(control.dx, control.dy, p2.dx, p2.dy);

      final semanticColor = switch (type) {
        'conflict_update' => Colors.orange.shade400,
        'duplicate_candidate' => YanciTheme.accentLight,
        _ => YanciTheme.accentLight,
      };
      final glow = Paint()
        ..color = semanticColor.withValues(
          alpha:
              (tugged
                  ? 0.40
                  : suggested
                  ? 0.10
                  : 0.24) *
              vis,
        )
        ..strokeWidth = tugged ? 9 : 7
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      final line = Paint()
        ..color = semanticColor.withValues(
          alpha:
              (tugged
                  ? 0.95
                  : suggested
                  ? 0.66
                  : 0.80) *
              vis,
        )
        ..strokeWidth =
            (tugged
                ? 2.8
                : type == 'duplicate_candidate'
                ? 3.0
                : 2.2) +
            clarity * 0.8
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;

      if (!suggested) canvas.drawPath(path, glow);
      if (suggested) {
        _drawDashedPath(
          canvas,
          path,
          line,
          type == 'conflict_update' ? 12 : 18,
        );
        _drawRelationMarker(canvas, midpoint, type, semanticColor, vis);
      } else {
        canvas.drawPath(path, line);
      }

      // ═══ 流光：清晰的連線上有微光沿絲滑行（神經傳導感）═══
      if (!suggested &&
          !reduceMotion &&
          clarity >= 0.55 &&
          edges.length <= 60) {
        // 每根線相位錯開，速度 ~8s 一趟，方向由索引奇偶交替
        var t = (timeSec * 0.13 + ei * 0.37) % 1.0;
        if (ei.isOdd) t = 1.0 - t;
        final pos = quadPoint(p1, control, p2, t);
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

  static int? _nodeId(_Node node) {
    final raw = node.data['id'];
    return raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
  }

  void _drawDashedPath(
    Canvas canvas,
    Path path,
    Paint paint,
    double dashLength,
  ) {
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = min(distance + dashLength, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + dashLength * 0.62;
      }
    }
  }

  void _drawRelationMarker(
    Canvas canvas,
    Offset center,
    String type,
    Color color,
    double visibility,
  ) {
    final radius = type == 'duplicate_candidate' ? 11.0 : 9.0;
    final marker = Path()
      ..moveTo(center.dx, center.dy - radius)
      ..lineTo(center.dx + radius, center.dy)
      ..lineTo(center.dx, center.dy + radius)
      ..lineTo(center.dx - radius, center.dy)
      ..close();
    canvas.drawPath(
      marker,
      Paint()..color = color.withValues(alpha: 0.82 * visibility),
    );
    final glyph = switch (type) {
      'duplicate_candidate' => '≋',
      'conflict_update' => '!',
      _ => '?',
    };
    final painter = TextPainter(
      text: TextSpan(
        text: glyph,
        style: TextStyle(
          color: Colors.white.withValues(alpha: visibility),
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  void _drawNodes(Canvas canvas) {
    for (var ni = 0; ni < nodes.length; ni++) {
      final node = nodes[ni];
      final nodeId = _nodeId(node);
      final connectedToSelection =
          selectedMemoryId == null ||
          nodeId == selectedMemoryId ||
          edges.any((edge) {
            final first = _nodeId(edge.source);
            final second = _nodeId(edge.target);
            return (first == selectedMemoryId && second == nodeId) ||
                (second == selectedMemoryId && first == nodeId);
          });
      // ═══ 入場：沿排序逐個「織」出來（縮放回彈 + 淡入）═══
      final entry = _entryProgress(ni);
      if (entry <= 0) continue;
      final entryScale = _easeOutBack(entry).clamp(0.0, 1.12);
      final entryAlpha = entry.clamp(0.0, 1.0);

      final p = Offset(node.x, node.y);
      final color = _categoryColor(node.category);
      final mentionBoost = min(node.mentionCount, 8) * 0.45;

      // ═══ 呼吸：相位按索引錯開；清晰度越低呼吸越微弱（將熄的燈）═══
      final breath = reduceMotion
          ? 0.0
          : sin(timeSec * 1.5 + ni * 1.7) * (0.35 + 0.65 * node.clarity);
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
              entryAlpha *
              (connectedToSelection ? 1 : 0.22),
        )
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
      final halo = Paint()
        ..color = color.withValues(
          alpha: 0.12 * entryAlpha * (connectedToSelection ? 1 : 0.22),
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      final dot = Paint()
        ..color = color.withValues(
          alpha:
              (0.66 + node.clarity * 0.32) *
              entryAlpha *
              (connectedToSelection ? 1 : 0.24),
        );
      final core = Paint()
        ..color = Colors.white.withValues(
          alpha: 0.86 * entryAlpha * (connectedToSelection ? 1 : 0.28),
        );

      canvas.drawCircle(p, glowRadius, outerGlow);
      canvas.drawCircle(p, dotRadius + 8, halo);
      canvas.drawCircle(p, dotRadius, dot);
      canvas.drawCircle(p, max(2.0, dotRadius * 0.28), core);

      final shouldLabel =
          (nodes.length <= 18 ||
              node.clarity >= 0.64 ||
              node.mentionCount >= 3) &&
          entry >= 1.0;
      if (shouldLabel && connectedToSelection) {
        _drawLabel(canvas, node, p, color);
      }
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
