import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueChanged, VoidCallback;
import 'package:http/http.dart' as http;

import '../memory/database.dart';
import 'call_tts_failure_policy.dart';
import 'settings_manager.dart';
import 'token_tracker.dart';
import 'tts_service.dart';

/// TTS 供應商 id（與 `TtsSettings.getTtsProvider()` 的值一致）。
abstract final class TtsProviders {
  static const String openai = 'openai';
  static const String elevenlabs = 'elevenlabs';
}

/// 角色卡的聲音綁定：每個供應商各存一個（`characters.tts_voice_ids_json`）。
///
/// 以前只有一個 `tts_voice_id`，切換供應商時會把 A 家的聲音 ID 送給 B 家。
/// 舊欄位仍保留並鏡像寫入（備份／降級相容）；新欄位沒資料時，按舊值的格式
/// 判斷它原本屬於哪一家，只給那一家用。
abstract final class CharacterVoiceBindings {
  static const String column = 'tts_voice_ids_json';
  static const String legacyColumn = 'tts_voice_id';

  static Map<String, String> decode(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return <String, String>{
        for (final entry in decoded.entries)
          if (entry.value is String &&
              (entry.value as String).trim().isNotEmpty)
            entry.key.toString(): (entry.value as String).trim(),
      };
    } catch (_) {
      return <String, String>{};
    }
  }

  static String encode(Map<String, String> bindings) =>
      jsonEncode(<String, String>{
        for (final entry in bindings.entries)
          if (entry.value.trim().isNotEmpty) entry.key: entry.value.trim(),
      });

  /// 舊的單一欄位值看起來屬於哪個供應商。
  static bool legacyFits(String provider, String legacyVoice) {
    final isOpenaiVoice = TtsService.openaiVoices.contains(legacyVoice);
    return switch (provider) {
      TtsProviders.openai => isOpenaiVoice,
      TtsProviders.elevenlabs => !isOpenaiVoice,
      _ => false,
    };
  }

  static Map<String, String> bindingsOf(Map<String, Object?>? character) {
    if (character == null) return <String, String>{};
    final bindings = decode(character[column]);
    if (bindings.isNotEmpty) return bindings;
    final legacy = (character[legacyColumn] as String?)?.trim() ?? '';
    if (legacy.isEmpty) return bindings;
    for (final provider in <String>[
      TtsProviders.openai,
      TtsProviders.elevenlabs,
    ]) {
      if (legacyFits(provider, legacy)) {
        return <String, String>{provider: legacy};
      }
    }
    return bindings;
  }

  static String voiceFor(Map<String, Object?>? character, String provider) =>
      bindingsOf(character)[provider] ?? '';

  /// 回傳新的綁定表；[voice] 為空代表該供應商改回跟隨全域預設。
  static Map<String, String> withVoice(
    Map<String, String> bindings,
    String provider,
    String voice,
  ) {
    final next = Map<String, String>.from(bindings);
    if (voice.trim().isEmpty) {
      next.remove(provider);
    } else {
      next[provider] = voice.trim();
    }
    return next;
  }
}

/// 一次解析好的 TTS 設定：聊天朗讀每次請求解析一次，通話整輪解析一次後
/// 重複用在每一句。新增供應商時在這裡加欄位，在 [TtsSynthesizer] 加分支。
class TtsVoiceConfig {
  const TtsVoiceConfig({
    required this.provider,
    required this.apiKey,
    required this.voice,
    this.model = '',
    this.stability = 0.5,
    this.similarity = 0.75,
  });

  final String provider;
  final String apiKey;

  /// OpenAI 為 voice 名稱；ElevenLabs 為 Voice ID。
  final String voice;
  final String model;
  final double stability;
  final double similarity;

  /// ElevenLabs v3／v4 會讀 `[laughs]` 這類語音標籤，其他模型要剝掉。
  bool get keepsAudioTags =>
      provider == TtsProviders.elevenlabs &&
      (model == 'eleven_v3' || model == 'eleven_v4');

  /// ElevenLabs request stitching（`previous_request_ids`）：讓每句接著
  /// 前幾句的語氣唸，句間不斷氣。官方文件明寫 v3 不支援；只對 v4 開，
  /// Flash／Multilingual 文件沒寫，未實測前不開。
  bool get supportsStitching =>
      provider == TtsProviders.elevenlabs && effectiveModel == 'eleven_v4';

