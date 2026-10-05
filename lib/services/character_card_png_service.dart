import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Exports a standard Character Card V2 PNG.
///
/// The image is ordinary PNG data and the interoperable card JSON is stored in
/// a `tEXt` chunk with the keyword `chara`, base64-encoded as expected by
/// common character-card readers.
abstract final class CharacterCardPngService {
  static const List<int> _pngSignature = <int>[
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
  ];

  static Future<File> export(Map<String, dynamic> character) async {
    final imageBytes = await _readAvatar(character['avatar_path']?.toString());
    final card = <String, Object?>{
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': <String, Object?>{
        'name': _text(character['name']),
        'description': _text(character['description']),
        'personality': '',
        'scenario': '',
        'first_mes': '',
        'mes_example': '',
        'creator_notes': 'Exported from Holt',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': <String>[],
        'tags': <String>['holt'],
        'creator': 'Holt',
        'character_version': '1.0',
        'extensions': <String, Object?>{
          'holt': <String, String>{
            'gender': _text(character['gender']),
            'relationship': _text(character['relationship']),
            'race': _text(character['race']),
            'skill': _text(character['skill']),
            'age': _text(character['age']),
            'height': _text(character['height']),
            'signature': _boundedSignature(character['signature']),
          },
        },
      },
    };
    final json = utf8.encode(jsonEncode(card));
    final payload = utf8.encode('chara\u0000${base64Encode(json)}');
    final png = _insertTextChunk(imageBytes, payload);
    final temp = await getTemporaryDirectory();
    final name = _safeFileName(_text(character['name']));
    final file = File(
      p.join(
        temp.path,
        'holt_character_${name}_${DateTime.now().millisecondsSinceEpoch}.png',
      ),
    );
    await file.writeAsBytes(png, flush: true);
    return file;
  }

  static String _text(Object? value) => value?.toString().trim() ?? '';

  static String _boundedSignature(Object? value) {
    final lines = _text(value)
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(4)
        .join('\n');
    return String.fromCharCodes(lines.runes.take(64));
  }

  static String _safeFileName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[^a-zA-Z0-9一-龥_-]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (cleaned.isEmpty) return 'character';
    final end = cleaned.length > 48 ? 48 : cleaned.length;
    return cleaned.substring(0, end);
  }

  static Future<List<int>> _readAvatar(String? path) async {
    if (path != null && path.trim().isNotEmpty) {
      final file = File(path);
      if (await file.exists()) {
        final decoded = img.decodeImage(await file.readAsBytes());
        if (decoded != null) return img.encodePng(decoded, level: 6);
      }
    }
    final blank = img.Image(width: 1, height: 1, numChannels: 4);
    blank.setPixelRgba(0, 0, 0, 0, 0, 0);
    return img.encodePng(blank, level: 6);
  }

  static List<int> _insertTextChunk(List<int> png, List<int> payload) {
    if (png.length < _pngSignature.length ||
        !_pngSignature.asMap().entries.every(
          (entry) => png[entry.key] == entry.value,
        )) {
      throw const FormatException('PNG header is invalid');
    }
    var offset = _pngSignature.length;
    while (offset + 12 <= png.length) {
      final length = _readUint32(png, offset);
      final type = String.fromCharCodes(png.sublist(offset + 4, offset + 8));
      final end = offset + 12 + length;
      if (length < 0 || end > png.length) {
        throw const FormatException('PNG chunk exceeds file bounds');
      }
      if (type == 'IEND') {
        final chunk = _chunk('tEXt', payload);
        return <int>[
          ...png.sublist(0, offset),
          ...chunk,
          ...png.sublist(offset),
        ];
      }
      offset = end;
    }
    throw const FormatException('PNG IEND chunk is missing');
  }

  static int _readUint32(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static List<int> _chunk(String type, List<int> data) {
    final typeBytes = ascii.encode(type);
    final body = <int>[...typeBytes, ...data];
    final output = <int>[];
    output.addAll(_uint32(body.length));
    output.addAll(body);
    output.addAll(_uint32(_crc32(body)));
    return output;
  }

  static List<int> _uint32(int value) => <int>[
    (value >> 24) & 0xff,
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  ];

  static int _crc32(List<int> bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }
}
