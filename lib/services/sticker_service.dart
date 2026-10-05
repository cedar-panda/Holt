import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../memory/database.dart';
import 'api_adapter.dart';
import 'settings_manager.dart';
import 'locale_strings.dart';
import 'token_tracker.dart';

/// 表情包管理服務
/// 上傳 → 三種描述 → AI 挑選 → 台詞注入 prompt
class StickerService {
  static const String userBucket = 'user';
  static const String legacyDefaultBucket = 'default';

  /// 預設情緒標籤
  static const List<String> presetLabels = [
    '開心',
    '害羞',
    '生氣',
    '委屈',
    '無語',
    '撒嬌',
    '得意',
    '震驚',
    '心動',
    '嫌棄',
    '困',
    '哭',
    '笑哭',
    '期待',
    '拒絕',
    '心疼',
    '發呆',
    '嘴硬',
    '偷看',
    '裝死',
  ];

  /// 取得 tag 的顯示文字（翻譯後）
  static String tagDisplay(String tag) => L.get('tag_$tag');

  // ═══════════════════════════════════
  // 表情包 CRUD
  // ═══════════════════════════════════

  /// 新增表情包
  static Future<int> addSticker({
    required String filePath,
    String characterId = userBucket,
    String? line,
    String? scene,
    String? mood,
    String? tags,
    String descriptionMethod = 'label',
  }) async {
    final source = File(filePath);
    if (!await source.exists()) return -1;
    final documents = await getApplicationDocumentsDirectory();
    final stickerDir = Directory(p.join(documents.path, 'stickers'));
    await stickerDir.create(recursive: true);
    final rawExt = p.extension(filePath).toLowerCase();
    final ext = RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(rawExt) ? rawExt : '.png';
    final storedPath = p.join(
      stickerDir.path,
      'sticker_${DateTime.now().microsecondsSinceEpoch}$ext',
    );
    await source.copy(storedPath);
    try {
      return await DatabaseHelper.insertSticker({
        'character_id': characterId,
        'file_path': storedPath,
        'line': line,
        'scene': scene,
        'mood': mood,
        'tags': tags,
        'description_method': descriptionMethod,
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {
      final copied = File(storedPath);
      if (await copied.exists()) await copied.delete();
      rethrow;
    }
  }

  /// 更新表情包描述
  static Future<void> updateSticker(
    int id, {
    String? line,
    String? scene,
    String? mood,
    String? tags,
    String? descriptionMethod,
  }) async {
    final db = await DatabaseHelper.database;
    final updates = <String, dynamic>{};
    if (line != null) updates['line'] = line;
    if (scene != null) updates['scene'] = scene;
    if (mood != null) updates['mood'] = mood;
    if (tags != null) updates['tags'] = tags;
    if (descriptionMethod != null) {
      updates['description_method'] = descriptionMethod;
    }
    if (updates.isNotEmpty) {
      await db.update('stickers', updates, where: 'id = ?', whereArgs: [id]);
    }
  }

  /// 獲取指定表情桶的所有表情包。
  static Future<List<StickerInfo>> getStickers({
    String characterId = userBucket,
  }) async {
    final maps = await DatabaseHelper.getStickers(characterId: characterId);
    return maps.map((m) => StickerInfo.fromMap(m)).toList();
  }

  /// 「我的表情」：正式桶為 user，兼容尚未遷移的舊 default 桶。
  static Future<List<StickerInfo>> getUserStickers({
    bool includeLegacyDefault = true,
  }) async {
    final buckets = <String>[
      userBucket,
      if (includeLegacyDefault) legacyDefaultBucket,
    ];
    return _getMergedStickers(buckets);
  }

  static Future<List<StickerInfo>> _getMergedStickers(
    List<String> bucketIds,
  ) async {
    final seen = <int>{};
    final merged = <StickerInfo>[];
    for (final bucket in bucketIds) {
      final trimmed = bucket.trim();
      if (trimmed.isEmpty) continue;
      for (final sticker in await getStickers(characterId: trimmed)) {
        if (seen.add(sticker.id)) merged.add(sticker);
      }
    }
    return merged;
  }

  /// 刪除表情包
  static Future<void> deleteSticker(int id) async {
    await DatabaseHelper.deleteSticker(id);
  }

  /// 替單一缺圖表情補回本地圖片。只改 file_path，ID/描述/標籤不變，
  /// 因此 buildStickerPrompt 逐字不變，不會影響 prompt cache。
  static Future<bool> repairStickerImage({
    required int stickerId,
    required String sourcePath,
    required String sourceName,
  }) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) return false;

    final documents = await getApplicationDocumentsDirectory();
    final stickerDir = Directory(p.join(documents.path, 'stickers'));
    await stickerDir.create(recursive: true);
    final rawExt = p.extension(sourceName).toLowerCase();
    final ext = RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(rawExt) ? rawExt : '.png';
    final targetPath = p.join(stickerDir.path, 'sticker_$stickerId$ext');
    await sourceFile.copy(targetPath);
    await DatabaseHelper.updateStickerFilePath(stickerId, targetPath);
    return true;
  }

  // ═══════════════════════════════════
  // Vision API 描述
  // ═══════════════════════════════════

  /// 建立表情包 Vision 提示詞。字數滑條只控制這條指令，不會被誤用成
  /// API max_tokens，也不會在回傳後硬截斷模型內容。
  static String buildVisionPrompt({
    required String characterName,
    int maxCharacters = 20,
  }) {
    final characterLimit = maxCharacters.clamp(20, 100).toInt();

    // 精簡 prompt — 不注入完整人設，省 input token
    final visionTemplate = L.pick(
      en:
          '''
You are “\u{E000}”. Read this sticker's conversational mood and infer what feeling it represents and when it would be used.
Do not describe the image. Keep the output content within $characterLimit characters.
Output JSON only, with no other text or Markdown:
{"line":"a line \u{E000} would say","scene":"usage context","mood":"3-5 emotion words, comma-separated"}''',
      zhTW:
          '''
你是「\u{E000}」。看這張表情包，讀空氣：它在對話裡代表什麼心情、什麼場景下會用。
不要描述畫面內容。輸出內容務必控制在 $characterLimit 字數內。
直接輸出 JSON，不加任何其他文字或 markdown：
{"line":"一句\u{E000} 會說的台詞","scene":"使用場景","mood":"3-5個情緒詞,逗號分隔"}''',
    );
    return visionTemplate.replaceAll('\u{E000}', characterName);
  }

  /// 用 Vision API 描述表情包（結合角色人設）
  /// 返回 {line, scene, mood}
  static Future<Map<String, String>> describeWithVision({
    required String imagePath,
    required String characterName,
    required String characterPrompt,
    int maxCharacters = 20,
  }) async {
    final file = File(imagePath);
    if (!file.existsSync()) {
      throw Exception('圖片不存在：$imagePath');
    }

    final bytes = await file.readAsBytes();
    final base64Image = base64Encode(bytes);

    // 判斷圖片格式
    final ext = imagePath.toLowerCase();
    String mediaType = 'image/png';
    if (ext.endsWith('.jpg') || ext.endsWith('.jpeg')) {
      mediaType = 'image/jpeg';
    } else if (ext.endsWith('.gif')) {
      mediaType = 'image/gif';
    } else if (ext.endsWith('.webp')) {
      mediaType = 'image/webp';
    }

    final visionPrompt = buildVisionPrompt(
      characterName: characterName,
      maxCharacters: maxCharacters,
    );

    // 優先用表情包專用模型（便宜的），沒設就用主模型
    var model = await UserSettings.getStickerVisionModel();
    final followsMainModel = model.isEmpty;
    final configuredProvider = await UserSettings.getStickerVisionProvider();
    if (followsMainModel) model = await ApiSettings.getModel();
    final provider = followsMainModel
        ? await ApiSettings.getApiProvider()
        : configuredProvider.isNotEmpty
        ? configuredProvider
        : await ApiSettings.resolveStarredModelProvider(model);

    final dataUrl = 'data:$mediaType;base64,$base64Image';

    // 工具模型按星標保存的來源建 adapter，不能借目前主 provider 承載。
    final adapter = followsMainModel
        ? await ApiSettings.buildAdapter()
        : configuredProvider.isEmpty
        ? await ApiSettings.buildAdapterForModel(model)
        : await ApiSettings.buildAdapter(
            overrideProvider: configuredProvider,
            overrideModel: model,
          );
    ApiUsage? usage;
    final response = await adapter.sendMessage(
      messages: [
        {'role': 'user', 'content': visionPrompt, 'image_data_url': dataUrl},
      ],
      model: model,
      onUsage: (value) => usage = value,
    );
    await TokenTracker().recordRealUsage(
      provider: provider,
      model: model,
      usage: usage ?? const ApiUsage(),
      requestKind: ApiRequestKind.sticker,
    );

    return _parseVisionResponse(response);
  }

  /// 解析 Vision 回覆 JSON
  static Map<String, String> _parseVisionResponse(String raw) {
    try {
      // 嘗試直接解析
      var cleaned = raw.trim();
      // 去掉可能的 markdown 包裹
      if (cleaned.startsWith('```')) {
        cleaned = cleaned.replaceAll(RegExp(r'^```\w*\n?'), '');
        cleaned = cleaned.replaceAll(RegExp(r'\n?```$'), '');
        cleaned = cleaned.trim();
      }
      final json = jsonDecode(cleaned);
      return {
        'line': json['line']?.toString() ?? '',
        'scene': json['scene']?.toString() ?? '',
        'mood': json['mood']?.toString() ?? '',
      };
    } catch (_) {
      // 解析失敗，把整段當台詞
      return {
        'line': raw.trim().length > 50
            ? raw.trim().substring(0, 50)
            : raw.trim(),
        'scene': '',
        'mood': '',
      };
    }
  }

  // ═══════════════════════════════════
  // Prompt 注入（聊天用）
  // ═══════════════════════════════════

  /// 組裝表情包 prompt 注入文字
  static Future<String> buildStickerPrompt({
    String characterId = legacyDefaultBucket,
  }) async {
    var ownStickers = await getStickers(characterId: characterId);
    // fallback：舊版角色共用表情可能仍在 default；新資料不再寫入 default。
    if (ownStickers.isEmpty &&
        characterId != legacyDefaultBucket &&
        characterId != userBucket) {
      ownStickers = await getStickers(characterId: legacyDefaultBucket);
    }
    final userStickers = await getUserStickers();
    if (ownStickers.isEmpty && userStickers.isEmpty) return '';

    final buffer = StringBuffer();
    if (ownStickers.isNotEmpty) {
      buffer.writeln(
        L.pick(
          en: 'You can use the following stickers. Insert one at an appropriate moment with [sticker:ID].',
          zhTW: '你有以下表情包可以使用。在回覆中適當的時機，用 [sticker:ID] 來插入表情包。',
        ),
      );
      buffer.writeln(
        L.pick(
          en: 'Do not use one in every reply; use them only for strong emotion or nonverbal expression.',
          zhTW: '不要每句話都用，只在情緒強烈或想表達非文字情感時使用。',
        ),
      );
      buffer.writeln('---');
      _writeStickerLines(buffer, ownStickers);
      buffer.writeln('---');
    }
    if (userStickers.isNotEmpty) {
      buffer.writeln(
        L.pick(
          en: 'The other person (user) may send the following stickers. When [sticker:ID] appears in their message, interpret its meaning as a sticker; do not reply to the ID as ordinary text.',
          zhTW:
              '對方（user）可能發以下表情包。當你在對方消息中看到 [sticker:ID]，請按含義理解，那是對方在發表情包；不要把 ID 當普通文字回覆。',
        ),
      );
      buffer.writeln('---');
      _writeStickerLines(buffer, userStickers);
      buffer.writeln('---');
    }
    return buffer.toString();
  }

  static void _writeStickerLines(
    StringBuffer buffer,
    List<StickerInfo> stickers,
  ) {
    // 全量發送：台詞/情緒/場景/標籤，有什麼帶什麼。
    for (final s in stickers) {
      final parts = <String>[];
      if (s.line != null && s.line!.isNotEmpty) parts.add('「${s.line}」');
      if (s.mood != null && s.mood!.isNotEmpty) {
        parts.add('${L.pick(en: 'Mood', zhTW: '情緒')}:${s.mood}');
      }
      if (s.scene != null && s.scene!.isNotEmpty) {
        parts.add('${L.pick(en: 'Scene', zhTW: '場景')}:${s.scene}');
      }
      if (s.tags != null && s.tags!.isNotEmpty) parts.add('#${s.tags}');
      if (parts.isEmpty) continue;
      buffer.writeln('ID:${s.id} ${parts.join(' ')}');
    }
  }

  /// 從 AI 回覆中解析表情包標記
  /// 支持格式：[sticker:5]、[sticker:ID:5]（本地模型常見變體）
  ///
  /// 標記裡的數字沒有位數上限，模型（尤其本地小模型）可能吐出超出 int
  /// 範圍的 ID。這個方法跑在 ChatBubble 的 build 期，拋錯會讓該訊息永久
  /// 紅屏，所以解析失敗時不推進 lastEnd，整段非法標記原樣留在文字裡。
  static List<ChatSegment> parseResponse(String response) {
    final segments = <ChatSegment>[];
    final pattern = RegExp(r'\[sticker:(?:ID:)?(\d+)\]');
    int lastEnd = 0;

    for (final match in pattern.allMatches(response)) {
      final stickerId = int.tryParse(match.group(1)!);
      if (stickerId == null) continue;

      if (match.start > lastEnd) {
        segments.add(TextSegment(response.substring(lastEnd, match.start)));
      }
      segments.add(StickerSegment(stickerId));
      lastEnd = match.end;
    }

    if (lastEnd < response.length) {
      segments.add(TextSegment(response.substring(lastEnd)));
    }

    return segments.isEmpty ? [TextSegment(response)] : segments;
  }
}

/// 表情包資訊
class StickerInfo {
  final int id;
  final String characterId;
  final String filePath;
  final String? line;
  final String? scene;
  final String? mood;
  final String? tags;
  final String descriptionMethod;

  StickerInfo({
    required this.id,
    required this.characterId,
    required this.filePath,
    this.line,
    this.scene,
    this.mood,
    this.tags,
    this.descriptionMethod = 'label',
  });

  factory StickerInfo.fromMap(Map<String, dynamic> map) {
    return StickerInfo(
      id: map['id'] as int,
      characterId: map['character_id'] as String? ?? 'default',
      filePath: map['file_path'] as String,
      line: map['line'] as String?,
      scene: map['scene'] as String?,
      mood: map['mood'] as String?,
      tags: map['tags'] as String?,
      descriptionMethod: map['description_method'] as String? ?? 'label',
    );
  }
}

/// 聊天內容片段
abstract class ChatSegment {}

class TextSegment extends ChatSegment {
  final String text;
  TextSegment(this.text);
}

class StickerSegment extends ChatSegment {
  final int stickerId;
  StickerSegment(this.stickerId);
}
