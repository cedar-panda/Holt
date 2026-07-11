import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class HelpSwitchTile extends StatefulWidget {
  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  const HelpSwitchTile({
    super.key,
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  State<HelpSwitchTile> createState() => _HelpSwitchTileState();
}

class _HelpSwitchTileState extends State<HelpSwitchTile> {
  bool _isExpanded = false;

  void _toggleExpand() {
    setState(() {
      _isExpanded = !_isExpanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    return TapRegion(
      onTapOutside: (event) {
        if (_isExpanded) {
          setState(() => _isExpanded = false);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_isExpanded) {
            setState(() => _isExpanded = false);
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    widget.title,
                    style: YanciTheme.bodyText.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: widget.enabled
                          ? YanciTheme.textPrimary
                          : YanciTheme.textSecondary.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _toggleExpand,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _isExpanded
                              ? YanciTheme.accent
                              : YanciTheme.textSecondary.withValues(alpha: 0.5),
                          width: 1.2,
                        ),
                      ),
                      child: Icon(
                        Icons.question_mark_rounded,
                        size: 10,
                        color: _isExpanded
                            ? YanciTheme.accent
                            : YanciTheme.textSecondary.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Transform.scale(
                    scale: 0.85,
                    child: Switch(
                      value: widget.value,
                      activeThumbColor: YanciTheme.accent,
                      activeTrackColor: YanciTheme.accent.withValues(
                        alpha: 0.3,
                      ),
                      onChanged: widget.enabled ? widget.onChanged : null,
                    ),
                  ),
                ],
              ),
              AnimatedCrossFade(
                firstChild: const SizedBox(width: double.infinity, height: 0),
                secondChild: Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 10, right: 40),
                  child: Text(
                    widget.description,
                    style: YanciTheme.bodySmall.copyWith(
                      fontSize: 11,
                      color: YanciTheme.textSecondary.withValues(alpha: 0.7),
                      height: 1.45,
                    ),
                  ),
                ),
                crossFadeState: _isExpanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topLeft,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
