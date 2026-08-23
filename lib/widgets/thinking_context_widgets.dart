import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../services/locale_strings.dart';
import '../theme/app_theme.dart';

class ThinkingContextLogParts {
  const ThinkingContextLogParts({
    this.memoryLog = '',
    this.emotionLog = '',
    this.emotionCoordinate = '',
  });

  final String memoryLog;
  final String emotionLog;
  final String emotionCoordinate;
}

ThinkingContextLogParts parseThinkingContextLog(
  String rawLog, {
  required bool includeMemory,
  required bool includeEmotion,
}) {
  if (rawLog.isEmpty) return const ThinkingContextLogParts();
  final memoryLines = <String>[];
  final emotionLines = <String>[];
  var emotionCoordinate = '';
  var done = false;
  for (final line in rawLog.split('\n')) {
    final trimmed = line.trim();
    if (trimmed == 'Done') {
      done = true;
      continue;
    }
    if (line.startsWith('🎨')) {
      continue;
    }
    if (line.startsWith('情緒座標')) {
      emotionCoordinate = line;
    } else if (_isEmotionLogLine(line)) {
      emotionLines.add(line);
    } else {
      memoryLines.add(line);
    }
  }
  if (done && memoryLines.isNotEmpty) memoryLines.add('Done');
  if (done && emotionLines.isNotEmpty) emotionLines.add('Done');
  return ThinkingContextLogParts(
    memoryLog: includeMemory ? memoryLines.join('\n') : '',
    emotionLog: includeEmotion ? emotionLines.join('\n') : '',
    emotionCoordinate: includeEmotion ? emotionCoordinate : '',
  );
}

bool _isEmotionLogLine(String line) {
  final trimmed = line.trimLeft();
  return trimmed.startsWith('📍') ||
      trimmed.startsWith('🌊') ||
      trimmed.startsWith('🔒') ||
      trimmed.startsWith('情緒') ||
      trimmed.contains('打點 ') ||
      trimmed.contains('消解 ');
}

class ThinkingSheetLauncher extends StatelessWidget {
  const ThinkingSheetLauncher({
    super.key,
    required this.color,
    required this.onTap,
    this.badge,
  });

  final Color color;
  final VoidCallback onTap;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final label = L.get('chat_thinking_tree');
    return Semantics(
      button: true,
      expanded: false,
      label: L.pick(
        en: 'Thinking. Open details.',
        zhTW: 'Thinking，開啟詳細內容。',
        zhCN: 'Thinking，打开详细内容。',
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          key: const ValueKey('thinking-chain-container'),
          constraints: const BoxConstraints(minHeight: 44),
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontFamily: YanciTheme.fontFamily,
                ),
              ),
              if (badge != null) ...[const SizedBox(width: 6), badge!],
              const SizedBox(width: 4),
              Icon(
                Icons.keyboard_arrow_right_rounded,
                key: const ValueKey('thinking-sheet-launcher-chevron'),
                size: 16,
                color: color,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ThinkingTreeBodyLayout extends StatelessWidget {
  const ThinkingTreeBodyLayout({
    super.key,
    required this.inSheet,
    this.webSearch,
    this.contextDetails,
    this.thinkingContent,
  });

  final bool inSheet;
  final Widget? webSearch;
  final Widget? contextDetails;
  final Widget? thinkingContent;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('thinking-tree-body'),
      margin: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (webSearch != null)
            Padding(
              padding: EdgeInsets.only(left: inSheet ? 16 : 26, right: 8),
              child: webSearch,
            ),
          if (contextDetails != null)
            Padding(
              padding: EdgeInsets.only(left: inSheet ? 16 : 26, right: 8),
              child: contextDetails,
            ),
          if (thinkingContent != null)
            Padding(
              padding: EdgeInsets.only(
                left: inSheet ? 2 : 10,
                top: 7,
                right: 8,
                bottom: 7,
              ),
              child: thinkingContent,
            ),
        ],
      ),
    );
  }
}

class ThinkingMarkdown extends StatelessWidget {
  const ThinkingMarkdown({
    super.key,
    required this.text,
    required this.bodyColor,
    this.fontSize = 11,
  });

  final String text;
  final Color bodyColor;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: fontSize, color: bodyColor, height: 1.55);
    return MarkdownBody(
      data: text,
      selectable: false,
      softLineBreak: true,
      styleSheet: MarkdownStyleSheet(
        p: base,
        strong: base.copyWith(fontWeight: FontWeight.w600),
        em: base.copyWith(fontStyle: FontStyle.italic),
        code: base.copyWith(
          fontFamily: 'monospace',
          color: YanciTheme.accent,
          backgroundColor: YanciTheme.isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04),
        ),
        codeblockPadding: const EdgeInsets.all(8),
        codeblockDecoration: BoxDecoration(
          color: YanciTheme.isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(6),
        ),
        blockquote: base.copyWith(fontStyle: FontStyle.italic),
        blockquotePadding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: YanciTheme.accent.withValues(alpha: 0.32),
              width: 2,
            ),
          ),
        ),
        h1: base.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
        h2: base.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
        h3: base.copyWith(fontSize: 12, fontWeight: FontWeight.w600),
        listBullet: base,
        pPadding: const EdgeInsets.only(bottom: 2),
      ),
    );
  }
}
