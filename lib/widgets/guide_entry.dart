import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/locale_strings.dart';

class GuideEntry extends StatefulWidget {
  const GuideEntry({
    super.key,
    required this.showIntro,
    required this.reduceMotion,
    required this.color,
    required this.onTap,
    required this.onIntroCompleted,
  });

  final bool showIntro;
  final bool reduceMotion;
  final Color color;
  final VoidCallback onTap;
  final VoidCallback onIntroCompleted;

  @override
  State<GuideEntry> createState() => _GuideEntryState();
}

class _GuideEntryState extends State<GuideEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 8000),
  );

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onIntroCompleted();
    });
    if (widget.showIntro) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant GuideEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showIntro && !oldWidget.showIntro) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final progress = _controller.value;
        final iconOpacity = widget.showIntro
            ? (progress / .06).clamp(0.0, 1.0)
            : 1.0;
        final textOpacity = !widget.showIntro
            ? 0.0
            : progress < .08
            ? 0.0
            : progress < .14
            ? ((progress - .08) / .06).clamp(0.0, 1.0)
            : progress < .9
            ? 1.0
            : ((1 - progress) / .1).clamp(0.0, 1.0);
        final pulseWindow =
            !widget.reduceMotion && progress >= .06 && progress <= .46;
        final pulsePhase = ((progress - .06) / .4).clamp(0.0, 1.0);
        final pulse = pulseWindow
            ? (math.sin(pulsePhase * math.pi * 6 - math.pi / 2) + 1) / 2
            : 0.0;

        return Opacity(
          opacity: iconOpacity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Semantics(
                key: const Key('guide_entry_button'),
                button: true,
                label: L.pick(en: 'Open Guide', zhTW: '打開嚮導', zhCN: '打开向导'),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onTap,
                  child: SizedBox.square(
                    dimension: 48,
                    child: Stack(
                      alignment: Alignment.center,
                      children: <Widget>[
                        if (pulseWindow)
                          Container(
                            width: 31 + pulse * 9,
                            height: 31 + pulse * 9,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: widget.color.withValues(
                                    alpha: .08 + pulse * .18,
                                  ),
                                  blurRadius: 8 + pulse * 8,
                                  spreadRadius: pulse * 2,
                                ),
                              ],
                            ),
                          ),
                        Icon(
                          Icons.person_outline_rounded,
                          size: 23,
                          color: widget.color,
                        ),
                        Positioned(
                          right: 8,
                          top: 7,
                          child: Text(
                            '?',
                            style: TextStyle(
                              color: widget.color,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (pulseWindow)
                          for (final offset in const <Offset>[
                            Offset(7, 11),
                            Offset(36, 10),
                            Offset(39, 34),
                          ])
                            Positioned(
                              left: offset.dx,
                              top: offset.dy,
                              child: Opacity(
                                opacity: .18 + pulse * .72,
                                child: Container(
                                  width: 3.5,
                                  height: 3.5,
                                  decoration: BoxDecoration(
                                    color: widget.color,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
              ),
              IgnorePointer(
                child: Opacity(
                  opacity: textOpacity,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1, right: 2),
                    child: Text(
                      L.pick(
                        en: 'Talk through your questions with the Guide',
                        zhTW: '與嚮導聊聊你的困惑',
                        zhCN: '与向导聊聊你的困惑',
                      ),
                      style: TextStyle(
                        color: widget.color.withValues(alpha: .76),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