  String get effectiveModel => switch (provider) {
    TtsProviders.elevenlabs =>
      model.isEmpty ? TtsSynthesizer.defaultElevenlabsModel : model,
    _ => TtsSynthesizer.openaiModel,
  };
}

/// 聊天朗讀（`TtsService`）與通話（`SentenceTtsPipeline`）共用的合成層。
///
/// 以前兩邊各寫一份 OpenAI／ElevenLabs 請求：聊天那份沒有逾時、
/// 沒有區分設定錯誤；通話那份另外解析角色聲音。現在統一由這裡負責
/// 「角色卡聲音優先 → 全域預設」、請求、逾時與錯誤分類。
abstract final class TtsSynthesizer {
  static const String openaiModel = 'tts-1';
  static const String defaultElevenlabsModel = 'eleven_multilingual_v2';
  static const String _defaultOpenaiVoice = 'nova';
  static const int _openaiMaxInputChars = 4096;
  static const Duration requestTimeout = Duration(seconds: 30);

  /// 角色卡為「這個供應商」綁定的聲音；沒綁就回空字串（跟隨全域）。
  static Future<String> _characterVoice(
    String? characterId,
    String provider,
  ) async {
    if (characterId == null) return '';
    final character = await DatabaseHelper.getCharacter(characterId);
    return CharacterVoiceBindings.voiceFor(character, provider);
  }

  static Future<TtsVoiceConfig> resolve({String? characterId}) async {
    final provider =
        await TtsSettings.getTtsProvider() == TtsProviders.elevenlabs
        ? TtsProviders.elevenlabs
        : TtsProviders.openai;
    final characterVoice = await _characterVoice(characterId, provider);
    if (provider == TtsProviders.elevenlabs) {
      return TtsVoiceConfig(
        provider: TtsProviders.elevenlabs,
        apiKey: await TtsSettings.getTtsElevenlabsKey(),
        voice: characterVoice.isNotEmpty
            ? characterVoice
            : await TtsSettings.getTtsElevenlabsVoiceId(),
        model: await TtsSettings.getTtsElevenlabsModel(),
        stability: await TtsSettings.getTtsElevenlabsStability(),
        similarity: await TtsSettings.getTtsElevenlabsSimilarity(),
      );
    }
    return TtsVoiceConfig(
      provider: TtsProviders.openai,
      apiKey: await TtsSettings.getTtsOpenaiKey(),
      voice: characterVoice.isNotEmpty
          ? characterVoice
          : await TtsSettings.getTtsVoice(),
    );
  }

  /// 合成一段音頻（mp3 bytes）。
  ///
  /// 金鑰／聲音未設定、或供應商回 4xx（408／429 除外）時拋
  /// [CallTtsConfigurationException]：使用者改設定前重試也不會成功。
  /// 其他失敗拋一般 [Exception]，呼叫端可視為暫時性錯誤。
  static Future<Uint8List> synthesize(
    TtsVoiceConfig config,
    String text, {
    String? characterId,
    bool recordUsage = false,
    String? languageCode,
    List<String> previousRequestIds = const [],
    ValueChanged<String>? onRequestId,
    VoidCallback? onStitchRejected,
  }) async {
    final bytes = switch (config.provider) {
      TtsProviders.elevenlabs => await _elevenlabs(
        config,
        text,
        languageCode: languageCode,
        previousRequestIds: previousRequestIds,
        onRequestId: onRequestId,
        onStitchRejected: onStitchRejected,
      ),
      _ => await _openai(config, text),
    };
    if (recordUsage) {
      await TokenTracker().recordBillableOperation(
        provider: config.provider,
        model: config.effectiveModel,
        estimatedCost: 0,
        characterId: characterId ?? 'default',
        requestKind: ApiRequestKind.tts,
      );
    }
    return bytes;
  }

