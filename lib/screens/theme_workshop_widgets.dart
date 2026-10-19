part of 'theme_workshop_screen.dart';

class _ParticleEffectOption {
  final String id;
  final String en;
  final String zhTW;
  final String zhCN;

  const _ParticleEffectOption(this.id, this.en, this.zhTW, this.zhCN);
}

enum _ChatBackgroundColorRole { aiBubble, userBubble, bubbleText, thinkingText }

class _AlternatingDoubleChevronHint extends StatefulWidget {
  const _AlternatingDoubleChevronHint({required this.color});

  final Color color;

  @override
  State<_AlternatingDoubleChevronHint> createState() =>
      _AlternatingDoubleChevronHintState();
}

class _AlternatingDoubleChevronHintState
    extends State<_AlternatingDoubleChevronHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      _controller.stop();
    } else if (_controller.isDismissed) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: RepaintBoundary(
          key: const ValueKey('chat-background-more-content-hint'),
          child: SizedBox(
            width: 24,
            height: 25,
            child: reduceMotion
                ? _buildChevrons(topOpacity: 0.5, bottomOpacity: 0.5)
                : AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      if (_controller.isCompleted) {
                        return _buildChevrons(
                          topOpacity: 0.5,
                          bottomOpacity: 0.5,
                        );
                      }
                      final position = _controller.value;
                      final pulse = position <= 0.5
                          ? position * 2
                          : (1 - position) * 2;
                      return _buildChevrons(
                        topOpacity: 0.22 + pulse * 0.58,
                        bottomOpacity: 0.8 - pulse * 0.58,
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildChevrons({
    required double topOpacity,
    required double bottomOpacity,
  }) {
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        Opacity(
          opacity: topOpacity,
          child: Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 19,
            color: widget.color,
          ),
        ),
        Positioned(
          top: 8,
          child: Opacity(
            opacity: bottomOpacity,
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 19,
              color: widget.color,
            ),
          ),
        ),
      ],
    );
  }
}

class _HexColorInput extends StatefulWidget {
  const _HexColorInput({
    required this.color,
    required this.valid,
    required this.onChanged,
  });

  final Color color;
  final bool valid;
  final ValueChanged<String> onChanged;

  @override
  State<_HexColorInput> createState() => _HexColorInputState();
}

class _HexColorInputState extends State<_HexColorInput> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _textFor(widget.color));
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _HexColorInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color && !_focusNode.hasFocus) {
      final text = _textFor(widget.color);
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  String _textFor(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('theme-color-hex-input'),
      controller: _controller,
      focusNode: _focusNode,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.characters,
      decoration: InputDecoration(
        labelText: 'HEX',
        hintText: '#RRGGBB',
        errorText: widget.valid
            ? null
            : L.pick(
                en: 'Enter a 6-digit HEX color',
                zhTW: '請輸入 6 位 HEX 色碼',
                zhCN: '请输入 6 位 HEX 色码',
              ),
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: widget.onChanged,
    );
  }
}

class _ColorEntry {
  final String label;
  Color color;
  final String key;
  bool selected;

  _ColorEntry(this.label, this.color, this.key) : selected = false;
}
