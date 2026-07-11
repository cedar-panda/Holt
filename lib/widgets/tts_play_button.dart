import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'orbit_loading_indicator.dart';
import '../services/tts_service.dart';

/// 氣泡下方 TTS 播放按鈕
///
/// 三態：
/// - 靜態（未播放）：小喇叭圖標
/// - 連接中：喇叭 + 旋轉小點提示
/// - 播放中：3 條音波跳動 bars
enum TtsButtonState { idle, connecting, playing }

class TtsPlayButton extends StatefulWidget {
  final String? messageId;
  final VoidCallback onTap;
  final double size;

  const TtsPlayButton({
    super.key,
    required this.messageId,
    required this.onTap,
    this.size = 13,
  });

  @override
  State<TtsPlayButton> createState() => _TtsPlayButtonState();
}

class _TtsPlayButtonState extends State<TtsPlayButton>
    with TickerProviderStateMixin {
  // 音波跳動（3 條 bar 各自獨立）
  late List<AnimationController> _barCtrls;
  // 連接旋轉
  late AnimationController _connectCtrl;

  TtsButtonState _state = TtsButtonState.idle;

  @override
  void initState() {
    super.initState();

    _barCtrls = List.generate(3, (i) {
      return AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 300 + i * 120),
      );
    });

    _connectCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    // 監聽 TTS 狀態
    TtsService.stateNotifier.addListener(_onTtsChanged);
    TtsService.playingMessageId.addListener(_onTtsChanged);
  }

  void _onTtsChanged() {
    if (!mounted) return;
    final isThis =
        widget.messageId != null &&
        TtsService.playingMessageId.value == widget.messageId;
    final ttsState = TtsService.stateNotifier.value;

    TtsButtonState newState;
    if (isThis && ttsState == TtsState.playing) {
      newState = TtsButtonState.playing;
    } else if (isThis && ttsState == TtsState.connecting) {
      newState = TtsButtonState.connecting;
    } else {
      newState = TtsButtonState.idle;
    }

    if (newState != _state) {
      setState(() => _state = newState);
      _syncAnimations();
    }
  }

  void _syncAnimations() {
    switch (_state) {
      case TtsButtonState.idle:
        _connectCtrl.stop();
        for (final c in _barCtrls) {
          c.stop();
        }
        break;
      case TtsButtonState.connecting:
        _connectCtrl.repeat();
        break;
      case TtsButtonState.playing:
        _connectCtrl.stop();
        for (final c in _barCtrls) {
          c.repeat(reverse: true);
        }
        break;
    }
  }

  @override
  void dispose() {
    TtsService.stateNotifier.removeListener(_onTtsChanged);
    TtsService.playingMessageId.removeListener(_onTtsChanged);
    for (final c in _barCtrls) {
      c.dispose();
    }
    _connectCtrl.dispose();
    super.dispose();
  }

  void _handleTap() {
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    switch (_state) {
      case TtsButtonState.idle:
        return _buildIdleIcon();
      case TtsButtonState.connecting:
        return _buildConnecting();
      case TtsButtonState.playing:
        return _buildPlayingBars();
    }
  }

  /// 靜態：play_circle 圖標
  Widget _buildIdleIcon() {
    return Icon(
      Icons.play_circle_outline,
      size: widget.size,
      color: YanciTheme.textSecondary.withValues(alpha: 0.45),
    );
  }

  /// 連接中：正圓軌道 + 雙珠接力碰撞
  Widget _buildConnecting() {
    return AnimatedBuilder(
      animation: _connectCtrl,
      builder: (_, _) {
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: CustomPaint(
            painter: OrbitPainter(
              progress: _connectCtrl.value,
              color: YanciTheme.accent,
            ),
          ),
        );
      },
    );
  }

  /// 播放中：3 條音波 bars 跳動
  Widget _buildPlayingBars() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(3, (i) {
        return AnimatedBuilder(
          animation: _barCtrls[i],
          builder: (_, _) {
            final minH = widget.size * 0.2;
            final maxH = widget.size * (0.5 + i * 0.15);
            final h = minH + _barCtrls[i].value * (maxH - minH);

            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 0.8),
              width: 2,
              height: h,
              decoration: BoxDecoration(
                color: YanciTheme.accent.withValues(
                  alpha: 0.5 + _barCtrls[i].value * 0.4,
                ),
                borderRadius: BorderRadius.circular(1),
              ),
            );
          },
        );
      }),
    );
  }
}
