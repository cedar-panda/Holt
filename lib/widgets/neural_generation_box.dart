import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../services/locale_strings.dart';

class NeuralGenerationBox extends StatefulWidget {
  const NeuralGenerationBox({super.key});

  @override
  State<NeuralGenerationBox> createState() => _NeuralGenerationBoxState();
}

class _NeuralGenerationBoxState extends State<NeuralGenerationBox>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final DateTime _startTime = DateTime.now();
  final ValueNotifier<Duration> _elapsed = ValueNotifier(Duration.zero);
  Timer? _elapsedTimer;
  bool _motionDisabled = false;
  late List<_Node> _nodes;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _startElapsedTimer();

    _nodes = List.generate(20, (index) {
      return _Node(
        offset: Offset(Random().nextDouble(), Random().nextDouble()),
        velocity: Offset(
          (Random().nextDouble() - 0.5) * 0.2,
          (Random().nextDouble() - 0.5) * 0.2,
        ),
      );
    });
  }

  void _startElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _elapsed.value = DateTime.now().difference(_startTime);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = MediaQuery.disableAnimationsOf(context);
    if (_motionDisabled == disabled) return;
    _motionDisabled = disabled;
    if (disabled) {
      _controller.stop();
      _elapsedTimer?.cancel();
    } else {
      _controller.repeat();
      _startElapsedTimer();
    }
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _elapsed.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.0,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E24), // Sleek dark background
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return CustomPaint(
                    painter: _NeuralNetworkPainter(
                      progress: _controller.value,
                      nodes: _nodes,
                    ),
                    size: Size.infinite,
                  );
                },
              ),
              Positioned(
                bottom: 12,
                right: 12,
                child: ValueListenableBuilder<Duration>(
                  valueListenable: _elapsed,
                  builder: (context, elapsed, _) {
                    final minutes = elapsed.inMinutes.toString().padLeft(
                      2,
                      '0',
                    );
                    final seconds = (elapsed.inSeconds % 60).toString().padLeft(
                      2,
                      '0',
                    );
                    final millis = (elapsed.inMilliseconds % 1000 ~/ 100)
                        .toString();
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$minutes:$seconds.$millis',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  },
                ),
              ),
              Center(
                child: Text(
                  L.pick(en: 'Generating…', zhTW: '生成中…'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.2,
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

class _Node {
  Offset offset;
  Offset velocity;

  _Node({required this.offset, required this.velocity});
}

class _NeuralNetworkPainter extends CustomPainter {
  final double progress;
  final List<_Node> nodes;

  _NeuralNetworkPainter({required this.progress, required this.nodes});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.cyanAccent.withValues(alpha: 0.6)
      ..strokeWidth = 1.0;

    final nodePaint = Paint()
      ..color = Colors.cyanAccent
      ..style = PaintingStyle.fill;

    // Update node positions based on velocity and bounce off edges
    for (var node in nodes) {
      node.offset += node.velocity * 0.05; // Adjust speed

      if (node.offset.dx < 0 || node.offset.dx > 1) {
        node.velocity = Offset(-node.velocity.dx, node.velocity.dy);
        node.offset = Offset(node.offset.dx.clamp(0.0, 1.0), node.offset.dy);
      }
      if (node.offset.dy < 0 || node.offset.dy > 1) {
        node.velocity = Offset(node.velocity.dx, -node.velocity.dy);
        node.offset = Offset(node.offset.dx, node.offset.dy.clamp(0.0, 1.0));
      }
    }

    final mappedNodes = nodes
        .map((n) => Offset(n.offset.dx * size.width, n.offset.dy * size.height))
        .toList();

    for (int i = 0; i < mappedNodes.length; i++) {
      for (int j = i + 1; j < mappedNodes.length; j++) {
        final dist = (mappedNodes[i] - mappedNodes[j]).distance;
        if (dist < 80) {
          paint.color = Colors.cyanAccent.withValues(
            alpha: (1 - dist / 80) * 0.5,
          );
          canvas.drawLine(mappedNodes[i], mappedNodes[j], paint);
        }
      }
      canvas.drawCircle(mappedNodes[i], 2, nodePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _NeuralNetworkPainter old) => true;
}
