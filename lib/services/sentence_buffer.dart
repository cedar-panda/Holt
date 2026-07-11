/// 句子緩衝器 — LLM stream tokens → 完整句子
///
/// 收集 token，在斷句點（句號、問號、感嘆號、換行）切割。
/// 太短的碎片會合併到下一句，避免 TTS 卡頓。
class SentenceBuffer {
  final void Function(String sentence) onSentence;
  final int minLength;

  String _buffer = '';
  int _searchFrom = 0; // 短句跳過的斷點位置（避免在同一斷點上死循環）

  SentenceBuffer({required this.onSentence, this.minLength = 6});

  /// 餵入一個 token
  void add(String token) {
    _buffer += token;
    _tryFlush(force: false);
  }

  /// 強制清空（stream 結束時呼叫）
  void flush() {
    _tryFlush(force: true);
  }

  void _tryFlush({required bool force}) {
    while (true) {
      final idx = _findBreakPoint(from: _searchFrom);
      if (idx < 0) break;

      final candidate = _buffer.substring(0, idx + 1).trim();

      // 太短：不切，斷點後移，讓短句與後文合併成一句
      // （舊版把短句拼回 buffer 頭部，斷點位置永遠不變 →
      //   開頭是「嗯。」這種短句時整段堵死到 stream 結束）
      if (!force && candidate.length < minLength) {
        _searchFrom = idx + 1;
        continue;
      }

      _buffer = _buffer.substring(idx + 1);
      _searchFrom = 0;
      if (candidate.isNotEmpty) onSentence(candidate);
    }

    // force 時把殘留的也推出去
    if (force && _buffer.trim().isNotEmpty) {
      onSentence(_buffer.trim());
      _buffer = '';
      _searchFrom = 0;
    }
  }

  /// 找最近的斷句點（從 from 位置開始找）
  int _findBreakPoint({int from = 0}) {
    // 優先級：換行 > 句號/問號/感嘆號 > 省略號後
    for (int i = from; i < _buffer.length; i++) {
      final c = _buffer[i];
      if (c == '\n') return i;
      // 中文標點
      if (c == '。' || c == '？' || c == '！' || c == '；') return i;
      // 英文標點（後面是空格或結尾才算）
      if ((c == '.' || c == '?' || c == '!') &&
          (i == _buffer.length - 1 ||
              _buffer[i + 1] == ' ' ||
              _buffer[i + 1] == '\n')) {
        return i;
      }
      // 省略號（中文 …… 結束）
      if (c == '…' && i + 1 < _buffer.length && _buffer[i + 1] != '…') {
        return i;
      }
    }
    return -1;
  }

  void reset() {
    _buffer = '';
    _searchFrom = 0;
  }
}
