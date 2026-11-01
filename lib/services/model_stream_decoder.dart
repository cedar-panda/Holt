import 'protocol_tags.dart';

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

  /// Bare JSON action blocks the model sometimes outputs without sentinels.
  /// Only matched as a prefix of the `{` currently being examined.
  static final RegExp _bareJsonActionStart = ProtocolTags.bareJsonActionStart;
  static const String _bareJsonCompact = '{"actions":[';

  static const Set<String> _blockTags = <String>{
    ...ProtocolTags.block,
    'think',
    'thinking',
  };

  static const Set<String> _standaloneTags = ProtocolTags.standalone;

  static final Set<String> _knownTags = <String>{
    ..._blockTags,
    ..._standaloneTags,
  };

  String _pending = '';
  String _heldWhitespace = '';
  String? _hiddenClose;

  /// When hiding a bare JSON action block (no sentinels), track brace depth
  /// to find the matching closing `}`. Braces inside JSON strings (for
  /// example a free-text `note`) are ignored.
  int _jsonBraceDepth = 0;
  bool _jsonInString = false;
  bool _jsonEscaped = false;

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
    if (_hiddenClose == null && _jsonBraceDepth == 0 && _pending.isNotEmpty) {
      _emitVisible(_pending, out);
    }
    _pending = '';
    if (_hiddenClose == null && _jsonBraceDepth == 0 && _heldWhitespace.isNotEmpty) {
      out.write(_heldWhitespace);
    }
    _heldWhitespace = '';
    _resetJson();
    return out.toString();
  }

  void reset() {
    _pending = '';
    _heldWhitespace = '';
    _hiddenClose = null;
    _resetJson();
  }

  void _resetJson() {
    _jsonBraceDepth = 0;
    _jsonInString = false;
    _jsonEscaped = false;
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

      // ── Bare JSON action block (brace-depth tracking) ──
      if (_jsonBraceDepth > 0) {
        for (var i = 0; i < _pending.length; i++) {
          final ch = _pending.codeUnitAt(i);
          if (_jsonInString) {
            if (_jsonEscaped) {
              _jsonEscaped = false;
            } else if (ch == 0x5C) {
              _jsonEscaped = true;
            } else if (ch == 0x22) {
              _jsonInString = false;
            }
            continue;
          }
          if (ch == 0x22) {
            _jsonInString = true;
          } else if (ch == 0x7B) {
            _jsonBraceDepth++;
          } else if (ch == 0x7D) {
            _jsonBraceDepth--;
            if (_jsonBraceDepth == 0) {
              _pending = _pending.substring(i + 1);
              _heldWhitespace = '';
              _resetJson();
              break;
            }
          }
        }
        if (_jsonBraceDepth > 0) {
          // Still inside the JSON block — consume everything.
          _pending = '';
          return;
        }
        continue;
      }

      final xmlIndex = _pending.indexOf('<');
      final jsonIndex = _pending.indexOf('[');
      final braceIndex = _pending.indexOf('{');
      final candidateIndex = _firstOfThree(xmlIndex, jsonIndex, braceIndex);
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

      // ── Bare JSON action block: {"actions":[ ──
      if (_pending.startsWith('{')) {
        if (_bareJsonActionStart.matchAsPrefix(_pending) != null) {
          _resetJson();
          _jsonBraceDepth = 1;
          _pending = _pending.substring(1);
          _heldWhitespace = '';
          continue;
        }
        if (!finishing && _couldBeBareJsonPrefix(_pending)) {
          // Could still become `{"actions":[` — wait for more.
          return;
        }
        // Not an action block — emit the brace as visible text.
        _emitVisible(_pending[0], out);
        _pending = _pending.substring(1);
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

  static int _firstOfThree(int a, int b, int c) =>
      _firstCandidate(_firstCandidate(a, b), c);

  static int _indexOfIgnoreCase(String value, String needle) =>
      value.toLowerCase().indexOf(needle.toLowerCase());

  static bool _couldBeBareJsonPrefix(String value) {
    final head = value.length > 64 ? value.substring(0, 64) : value;
    final compact = head.replaceAll(RegExp(r'\s'), '');
    return _bareJsonCompact.startsWith(compact);
  }

  static bool _couldBeKnownTagPrefix(String value) {
    final normalized = value.toLowerCase().replaceFirst(RegExp(r'^<\s*'), '');
    if (normalized.isEmpty) return true;
    final name = normalized.split(RegExp(r'[\s>/]')).first;
    return _knownTags.any((known) => known.startsWith(name));
  }
}