  static Future<Uint8List> _openai(TtsVoiceConfig config, String text) async {
    if (config.apiKey.isEmpty) {
      throw const CallTtsConfigurationException('OpenAI TTS API Key 未設定');
    }
    final response = await http
        .post(
          Uri.parse('https://api.openai.com/v1/audio/speech'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${config.apiKey}',
          },
          body: jsonEncode({
            'model': openaiModel,
            'voice': config.voice.isEmpty ? _defaultOpenaiVoice : config.voice,
            'input': text.length > _openaiMaxInputChars
                ? text.substring(0, _openaiMaxInputChars)
                : text,
            'response_format': 'mp3',
          }),
        )
        .timeout(requestTimeout);
    if (response.statusCode != 200) {
      if (CallTtsFailurePolicy.isConfigurationStatus(response.statusCode)) {
        throw CallTtsConfigurationException(
          'OpenAI TTS ${response.statusCode}',
        );
      }
      throw Exception('OpenAI TTS ${response.statusCode}');
    }
    return response.bodyBytes;
  }

  /// 通話語言 → ElevenLabs language_code。只有 v3／v4 支援粵語（yue），
  /// 其他模型不送，避免被拒。
  static String? elevenlabsLanguageFor(String sttLocale) =>
      sttLocale == 'zh_HK' ? 'yue' : null;

  /// stitching 最多帶前幾句的 request id。
  static const int maxStitchIds = 3;

  static Future<Uint8List> _elevenlabs(
    TtsVoiceConfig config,
    String text, {
    String? languageCode,
    List<String> previousRequestIds = const [],
    ValueChanged<String>? onRequestId,
    VoidCallback? onStitchRejected,
  }) async {
    final hint = config.keepsAudioTags ? languageCode : null;
    final previous = config.supportsStitching
        ? previousRequestIds
        : const <String>[];
    try {
      return await _elevenlabsRequest(
        config,
        text,
        languageCode: hint,
        previousRequestIds: previous,
        onRequestId: onRequestId,
      );
    } on CallTtsConfigurationException {
      // 語言提示或 stitching 被模型拒絕（400／422）時，兩個都拿掉再試一次；
      // 不能因為一個「建議」害整通電話沒聲音。
      if (hint == null && previous.isEmpty) rethrow;
      if (previous.isNotEmpty) onStitchRejected?.call();
      return _elevenlabsRequest(config, text, onRequestId: onRequestId);
    }
  }

  static Future<Uint8List> _elevenlabsRequest(
    TtsVoiceConfig config,
    String text, {
    String? languageCode,
    List<String> previousRequestIds = const [],
    ValueChanged<String>? onRequestId,
  }) async {
    if (config.apiKey.isEmpty) {
      throw const CallTtsConfigurationException('ElevenLabs API Key 未設定');
    }
    if (config.voice.isEmpty) {
      throw const CallTtsConfigurationException('ElevenLabs Voice ID 未設定');
    }
    final response = await http
        .post(
          Uri.parse(
            'https://api.elevenlabs.io/v1/text-to-speech/${config.voice}'
            '?output_format=mp3_44100_128',
          ),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'audio/mpeg',
            'xi-api-key': config.apiKey,
          },
          body: jsonEncode({
            'text': text,
            'model_id': config.effectiveModel,
            'language_code': ?languageCode,
            // 不送 previous_text：部分模型帶它會直接 400
            // （「第一句有聲、第二句起 400」的元兇）。
            // 改用 previous_request_ids（只對 supportsStitching 的模型）。
            if (previousRequestIds.isNotEmpty)
              'previous_request_ids': previousRequestIds.length > maxStitchIds
                  ? previousRequestIds.sublist(
                      previousRequestIds.length - maxStitchIds,
                    )
                  : previousRequestIds,
            'voice_settings': {
              'stability': config.stability,
              'similarity_boost': config.similarity,
            },
          }),
        )
        .timeout(requestTimeout);
    if (response.statusCode != 200) {
      // 帶上 body：ElevenLabs 的 400 會在 body 寫明真正原因。
      final message = 'ElevenLabs ${response.statusCode}: ${response.body}';
      if (CallTtsFailurePolicy.isConfigurationStatus(response.statusCode)) {
        throw CallTtsConfigurationException(message);
      }
      throw Exception(message);
    }
    final requestId = response.headers['request-id'];
    if (requestId != null && requestId.isNotEmpty) onRequestId?.call(requestId);
    return response.bodyBytes;
  }
}
