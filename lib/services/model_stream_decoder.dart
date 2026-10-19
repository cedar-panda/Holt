/// Incrementally separates user-visible prose from Holt's hidden action
/// protocol while provider chunks are still arriving.
///
/// The raw provider response must be stored separately for action processing.
/// This decoder owns presentation only: hidden XML/JSON actions are never
/// appended to the visible stream, so they cannot flash and then reflow the
/// completed reply.
class ModelStreamDecoder {
  ModelStreamDecoder();

  static const String jsonActionStart = '[[HOLT_ACTIONS]]';
  static const String jsonActionEnd = '[[/HOLT_ACTIONS]]';

  static const Set<String> _blockTags = <String>{
    'emo',
    'emo_resolve',
    'memo',
    'memo_del',
    'memo_merge',
    'memo_update',
    'memo_link',
    'force_recall',
    'persona_note',
    'draw',
    'clock',
    'clock_keep',
    'clock_update',
    'clock_del',
    'life_fix',
    'home',
    'whisper',
    'think',
    'thinking',
    'search_chat',
    'search_web',
    'call',
    'x_post',
    'pack_star',
    'email_draft',
    'holt_diary',
    'holt_persona_draft',
    'tool_call',
    'tool_calls',
  };

  static const Set<String> _standaloneTags = <String>{
    'scratch',
    'transfer',
    'transfer_accept',
    'transfer_decline',
    'buy',
    'shop_view',
    'sign_marriage',
    'propose_marriage',
    'decline_call',
    'hangup',
  };

  static final Set<String> _knownTags = <String>{
    ..._blockTags,
    ..._standaloneTags,
  };

  String _pending = '';
  String _heldWhitespace = '';
  String? _hiddenClose;

  /// Adds a provider chunk and returns only newly available visible text.
  String add(String chunk) {
    if (chunk.isEmpty) return '';
    _pending += chunk;
    final out = StringBuffer();
    _drain(out, finishing: false);
    return out.toString();
  }

  /// Flushes a final non-protocol fragment. An unfinished hidden action stays
  /// hidden fail-closed instead of leaking its payload into the reply.
  String close() {
    final out = StringBuffer();
    _drain(out, finishing: true);
    if (_hiddenClose == null && _pending.isNotEmpty) {
      _emitVisible(_pending, out);
    }
    _pending = '';
    if (_hiddenClose == null && _heldWhitespace.isNotEmpty) {
      out.write(_heldWhitespace);
    }
    _heldWhitespace = '';
    return out.toString();
  }

  void reset() {
    _pending = '';
    _heldWhitespace = '';
    _hiddenClose = null;
  }

  void _drain(StringBuffer out, {required bool finishing}) {
    while (_pending.isNotEmpty) {
      final hiddenClose = _hiddenClose;
      if (hiddenClose != null) {
        final closeIndex = _indexOfIgnoreCase(_pending, hiddenClose);
        if (closeIndex >= 0) {
          _pending = _pending.substring(closeIndex + hiddenClose.length);
          _hiddenClose = null;
          _heldWhitespace = '';
          continue;
        }
        if (finishing) {
          _pending = '';
          _heldWhitespace = '';
          return;
        }
        final keep = hiddenClose.length - 1;
        if (_pending.length > keep) {
          _pending = _pending.substring(_pending.length - keep);
        }
        return;
      }

      final xmlIndex = _pending.indexOf('<');
      final jsonIndex = _pending.indexOf('[');
      final candidateIndex = _firstCandidate(xmlIndex, jsonIndex);
      if (candidateIndex < 0) {
        _emitVisible(_pending, out);
        _pending = '';
        return;
      }
      if (candidateIndex > 0) {
        _emitVisible(_pending.substring(0, candidateIndex), out);
        _pending = _pending.substring(candidateIndex);
        continue;
      }

      if (_pending.startsWith('[')) {
        if (jsonActionStart.startsWith(_pending) && !finishing) return;
        if (_pending.startsWith(jsonActionStart)) {
          _pending = _pending.substring(jsonActionStart.length);
          _hiddenClose = jsonActionEnd;
          _heldWhitespace = '';
          continue;
        }
        _emitVisible(_pending[0], out);
        _pending = _pending.substring(1);
        continue;
      }

      final tagEnd = _pending.indexOf('>');
      if (tagEnd < 0) {
        if (!finishing && _couldBeKnownTagPrefix(_pending)) return;
        _emitVisible(_pending[0], out);
        _pending = _pending.substring(1);
        continue;
      }

      final opening = _pending.substring(0, tagEnd + 1);
      final match = RegExp(
        r'^<\s*([A-Za-z_][A-Za-z0-9_:-]*)\b',
      ).firstMatch(opening);
      final name = match?.group(1)?.toLowerCase();
      if (name == null || !_knownTags.contains(name)) {
        _emitVisible(opening, out);
        _pending = _pending.substring(tagEnd + 1);
        continue;
      }

      _pending = _pending.substring(tagEnd + 1);
      _heldWhitespace = '';
      final selfClosing = opening.trimRight().endsWith('/>');
      if (_blockTags.contains(name) && !selfClosing) {
        _hiddenClose = '</$name>';
      }
    }
  }

  void _emitVisible(String value, StringBuffer out) {
    if (value.isEmpty) return;
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      if (RegExp(r'\s').hasMatch(character)) {
        _heldWhitespace += character;
      } else {
        if (_heldWhitespace.isNotEmpty) {
          out.write(_heldWhitespace);
          _heldWhitespace = '';
        }
        out.write(character);
      }
    }
  }

  static int _firstCandidate(int xmlIndex, int jsonIndex) {
    if (xmlIndex < 0) return jsonIndex;
    if (jsonIndex < 0) return xmlIndex;
    return xmlIndex < jsonIndex ? xmlIndex : jsonIndex;
  }

  static int _indexOfIgnoreCase(String value, String needle) =>
      value.toLowerCase().indexOf(needle.toLowerCase());

  static bool _couldBeKnownTagPrefix(String value) {
    final normalized = value.toLowerCase().replaceFirst(RegExp(r'^<\s*'), '');
    if (normalized.isEmpty) return true;
    final name = normalized.split(RegExp(r'[\s>/]')).first;
    return _knownTags.any((known) => known.startsWith(name));
  }
}
